//! examples/server_interface.zig
//!
//! Registers a D-Bus object at /com/example/Counter exposing:
//!   Methods:    Increment(u32), Reset()
//!   Property:   Value (u32, read-only)
//!   Signal:     ValueChanged(u32)
//!
//! Test from another terminal:
//!   busctl --user call com.example.Counter /com/example/Counter \
//!          com.example.Counter Increment u 5
//!   busctl --user get-property com.example.Counter /com/example/Counter \
//!          com.example.Counter Value

const std = @import("std");
const Io = std.Io;

const zbus = @import("zbus");
const Method = zbus.types.Method;
const Property = zbus.types.Property;
const Signal = zbus.types.Signal;

// ── Interface template ────────────────────────────────────────────────────────

const CounterTemplate = struct {
    pub const interface_name: []const u8 = "com.example.Counter";

    value: u32 = 0,

    pub const Increment = Method(incrementFn, .{ .argument_names = &.{"amount"} });
    fn incrementFn(self: *CounterTemplate, amount: u32) !void {
        self.value +|= amount;
    }

    pub const Reset = Method(resetFn, .{});
    fn resetFn(self: *CounterTemplate) !void {
        self.value = 0;
    }

    pub const Value = Property(u32, null, .{ .mode = .Read, .signal = .true });
    pub const ValueChanged = Signal(struct { u32 }, .{ .param_names = &.{"new_value"} });
};

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const io = init.io;

    const conn = try zbus.connect(gpa, io, init.environ_map, .Session);
    defer conn.deinit(io);

    var loop = try Io.concurrent(io, zbus.Connection.run, .{ conn, io });
    defer _ = loop.cancel(io) catch {};

    try conn.hello(io);
    std.log.info("unique name: {s}", .{conn.unique_name orelse ""});

    // Request a well-known name.
    {
        const p = try conn.dbus_proxy.RequestName(io, "com.example.Counter", .{ .do_not_queue = true });
        defer if (p.release() == 1) p.destroy(io);
        const result, _ = try p.wait(io);
        if (try result != .primary_owner) return error.NameNotGranted;
    }

    const Impl = zbus.types.Interface.AutoInterface(CounterTemplate, null);
    const impl = try Impl.create(gpa);
    defer if (impl.interface.release() == 1) impl.interface.deinit(gpa);

    impl.properties.Value = impl.data.value;

    try conn.registerInterface(io, impl, "/com/example/Counter", gpa);
    defer _ = conn.unregisterInterface(io, impl, "/com/example/Counter");

    std.log.info("Object at /com/example/Counter – press Ctrl-C to exit", .{});

    while (true) {
        try io.sleep(std.Io.Duration.fromNanoseconds(std.time.ns_per_s), .real);
        impl.properties.Value = impl.data.value;
    }
}
