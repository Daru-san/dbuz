//! org.freedesktop.DBus.ObjectManager
//!
//! Used by services that expose a tree of objects (e.g. BlueZ, NetworkManager).
//! `GetManagedObjects` returns the full snapshot; `InterfacesAdded` /
//! `InterfacesRemoved` keep it up to date.
//!
//! Typical usage:
//!
//!   var mgr = ObjectManager.bind(conn, .{
//!       .InterfacesAdded   = &myAddedHandler,
//!       .InterfacesRemoved = &myRemovedHandler,
//!       .userdata          = &my_state,
//!   });
//!   _ = try conn.registerListenerAsync(&mgr, .{
//!       .interface = ObjectManager.interface_name,
//!       .path      = "/",
//!       .sender    = "org.bluez",
//!   }, null, gpa);
//!
//!   // Fetch the initial snapshot
//!   const p = try ObjectManager.GetManagedObjects(conn, null, "org.bluez", "/");
//!   defer if (p.release() == 1) p.destroy();
//!   const objs, _ = try p.wait(null);

const std = @import("std");
const zbus = @import("../zbus.zig");

const Connection = zbus.types.Connection;
const Promise = zbus.types.Promise;
const DBusError = zbus.types.DBusError;
const Signal = zbus.types.Signal;
const SignalManager = zbus.types.SignalManager;
const Proxy = zbus.types.Proxy;
const Message = zbus.types.Message;
const String = zbus.types.String;
const ObjectPath = zbus.types.ObjectPath;
const Variant = zbus.types.DefaultVariant;
const Dict = zbus.types.Dict;
const mem = std.mem;

pub const interface_name: []const u8 = "org.freedesktop.DBus.ObjectManager";

// ─────────────────────────────────────────────────────────────────────────────
//  Wire types
// ─────────────────────────────────────────────────────────────────────────────

/// a{sa{sv}}  –  interface name → property dict
pub const InterfaceMap = Dict(String, Dict(String, Variant));
/// a{oa{sa{sv}}}  –  object path → interface map
pub const ManagedObjects = Dict(ObjectPath, InterfaceMap);

// ─────────────────────────────────────────────────────────────────────────────
//  Signals
// ─────────────────────────────────────────────────────────────────────────────

pub const Signals = struct {
    /// Emitted when a new object (with one or more interfaces) is added.
    /// Payload: (object_path, interfaces_and_properties)
    pub const InterfacesAdded = Signal(
        struct { ObjectPath, InterfaceMap },
        .{ .param_names = &.{ "object_path", "interfaces_and_properties" } },
    );
    /// Emitted when one or more interfaces are removed from an object.
    /// Payload: (object_path, interfaces)
    pub const InterfacesRemoved = Signal(
        struct { ObjectPath, []String },
        .{ .param_names = &.{ "object_path", "interfaces" } },
    );
};

// ─────────────────────────────────────────────────────────────────────────────
//  Proxy struct
// ─────────────────────────────────────────────────────────────────────────────

const ObjectManager = @This();

interface: Proxy = .{
    .connection = null,
    .name = interface_name,
    .object_path = null,
    .vtable = &.{
        .handle_signal = &handleSignal,
        .destroy = &Proxy.noopDestroy,
    },
},
signals: SignalManager(Signals),

fn handleSignal(p: *Proxy, m: *Message, gpa: mem.Allocator) Proxy.Error!void {
    const self: *ObjectManager = @fieldParentPtr("interface", p);
    return self.signals.handle(m, gpa) catch error.HandlingFailed;
}

pub fn bind(c: *Connection, listener: SignalManager(Signals).Listener) ObjectManager {
    _ = c;
    return .{ .signals = .init(listener) };
}

// ─────────────────────────────────────────────────────────────────────────────
//  Methods
// ─────────────────────────────────────────────────────────────────────────────

pub fn GetManagedObjects(
    c: *Connection,
    gpa: ?std.mem.Allocator,
    dest: []const u8,
    object_path: []const u8,
) !*Promise(ManagedObjects, DBusError) {
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(dest)
        .setInterface(interface_name)
        .setPath(object_path)
        .setMember("GetManagedObjects");
    const p = try c.trackResponse(req, ManagedObjects, DBusError);
    errdefer if (p.release() == 1) p.destroy();
    try c.sendMessage(&req);
    return p;
}
