//! Build-time proxy code generator.
//!
//! Flags:
//!   -i <path>   Input introspection XML file (required)
//!   -x <name>   Interface name to extract from the XML (required)
//!               e.g. "org.bluez.Adapter1"
//!               An XML file may contain multiple <interface> elements;
//!               this flag selects exactly one.
//!   -n <name>   Zig type name for the generated struct (required)
//!   -d <path>   Output .zig file path (required)
//!   -t <name>   Native-types module name (optional)
//!               Parameters annotated with dev.zbus.TypeHint will be
//!               rewritten as native_types.<HintValue>.

const std = @import("std");
const xml = @import("dishwasher");
const mem = std.mem;
const Io = std.Io;
const proc = std.process;
const assert = std.debug.assert;

const typehint_ann = "dev.zbus.TypeHint";

const Annotation = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .value = .{ .attribute, "value" },
    };
    name: []const u8,
    value: []const u8,
};

const Arg = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .type = .{ .attribute, "type" },
        .direction = .{ .maybe, .{ .attribute, "direction" } },
    };
    name: []const u8,
    type: []const u8,
    direction: ?[]const u8, // null ↔ signal args (always "in")
};

const Method = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .args = .{ .elements, "arg", Arg },
        .annotations = .{ .elements, "annotation", Annotation },
    };
    name: []const u8,
    args: []Arg,
    annotations: []Annotation,
};

const Signal = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .args = .{ .elements, "arg", Arg },
        .annotations = .{ .elements, "annotation", Annotation },
    };
    name: []const u8,
    args: []Arg,
    annotations: []Annotation,
};

const Property = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .type = .{ .attribute, "type" },
        .access = .{ .attribute, "access" },
        .annotations = .{ .elements, "annotation", Annotation },
    };
    name: []const u8,
    type: []const u8,
    access: []const u8,
    annotations: []Annotation,
};

const Interface = struct {
    pub const xml_shape = .{
        .name = .{ .attribute, "name" },
        .methods = .{ .elements, "method", Method },
        .signals = .{ .elements, "signal", Signal },
        .properties = .{ .elements, "property", Property },
    };
    name: []const u8,
    methods: []Method,
    signals: []Signal,
    properties: []Property,
};

