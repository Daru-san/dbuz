//! org.freedesktop.DBus.Stats
//!
//! Exposes internal statistics of the dbus-daemon.  All methods target
//! the daemon directly ("org.freedesktop.DBus", "/org/freedesktop/DBus").
//!
//! This interface is non-standard and may be absent on some implementations.

const std = @import("std");
const zbus = @import("../zbus.zig");

const Connection = zbus.types.Connection;
const Promise = zbus.types.Promise;
const DBusError = zbus.types.DBusError;
const String = zbus.types.String;
const Variant = zbus.types.DefaultVariant;
const Dict = zbus.types.Dict;

pub const interface_name: []const u8 = "org.freedesktop.DBus.Stats";

/// a{sv} – string-keyed variant map
pub const StatsMap = Dict(String, Variant);

const daemon_dest = "org.freedesktop.DBus";
const daemon_path = "/org/freedesktop/DBus";

/// Returns a map of statistics about the daemon itself.
pub fn GetStats(
    c: *Connection,
    gpa: ?std.mem.Allocator,
) !*Promise(StatsMap, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(daemon_dest)
        .setInterface(interface_name)
        .setPath(daemon_path)
        .setMember("GetStats");
    const p = try c.trackResponse(req, StatsMap, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}

/// Returns per-connection statistics.
/// `connection_name` is the unique name (":1.42") to query.
pub fn GetConnectionStats(
    c: *Connection,
    gpa: ?std.mem.Allocator,
    connection_name: []const u8,
) !*Promise(StatsMap, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(daemon_dest)
        .setInterface(interface_name)
        .setPath(daemon_path)
        .setMember("GetConnectionStats")
        .setSignature("s");
    const w = req.writer();
    try w.write(zbus.types.String{ .value = connection_name });
    const p = try c.trackResponse(req, StatsMap, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}

/// Returns the list of all active connections and their stats.
pub fn GetAllMatchRules(
    c: *Connection,
    gpa: ?std.mem.Allocator,
) !*Promise(Dict(String, []String), DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(daemon_dest)
        .setInterface(interface_name)
        .setPath(daemon_path)
        .setMember("GetAllMatchRules");
    const p = try c.trackResponse(req, Dict(String, []String), DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}
