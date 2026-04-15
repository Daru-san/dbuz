//! org.freedesktop.DBus.Peer
//!
//! Implemented by every D-Bus object.  Provides Ping and GetMachineId.

const std = @import("std");
const zbus = @import("../zbus.zig");

const Connection = zbus.types.Connection;
const Promise = zbus.types.Promise;
const DBusError = zbus.types.DBusError;
const String = zbus.types.String;

pub const interface_name: []const u8 = "org.freedesktop.DBus.Peer";

/// Calls Ping on `dest` at `object_path`.  The reply is empty (void).
pub fn Ping(
    c: *Connection,
    gpa: ?std.mem.Allocator,
    dest: []const u8,
    object_path: []const u8,
) !*Promise(void, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(dest)
        .setInterface(interface_name)
        .setPath(object_path)
        .setMember("Ping");
    const p = try c.trackResponse(req, void, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}

/// Returns the machine UUID of the peer (a hex string).
pub fn GetMachineId(
    c: *Connection,
    gpa: ?std.mem.Allocator,
    dest: []const u8,
    object_path: []const u8,
) !*Promise(String, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(dest)
        .setInterface(interface_name)
        .setPath(object_path)
        .setMember("GetMachineId");
    const p = try c.trackResponse(req, String, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}