/// The root <node> element may contain multiple <interface> children.
const Document = struct {
    pub const xml_shape = .{
        .node = .{ .element, "node", .{
            .interfaces = .{ .elements, "interface", Interface },
        } },
    };
    node: struct { interfaces: []Interface },
};
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var xml_src: ?[]const u8 = null;
    var dest_path: ?[]const u8 = null;
    var iface_name: ?[]const u8 = null; // -x
    var out_name: ?[]const u8 = null; // -n
    var native_mod: ?[]const u8 = null; // -t

    var args = init.minimal.args;
    var iter = args.iterate();
    _ = iter.next(); // skip argv[0]
    while (iter.next()) |arg| {
        if (mem.eql(u8, arg, "-i")) {
            xml_src = iter.next() orelse return error.MissingArg;
        } else if (mem.eql(u8, arg, "-x")) {
            iface_name = iter.next() orelse return error.MissingArg;
        } else if (mem.eql(u8, arg, "-n")) {
            out_name = iter.next() orelse return error.MissingArg;
        } else if (mem.eql(u8, arg, "-d")) {
            dest_path = iter.next() orelse return error.MissingArg;
        } else if (mem.eql(u8, arg, "-t")) {
            native_mod = iter.next() orelse return error.MissingArg;
        }
    }

    if (xml_src == null or dest_path == null or iface_name == null or out_name == null)
        return error.MissingRequiredArgs;

    const xml_file = try Io.Dir.cwd().openFile(io, xml_src.?, .{});
    defer xml_file.close(io);

    var xml_buf: [32768]u8 = undefined;
    var xml_rd = xml_file.reader(io, &xml_buf);
    // skip the first line if it's an XML declaration (<?xml ...?>)
    const first_byte = xml_rd.interface.takeByte() catch 0;
    if (first_byte == '<') {
        // peek whether it's a declaration
        const peek = xml_rd.interface.takeByte() catch 0;
        if (peek == '?') {
            _ = try xml_rd.interface.discardDelimiterInclusive('>');
        }
        // If not a declaration, we lost two bytes — that's acceptable for
        // well-formed documents starting with <node>.
    }

    const owned_doc = try xml.Populate(Document).initFromReader(gpa, &xml_rd.interface);
    defer owned_doc.deinit();

    // ── find the requested interface ─────────────────────────────────────────

    const iface: Interface = for (owned_doc.value.node.interfaces) |i| {
        if (mem.eql(u8, i.name, iface_name.?)) break i;
    } else {
        std.debug.print("error: interface '{s}' not found in '{s}'\n", .{ iface_name.?, xml_src.? });
        std.debug.print("available interfaces:\n", .{});
        for (owned_doc.value.node.interfaces) |i|
            std.debug.print("  {s}\n", .{i.name});
        return error.InterfaceNotFound;
    };

    // ── code generation ──────────────────────────────────────────────────────

    var out_buf = Io.Writer.Allocating.init(gpa);
    defer out_buf.deinit();
    const w = &out_buf.writer;

    const name = out_name.?;

    // -- header
    try w.print(
        \\
        \\const std  = @import("std");
        \\const zbus = @import("zbus");
        \\
        \\const {s} = @This();
        \\
        \\pub const interface_name: []const u8 = "{s}";
        \\
        \\interface: zbus.types.Proxy = .{{
        \\    .connection  = null,
        \\    .name        = interface_name,
        \\    .object_path = null,
        \\    .vtable      = &.{{
        \\        .handle_signal = &{s},
        \\        .destroy       = &destroy,
        \\    }},
        \\}},
        \\properties: Properties = .{{}},
        \\properties_manager: zbus.proxies.Properties(Properties, PropertyUnion, PropertyNames) = undefined,
        \\signals: zbus.types.SignalManager(Signals) = undefined,
        \\remote: []const u8 = "",
        \\signals_listener_id: usize = 0,
        \\
        \\
    , .{
        name,
        iface.name,
        if (iface.signals.len > 0) "signalHandler" else "zbus.types.Proxy.noopSignalHandler",
    });

    // -- methods
    var native_usages = std.ArrayList(struct {
        hint: []const u8,
        sig: []const u8,
    }).empty;
    defer native_usages.deinit(gpa);

    for (iface.methods) |method| {
        var typehints: ?mem.SplitIterator(u8, .scalar) = blk: {
            for (method.annotations) |ann| {
                if (mem.eql(u8, ann.name, typehint_ann)) {
                    break :blk mem.splitScalar(u8, ann.value, ',');
                }
            }
            break :blk null;
        };
        if (typehints != null and native_mod == null) return error.NativeModuleRequired;

        // Collect in-args and out-args
        var in_args = std.ArrayList(Arg).empty;
        defer in_args.deinit(gpa);

        var out_args = std.ArrayList(Arg).empty;
        defer out_args.deinit(gpa);

        for (method.args) |arg| {
            const dir = arg.direction orelse "in";
            if (mem.eql(u8, dir, "in")) try in_args.append(gpa, arg);
            if (mem.eql(u8, dir, "out")) try out_args.append(gpa, arg);
        }

        // fn signature
        try w.print("pub fn {s}(self: *{s}, gpa: ?std.mem.Allocator", .{ method.name, name });
        var hints_clone = typehints; // may iterate twice
        for (in_args.items) |arg| {
            try w.print(", @\"{s}\": ", .{arg.name});
            if (hints_clone) |*ht| {
                if (ht.next()) |hint| {
                    try w.print("native_types.{s}", .{hint});
                    try native_usages.append(gpa, .{ .hint = hint, .sig = arg.type });
                    continue;
                }
            }
            try writeZigType(arg.type, w);
        }

        // return type
        try w.writeAll(") !*zbus.types.Promise(");
        if (out_args.items.len == 0) {
            try w.writeAll("void");
        } else if (out_args.items.len == 1) {
            const arg = out_args.items[0];
            if (typehints) |*ht| {
                if (ht.next()) |hint| {
                    try w.print("native_types.{s}", .{hint});
                    try native_usages.append(gpa, .{ .hint = hint, .sig = arg.type });
                } else {
                    try writeZigType(arg.type, w);
                }
            } else {
                try writeZigType(arg.type, w);
            }
        } else {
            try w.writeAll("struct { ");
            for (out_args.items) |arg| {
                if (typehints) |*ht| {
                    if (ht.next()) |hint| {
                        try w.print("native_types.{s}, ", .{hint});
                        try native_usages.append(gpa, .{ .hint = hint, .sig = arg.type });
                        continue;
                    }
                }
                try writeZigType(arg.type, w);
                try w.writeAll(", ");
            }
            try w.writeAll("}");
        }

        try w.print(
            \\, zbus.types.DBusError) {{
            \\    if (self.interface.connection == null) return error.Unbound;
            \\    const c = self.interface.connection.?;
            \\    var req = try c.startMessage(gpa);
            \\    defer req.deinit();
            \\    req.type = .method_call;
            \\    _ = req.setDestination(self.remote)
            \\           .setInterface(interface_name)
            \\           .setPath(self.interface.object_path.?)
            \\           .setMember("{s}")
        , .{method.name});

        // signature string
        if (in_args.items.len > 0) {
            var sig_buf: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&sig_buf);
            var sig_w = std.ArrayList(u8).empty;
            for (in_args.items) |arg| {
                sig_w.appendSlice(fba.allocator(), arg.type) catch {};
            }
            try w.print("\n           .setSignature(\"{s}\")", .{sig_w.items});
        }
        try w.writeAll(";\n\n");

        // write body args
        if (in_args.items.len > 0) {
            try w.writeAll("    const bw = req.writer();\n    try bw.write(.{ ");
            for (in_args.items) |arg|
                try w.print("@\"{s}\", ", .{arg.name});
            try w.writeAll("});\n\n");
        }

        try w.print(
            \\    const promise = try c.trackResponse(req,
            \\        @typeInfo(@typeInfo(@typeInfo(@TypeOf({s})).@"fn".return_type.?).error_union.payload).pointer.child.Type,
            \\        zbus.types.DBusError);
            \\    errdefer if (promise.release() == 1) promise.destroy();
            \\    try c.sendMessage(&req);
            \\    return promise;
            \\}}
            \\
            \\
        , .{method.name});
    }

    // -- destroy
    try w.print(
        \\pub fn destroy(i: *zbus.types.Proxy, alloc: std.mem.Allocator) void {{
        \\    const self: *{s} = @fieldParentPtr("interface", i);
        \\    if (!self.properties._inited) return;
        \\    self.properties._mutex.lock();
        \\    defer self.properties._mutex.unlock();
        \\    inline for (@typeInfo(Properties).@"struct".fields) |field| {{
        \\        if (comptime std.mem.startsWith(u8, field.name, "_")) continue;
        \\        zbus.utils.deinitValue(alloc, @field(self.properties, field.name));
        \\    }}
        \\}}
        \\
        \\
    , .{name});

    // -- Properties struct
    try w.writeAll(
        \\pub const Properties = struct {
        \\    _inited: bool = false,
        \\    _mutex: std.Thread.Mutex = .{},
        \\
    );
    for (iface.properties) |prop| {
        try w.print("    @\"{s}\": ", .{prop.name});
        const hint = annotationValue(prop.annotations, typehint_ann);
        if (hint) |h| {
            if (native_mod == null) return error.NativeModuleRequired;
            try w.print("native_types.{s}", .{h});
        } else {
            try writeZigType(prop.type, w);
        }
        try w.writeAll(" = undefined,\n");
    }
    try w.writeAll("};\n\n");

    // -- PropertyNames enum
    try w.writeAll("pub const PropertyNames = enum {\n");
    for (iface.properties) |prop|
        try w.print("    @\"{s}\",\n", .{prop.name});
    try w.writeAll("};\n\n");

    // -- PropertyUnion
    try w.writeAll("pub const PropertyUnion = zbus.types.Variant(&.{");
    for (iface.properties) |prop| {
        try w.writeAll("\n    ");
        const hint = annotationValue(prop.annotations, typehint_ann);
        if (hint) |h| try w.print("native_types.{s}", .{h}) else try writeZigType(prop.type, w);
        try w.writeAll(",");
    }
    try w.writeAll("\n});\n\n");

    // -- Signals struct
    try w.writeAll("pub const Signals = struct {\n");
    for (iface.signals) |sig| {
        var typehints: ?mem.SplitIterator(u8, .scalar) = null;
        for (sig.annotations) |ann| {
            if (mem.eql(u8, ann.name, typehint_ann))
                typehints = mem.splitScalar(u8, ann.value, ',');
        }
        if (typehints != null and native_mod == null) return error.NativeModuleRequired;

        try w.print("    pub const @\"{s}\" = zbus.types.Signal(struct {{ ", .{sig.name});
        var ht = typehints;
        for (sig.args) |arg| {
            if (ht) |*h| {
                if (h.next()) |hint| {
                    try w.print("native_types.{s}, ", .{hint});
                    continue;
                }
            }
            try writeZigType(arg.type, w);
            try w.writeAll(", ");
        }
        try w.writeAll("}, .{});\n");
    }
    try w.writeAll("};\n\n");

    // -- bind
    try w.print(
        \\pub fn bind(
        \\    self:        *{s},
        \\    alloc:       std.mem.Allocator,
        \\    c:           *zbus.types.Connection,
        \\    remote:      []const u8,
        \\    object_path: []const u8,
        \\    listener:    @FieldType({s}, "signals").Listener,
        \\) !void {{
        \\    self.interface.connection  = c;
        \\    self.interface.object_path = object_path;
        \\    self.remote = remote;
        \\    try self.properties_manager.bind(c, remote, interface_name, object_path, &self.properties, alloc);
        \\    const lp = try c.registerListenerAsync(self, .{{
        \\        .interface = interface_name,
        \\        .path      = object_path,
        \\        .sender    = remote,
        \\    }}, &self.signals_listener_id, alloc);
        \\    defer if (lp.release() == 1) lp.destroy();
        \\    self.signals = .init(listener);
        \\}}
        \\
    , .{ name, name });

    // -- signalHandler (only if there are signals)
    if (iface.signals.len > 0) {
        try w.print(
            \\fn signalHandler(i: *zbus.types.Proxy, m: *zbus.types.Message, alloc: std.mem.Allocator) zbus.types.Proxy.Error!void {{
            \\    const self: *{s} = @fieldParentPtr("interface", i);
            \\    return self.signals.handle(m, alloc) catch error.HandlingFailed;
            \\}}
            \\
        , .{name});
    }

    // -- native types module import + comptime checks
    if (native_mod) |mod| {
        try w.print("const native_types = @import(\"{s}\");\n", .{mod});
        try w.writeAll("comptime {\n");
        for (native_usages.items) |use| {
            try w.print("    if (!std.mem.eql(u8, zbus.utils.signatureOf(native_types.{s}), \"{s}\"))\n" ++
                "        @compileError(\"native type '{s}' has wrong D-Bus signature\");\n", .{ use.hint, use.sig, use.hint });
        }
        try w.writeAll("}\n");
    }

    // ── write output file ────────────────────────────────────────────────────

    const out_file = try std.Io.Dir.cwd().createFile(io, dest_path.?, .{ .truncate = true });
    defer out_file.close(io);
    var fw = out_file.writer(io, &.{});
    try fw.interface.writeAll(out_buf.written());
}

