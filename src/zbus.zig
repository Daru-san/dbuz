//! zbus – a D-Bus library for Zig 0.16
//!
//! Connect to a bus:
//!
//!   var threaded = try std.Io.Threaded.init(gpa, .{});
//!   defer threaded.deinit();
//!   const io = threaded.io();
//!
//!   const conn = try zbus.connect(gpa, io, .Session);
//!   defer conn.deinit();
//!
//!   try conn.hello();
//!
//!   // Drive the event loop in a concurrent task:
//!   var loop = try std.Io.concurrent(io, zbus.types.Connection.run, .{conn});
//!   defer _ = loop.cancel(io);
//!
//! See examples/ for usage.

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const net = std.Io.net;
const mem = std.mem;

pub const codec = @import("codec.zig");
pub const transport = @import("transport.zig");

pub const types = struct {
    pub const String = @import("types/dbus_types.zig").String;
    pub const ObjectPath = @import("types/dbus_types.zig").ObjectPath;
    pub const Signature = @import("types/dbus_types.zig").Signature;
    pub const Message = @import("types/Message.zig");
    pub const Promise = @import("types/promise.zig").Promise;
    pub const PromiseOpaque = @import("types/promise.zig").PromiseOpaque;
    pub const DBusError = @import("types/promise.zig").DBusError;
    pub const Interface = @import("types/Interface.zig");
    pub const Proxy = @import("types/Proxy.zig");
    pub const Method = @import("types/dbus_types.zig").Method;
    pub const Property = @import("types/dbus_types.zig").Property;
    pub const PropertyStorage = @import("types/dbus_types.zig").PropertiesStorage;
    pub const Signal = @import("types/dbus_types.zig").Signal;
    pub const SignalManager = @import("types/dbus_types.zig").SignalManager;
    pub const MatchRule = @import("types/MatchRule.zig");
    pub const Dict = @import("types/dict.zig").from;
    pub const Variant = @import("types/dbus_types.zig").Variant;
    pub const DefaultVariant = Variant(&.{
        u8,          u16,        u32,    u64,       i16,        i32, i64, f64,
        std.fs.File, []const u8, String, Signature, ObjectPath,
    });
};

pub const proxies = struct {
    pub const DBus = @import("proxies/DBus.zig");
    pub const Properties = @import("proxies/properties.zig").Properties;
    pub const Introspectable = @import("proxies/Introspectable.zig");
    pub const Peer = @import("proxies/Peer.zig");
    pub const ObjectManager = @import("proxies/ObjectManager.zig");
    pub const Monitoring = @import("proxies/Monitoring.zig");
    pub const Stats = @import("proxies/Stats.zig");
};

pub const utils = struct {
    pub const dupeValue = @import("types/dbus_types.zig").dupeValue;
    pub const deinitValue = @import("types/dbus_types.zig").deinitValueRecursive;
    pub const isTypeSerializable = @import("types/dbus_types.zig").isTypeSerializable;
    pub const signatureOf = @import("types/dbus_types.zig").guessSignature;
};

pub const auth = @import("sasl.zig");

pub const Connection = @import("Connection.zig");

const logger = std.log.scoped(.zbus);

// ─────────────────────────────────────────────────────────────────────────────
//  Bus type
// ─────────────────────────────────────────────────────────────────────────────

pub const BusType = union(enum) {
    /// $DBUS_SESSION_BUS_ADDRESS
    Session,
    /// unix:path=/run/dbus/system_bus_socket
    System,
    /// Explicit D-Bus address string, e.g. "unix:path=/tmp/mybus"
    Custom: []const u8,
};

// ─────────────────────────────────────────────────────────────────────────────
//  Address resolution
// ─────────────────────────────────────────────────────────────────────────────

/// Resolves `bus` to a unix socket path.  Caller owns the returned slice.
fn resolveSocketPath(gpa: mem.Allocator, env_map: *std.process.Environ.Map, bus: BusType) ![]const u8 {
    switch (bus) {
        .System => return gpa.dupe(u8, "/run/dbus/system_bus_socket"),
        .Session => {
            const addr = env_map.get("DBUS_SESSION_BUS_ADDRESS") orelse
                return error.SessionBusAddressNotSet;
            return parseUnixPath(gpa, addr);
        },
        .Custom => |addr| return parseUnixPath(gpa, addr),
    }
}

/// Parses the first "unix:" entry from a D-Bus address string and returns
/// the socket path.  Supports "path=" and "abstract=" keys.
/// Caller owns returned slice.
fn parseUnixPath(gpa: mem.Allocator, address: []const u8) ![]const u8 {
    var addr_it = mem.splitScalar(u8, address, ';');
    while (addr_it.next()) |addr| {
        const colon = mem.indexOfScalar(u8, addr, ':') orelse continue;
        if (!mem.eql(u8, addr[0..colon], "unix")) continue;

        const desc = addr[colon + 1 ..];
        var kv_it = mem.splitScalar(u8, desc, ',');
        while (kv_it.next()) |kv| {
            const eq = mem.indexOfScalar(u8, kv, '=') orelse continue;
            const key = kv[0..eq];
            const val = kv[eq + 1 ..];

            if (mem.eql(u8, key, "path")) {
                return gpa.dupe(u8, val);
            }
            if (mem.eql(u8, key, "abstract")) {
                // Abstract namespace: NUL-prefixed
                const out = try gpa.alloc(u8, val.len + 1);
                out[0] = 0;
                @memcpy(out[1..], val);
                return out;
            }
        }
    }
    return error.UnresolvableBusAddress;
}

// ─────────────────────────────────────────────────────────────────────────────
//  connect
// ─────────────────────────────────────────────────────────────────────────────

/// Connects to the specified D-Bus, authenticates via SASL EXTERNAL,
/// and returns an initialized *Connection.
///
/// `io` must outlive the returned connection.
/// Caller owns the returned pointer; call `conn.deinit()` when done.
pub fn connect(gpa: mem.Allocator, io: Io, env_map: *std.process.Environ.Map, bus: BusType) !*Connection {
    const path = try resolveSocketPath(gpa, env_map, bus);
    defer gpa.free(path);

    logger.debug("connecting to '{s}'", .{path});

    const unix_addr = net.UnixAddress.init(path) catch
        return error.SocketPathTooLong;

    const stream = try unix_addr.connect(io);
    errdefer stream.close(io);

    const fd: posix.fd_t = stream.socket.handle;

    // SASL over the stream reader/writer (uses std.Io, no raw syscalls here)
    {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [512]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        try auth.authenticate(&sr.interface, &sw.interface);
    }

    logger.debug("authenticated fd={}", .{fd});

    return Connection.init(gpa, io, stream, fd);
}
