//! examples/watch_signals.zig
//! Watches NameOwnerChanged for 10 seconds.

const std = @import("std");
const zbus = @import("zbus");
const Io = std.Io;

const String = zbus.types.String;

fn onNameOwnerChanged(
    name: String,
    old_owner: String,
    new_owner: String,
    _: ?*anyopaque,
) void {
    std.log.info("NameOwnerChanged: '{s}'  {s} → {s}", .{
        name.value,
        if (old_owner.value.len == 0) "(none)" else old_owner.value,
        if (new_owner.value.len == 0) "(none)" else new_owner.value,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const io = init.io;

    const conn = try zbus.connect(gpa, io, init.environ_map, .Session);
    defer conn.deinit(io);

    var loop = try Io.concurrent(io, zbus.Connection.run, .{ conn, io });
    defer _ = loop.cancel(io) catch {};

    try conn.hello(io);

    var dbus = zbus.proxies.DBus.bind(conn, .{
        .NameOwnerChanged = &onNameOwnerChanged,
        .NameAcquired = null,
        .NameLost = null,
        .ActivatableServicesChanged = null,
        .userdata = null,
    });

    const listener_id = try conn.registerListener(io, &dbus, .{
        .interface = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .member = "NameOwnerChanged",
    }, gpa);
    defer conn.unregisterListener(io, listener_id);

    std.log.info("Watching NameOwnerChanged for 10 s …", .{});
    try io.sleep(Io.Duration.fromNanoseconds(10 * std.time.ns_per_s), .real);
    std.log.info("Done.", .{});
}