// ─────────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn annotationValue(anns: []const Annotation, name: []const u8) ?[]const u8 {
    for (anns) |a| if (mem.eql(u8, a.name, name)) return a.value;
    return null;
}

/// Translates a single D-Bus type signature into a Zig type expression.
/// Writes directly to `w`.
fn writeZigType(sig: []const u8, w: *Io.Writer) !void {
    var i: usize = 0;
    try writeZigTypeInner(sig, &i, w);
}

fn writeZigTypeInner(sig: []const u8, i: *usize, w: *Io.Writer) !void {
    if (i.* >= sig.len) return;
    const c = sig[i.*];
    i.* += 1;
    switch (c) {
        'y' => try w.writeAll("u8"),
        'b' => try w.writeAll("bool"),
        'n' => try w.writeAll("i16"),
        'q' => try w.writeAll("u16"),
        'i' => try w.writeAll("i32"),
        'u' => try w.writeAll("u32"),
        'x' => try w.writeAll("i64"),
        't' => try w.writeAll("u64"),
        'd' => try w.writeAll("f64"),
        'h' => try w.writeAll("std.fs.File"),
        's' => try w.writeAll("zbus.types.String"),
        'o' => try w.writeAll("zbus.types.ObjectPath"),
        'g' => try w.writeAll("zbus.types.Signature"),
        'v' => try w.writeAll("zbus.types.DefaultVariant"),
        'a' => {
            if (i.* < sig.len and sig[i.*] == '{') {
                // dict: a{KV}
                i.* += 1; // skip '{'
                try w.writeAll("zbus.types.Dict(");
                try writeZigTypeInner(sig, i, w); // K
                try w.writeAll(", ");
                try writeZigTypeInner(sig, i, w); // V
                try w.writeAll(")");
                if (i.* < sig.len and sig[i.*] == '}') i.* += 1;
            } else {
                try w.writeAll("[]");
                try writeZigTypeInner(sig, i, w);
            }
        },
        '(' => {
            // struct
            try w.writeAll("struct { ");
            var field: usize = 0;
            while (i.* < sig.len and sig[i.*] != ')') {
                try w.print("field{}: ", .{field});
                try writeZigTypeInner(sig, i, w);
                try w.writeAll(", ");
                field += 1;
            }
            if (i.* < sig.len) i.* += 1; // skip ')'
            try w.writeAll("}");
        },
        else => try w.writeAll("anyopaque"), // unknown – compile error is better than panic
    }
}
