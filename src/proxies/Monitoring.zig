//! org.freedesktop.DBus.Monitoring
//!
//! Available on the dbus-daemon itself (destination "org.freedesktop.DBus",
//! path "/org/freedesktop/DBus").
//!
//! Turns the connection into a monitor: all matching messages are delivered
//! as read-only signals.  A monitoring connection cannot send ordinary
//! method calls after calling BecomeMonitor.
//!
//! Reference: https://dbus.freedesktop.org/doc/dbus-specification.html#bus-messages-become-monitor

const std = @import("std");
const zbus = @import("../zbus.zig");

const Connection = zbus.types.Connection;
const Promise = zbus.types.Promise;
const DBusError = zbus.types.DBusError;
const String = zbus.types.String;

pub const interface_name: []const u8 = "org.freedesktop.DBus.Monitoring";

/// Requests that this connection become a bus monitor.
///
/// `match_rules` is a slice of match-rule strings (same syntax as AddMatch).
/// Pass an empty slice to monitor everything.
/// `flags` is currently reserved; pass 0.
///
/// After this call succeeds the connection is in monitor mode and must not
/// send any further method calls.
pub fn BecomeMonitor(
    c: *Connection,
    gpa: ?std.mem.Allocator,
    match_rules: []const []const u8,
    flags: u32,
) !*Promise(void, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination("org.freedesktop.DBus")
        .setInterface(interface_name)
        .setPath("/org/freedesktop/DBus")
        .setMember("BecomeMonitor")
        .setSignature("asu");

    const w = req.writer();
    // Serialize as array-of-strings then uint32
    var string_slice = try (gpa orelse c.gpa).alloc(String, match_rules.len);
    defer (gpa orelse c.gpa).free(string_slice);
    for (match_rules, 0..) |rule, i|
        string_slice[i] = .{ .value = rule };
    try w.write(.{ string_slice, flags });

    const p = try c.trackResponse(req, void, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}
