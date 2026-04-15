//! examples/connect.zig
//! Connects to the session bus, says Hello, lists all bus names, exits.

const std = @import("std");
const zbus = @import("zbus");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const io = init.io;

    const conn = try zbus.connect(gpa, io, init.environ_map, .Session);
    defer conn.deinit(io);

    // Start the event loop on a concurrent task.
    var loop = try Io.concurrent(io, zbus.Connection.run, .{ conn, io });
    defer _ = loop.cancel(io) catch {};

    try conn.hello(io);
    std.log.info("unique name: {s}", .{conn.unique_name orelse "(none)"});

    // ListNames is a free function on the DBus proxy.
    const p = try zbus.proxies.DBus.ListNames(&conn.dbus_proxy, io);
    defer if (p.release() == 1) p.destroy(io);

    const result, const arena = try p.wait(io);
    defer {
        arena.deinit();
        arena.child_allocator.destroy(arena);
    }

    const names = try result;
    std.log.info("{} names on the bus:", .{names.len});
    for (names) |n| std.log.info("  {s}", .{n.value});
}
