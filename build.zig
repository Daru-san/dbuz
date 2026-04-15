const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dishwasher_dep = b.dependency("dishwasher", .{
        .target = target,
        .optimize = optimize,
    });

    const zbus_mod = b.addModule("zbus", .{
        .root_source_file = b.path("src/zbus.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &.{
            .{ .name = "dishwasher", .module = dishwasher_dep.module("dishwasher") },
        },
    });

    const scanner_host_mod = b.addModule("proxy-scanner", .{
        .root_source_file = b.path("src/codegen/xml_scanner.zig"),
        .target = b.resolveTargetQuery(.{}), // host
        .optimize = .Debug,
    });
    if (b.lazyDependency("dishwasher", .{})) |xml_dep|
        scanner_host_mod.addImport("dishwasher", xml_dep.module("dishwasher"));

    const scanner_exe = b.addExecutable(.{
        .name = "zbus-proxy-scanner",
        .root_module = scanner_host_mod,
    });
    b.installArtifact(scanner_exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zbus.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "dishwasher", .module = dishwasher_dep.module("dishwasher") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // ---------- examples ----------

    const ExampleDesc = struct { name: []const u8, file: []const u8 };
    const examples: []const ExampleDesc = &.{
        .{ .name = "connect", .file = "examples/connect.zig" },
        .{ .name = "watch_signals", .file = "examples/watch_signals.zig" },
        .{ .name = "server_iface", .file = "examples/server_interface.zig" },
    };

    const examples_step = b.step("examples", "Build all examples");
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .optimize = optimize,
                .target = target,
                .imports = &.{
                    .{ .name = "zbus", .module = zbus_mod },
                },
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  ProxyScanner – available to downstream build.zig via `b.dependency("zbus")`
// ─────────────────────────────────────────────────────────────────────────────

/// Compile-time proxy code generator.
///
/// Usage in a downstream build.zig:
///
///   const zbus_dep = b.dependency("zbus", .{});
///   var scanner = ProxyScanner.create(b, zbus_dep);
///
///   scanner.addProxy(.{
///       .interface_name = "org.bluez.Adapter1",   // exact interface name in XML
///       .output_name    = "BlueZAdapter1",         // Zig identifier for the generated type
///       .xml_path       = b.path("xml/org.bluez.adapter1.xml"),
///   });
///
///   const proxies_mod = scanner.generate();  // importable as @import("zbus_proxies")
///
pub const ProxyScanner = struct {
    b: *Build,
    zbus_mod: *Build.Module,
    scanner_exe: *Step.Compile,
    proxies: std.ArrayList(Entry),

    native_types_mod: ?*Build.Module = null,
    native_types_mod_name: ?[]const u8 = null,

    pub const ProxySpec = struct {
        /// The exact interface name that should be extracted from the XML file,
        /// e.g. "org.bluez.Adapter1".  The XML file may contain many interfaces.
        interface_name: []const u8,
        /// Zig identifier used for the generated top-level type.
        /// Defaults to the last component of `interface_name`.
        output_name: ?[]const u8 = null,
        /// Path to the D-Bus introspection XML.
        xml_path: Build.LazyPath,
    };

    const Entry = struct {
        spec: ProxySpec,
        module: *Build.Module,
    };

    pub fn create(b: *Build, zbus_dep: *Build.Dependency) *ProxyScanner {
        const self = b.allocator.create(ProxyScanner) catch @panic("OOM");
        self.* = .{
            .b = b,
            .zbus_mod = zbus_dep.module("zbus"),
            .scanner_exe = zbus_dep.artifact("zbus-proxy-scanner"),
            .proxies = std.ArrayList(Entry).init(b.allocator),
        };
        return self;
    }

    /// Override with a module that provides native Zig types for parameters
    /// annotated with `dev.zbus.TypeHint` in the XML.
    pub fn setNativeTypes(
        self: *ProxyScanner,
        name: []const u8,
        module: *Build.Module,
    ) void {
        self.native_types_mod_name = name;
        self.native_types_mod = module;
    }

    pub fn addProxy(self: *ProxyScanner, spec: ProxySpec) void {
        const b = self.b;

        const out_name = spec.output_name orelse blk: {
            // derive from interface name: last dot-separated component
            const iname = spec.interface_name;
            const dot = std.mem.lastIndexOfScalar(u8, iname, '.') orelse 0;
            break :blk if (dot == 0) iname else iname[dot + 1 ..];
        };

        const scan = b.addRunArtifact(self.scanner_exe);
        // -i  <xml file>
        scan.addArg("-i");
        scan.addFileArg(spec.xml_path);
        // -x  <interface name to extract>
        scan.addArg("-x");
        scan.addArg(spec.interface_name);
        // -n  <Zig output type name>
        scan.addArg("-n");
        scan.addArg(out_name);
        // -d  <output file>
        scan.addArg("-d");
        const out_file = scan.addOutputFileArg(b.fmt("{s}.zig", .{out_name}));
        // optional: -t <native types module name>
        if (self.native_types_mod_name) |ntm| {
            scan.addArg("-t");
            scan.addArg(ntm);
        }
        scan.setName(b.fmt("zbus: generate proxy {s}", .{spec.interface_name}));

        const mod = b.createModule(.{
            .root_source_file = out_file,
            .imports = &.{
                .{ .name = "zbus", .module = self.zbus_mod },
            },
        });
        if (self.native_types_mod) |ntm|
            mod.addImport(self.native_types_mod_name.?, ntm);

        self.proxies.append(.{ .spec = spec, .module = mod }) catch @panic("OOM");
    }

    /// Returns a synthetic module that re-exports every generated proxy under
    /// the name given by `output_name` (or the derived default).
    ///
    /// Import in your code as:
    ///   const proxies = @import("zbus_proxies");
    ///   const adapter = proxies.BlueZAdapter1;
    pub fn generate(self: *ProxyScanner) *Build.Module {
        const b = self.b;

        var source = std.ArrayList(u8).init(b.allocator);
        const w = source.writer(b.allocator);

        for (self.proxies.items) |entry| {
            const out_name = entry.spec.output_name orelse blk: {
                const iname = entry.spec.interface_name;
                const dot = std.mem.lastIndexOfScalar(u8, iname, '.') orelse 0;
                break :blk if (dot == 0) iname else iname[dot + 1 ..];
            };
            w.print("pub const {s} = @import(\"{s}\");\n", .{ out_name, out_name }) catch @panic("OOM");
        }

        const write_files = b.addWriteFiles();
        const root_file = write_files.add("zbus_proxies.zig", source.items);

        const mod = b.createModule(.{
            .root_source_file = root_file,
            .imports = &.{
                .{ .name = "zbus", .module = self.zbus_mod },
            },
        });
        for (self.proxies.items) |entry| {
            const out_name = entry.spec.output_name orelse blk: {
                const iname = entry.spec.interface_name;
                const dot = std.mem.lastIndexOfScalar(u8, iname, '.') orelse 0;
                break :blk if (dot == 0) iname else iname[dot + 1 ..];
            };
            mod.addImport(out_name, entry.module);
        }

        self.proxies.deinit();
        return mod;
    }
};
