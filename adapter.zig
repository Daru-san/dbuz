
const std  = @import("std");
const zbus = @import("zbus");

const Adapter = @This();

pub const interface_name: []const u8 = "org.bluez.Adapter1";

interface: zbus.types.Proxy = .{
    .connection  = null,
    .name        = interface_name,
    .object_path = null,
    .vtable      = &.{
        .handle_signal = &zbus.types.Proxy.noopSignalHandler,
        .destroy       = &destroy,
    },
},
properties: Properties = .{},
properties_manager: zbus.proxies.Properties(Properties, PropertyUnion, PropertyNames) = undefined,
signals: zbus.types.SignalManager(Signals) = undefined,
remote: []const u8 = "",
signals_listener_id: usize = 0,

pub fn StartDiscovery(self: *Adapter, gpa: ?std.mem.Allocator) !*zbus.types.Promise(void, zbus.types.DBusError) {
    if (self.interface.connection == null) return error.Unbound;
    const c = self.interface.connection.?;
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(self.remote)
           .setInterface(interface_name)
           .setPath(self.interface.object_path.?)
           .setMember("StartDiscovery");

    const promise = try c.trackResponse(req,
        @typeInfo(@typeInfo(@typeInfo(@TypeOf(StartDiscovery)).@"fn".return_type.?).error_union.payload).pointer.child.Type,
        zbus.types.DBusError);
    errdefer if (promise.release() == 1) promise.destroy();
    try c.sendMessage(&req);
    return promise;
}

pub fn SetDiscoveryFilter(self: *Adapter, gpa: ?std.mem.Allocator, @"properties": zbus.types.Dict(zbus.types.String, zbus.types.DefaultVariant)) !*zbus.types.Promise(void, zbus.types.DBusError) {
    if (self.interface.connection == null) return error.Unbound;
    const c = self.interface.connection.?;
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(self.remote)
           .setInterface(interface_name)
           .setPath(self.interface.object_path.?)
           .setMember("SetDiscoveryFilter")
           .setSignature("a{sv}");

    const bw = req.writer();
    try bw.write(.{ @"properties", });

    const promise = try c.trackResponse(req,
        @typeInfo(@typeInfo(@typeInfo(@TypeOf(SetDiscoveryFilter)).@"fn".return_type.?).error_union.payload).pointer.child.Type,
        zbus.types.DBusError);
    errdefer if (promise.release() == 1) promise.destroy();
    try c.sendMessage(&req);
    return promise;
}

pub fn StopDiscovery(self: *Adapter, gpa: ?std.mem.Allocator) !*zbus.types.Promise(void, zbus.types.DBusError) {
    if (self.interface.connection == null) return error.Unbound;
    const c = self.interface.connection.?;
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(self.remote)
           .setInterface(interface_name)
           .setPath(self.interface.object_path.?)
           .setMember("StopDiscovery");

    const promise = try c.trackResponse(req,
        @typeInfo(@typeInfo(@typeInfo(@TypeOf(StopDiscovery)).@"fn".return_type.?).error_union.payload).pointer.child.Type,
        zbus.types.DBusError);
    errdefer if (promise.release() == 1) promise.destroy();
    try c.sendMessage(&req);
    return promise;
}

pub fn RemoveDevice(self: *Adapter, gpa: ?std.mem.Allocator, @"device": zbus.types.ObjectPath) !*zbus.types.Promise(void, zbus.types.DBusError) {
    if (self.interface.connection == null) return error.Unbound;
    const c = self.interface.connection.?;
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(self.remote)
           .setInterface(interface_name)
           .setPath(self.interface.object_path.?)
           .setMember("RemoveDevice")
           .setSignature("o");

    const bw = req.writer();
    try bw.write(.{ @"device", });

    const promise = try c.trackResponse(req,
        @typeInfo(@typeInfo(@typeInfo(@TypeOf(RemoveDevice)).@"fn".return_type.?).error_union.payload).pointer.child.Type,
        zbus.types.DBusError);
    errdefer if (promise.release() == 1) promise.destroy();
    try c.sendMessage(&req);
    return promise;
}

pub fn GetDiscoveryFilters(self: *Adapter, gpa: ?std.mem.Allocator) !*zbus.types.Promise([]zbus.types.String, zbus.types.DBusError) {
    if (self.interface.connection == null) return error.Unbound;
    const c = self.interface.connection.?;
    var req = try c.startMessage(gpa);
    defer req.deinit();
    req.type = .method_call;
    _ = req.setDestination(self.remote)
           .setInterface(interface_name)
           .setPath(self.interface.object_path.?)
           .setMember("GetDiscoveryFilters");

    const promise = try c.trackResponse(req,
        @typeInfo(@typeInfo(@typeInfo(@TypeOf(GetDiscoveryFilters)).@"fn".return_type.?).error_union.payload).pointer.child.Type,
        zbus.types.DBusError);
    errdefer if (promise.release() == 1) promise.destroy();
    try c.sendMessage(&req);
    return promise;
}

pub fn destroy(i: *zbus.types.Proxy, alloc: std.mem.Allocator) void {
    const self: *Adapter = @fieldParentPtr("interface", i);
    if (!self.properties._inited) return;
    self.properties._mutex.lock();
    defer self.properties._mutex.unlock();
    inline for (@typeInfo(Properties).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "_")) continue;
        zbus.utils.deinitValue(alloc, @field(self.properties, field.name));
    }
}

pub const Properties = struct {
    _inited: bool = false,
    _mutex: std.Thread.Mutex = .{},
    @"Address": zbus.types.String = undefined,
    @"AddressType": zbus.types.String = undefined,
    @"Name": zbus.types.String = undefined,
    @"Alias": zbus.types.String = undefined,
    @"Class": u32 = undefined,
    @"Connectable": bool = undefined,
    @"Powered": bool = undefined,
    @"PowerState": zbus.types.String = undefined,
    @"Discoverable": bool = undefined,
    @"DiscoverableTimeout": u32 = undefined,
    @"Pairable": bool = undefined,
    @"PairableTimeout": u32 = undefined,
    @"Discovering": bool = undefined,
    @"UUIDs": []zbus.types.String = undefined,
    @"Modalias": zbus.types.String = undefined,
    @"Roles": []zbus.types.String = undefined,
    @"ExperimentalFeatures": []zbus.types.String = undefined,
    @"Manufacturer": u16 = undefined,
    @"Version": u8 = undefined,
};

pub const PropertyNames = enum {
    @"Address",
    @"AddressType",
    @"Name",
    @"Alias",
    @"Class",
    @"Connectable",
    @"Powered",
    @"PowerState",
    @"Discoverable",
    @"DiscoverableTimeout",
    @"Pairable",
    @"PairableTimeout",
    @"Discovering",
    @"UUIDs",
    @"Modalias",
    @"Roles",
    @"ExperimentalFeatures",
    @"Manufacturer",
    @"Version",
};

pub const PropertyUnion = zbus.types.Variant(&.{
    zbus.types.String,
    zbus.types.String,
    zbus.types.String,
    zbus.types.String,
    u32,
    bool,
    bool,
    zbus.types.String,
    bool,
    u32,
    bool,
    u32,
    bool,
    []zbus.types.String,
    zbus.types.String,
    []zbus.types.String,
    []zbus.types.String,
    u16,
    u8,
});

pub const Signals = struct {
};

pub fn bind(
    self:        *Adapter,
    alloc:       std.mem.Allocator,
    c:           *zbus.types.Connection,
    remote:      []const u8,
    object_path: []const u8,
    listener:    @FieldType(Adapter, "signals").Listener,
) !void {
    self.interface.connection  = c;
    self.interface.object_path = object_path;
    self.remote = remote;
    try self.properties_manager.bind(c, remote, interface_name, object_path, &self.properties, alloc);
    const lp = try c.registerListenerAsync(self, .{
        .interface = interface_name,
        .path      = object_path,
        .sender    = remote,
    }, &self.signals_listener_id, alloc);
    defer if (lp.release() == 1) lp.destroy();
    self.signals = .init(listener);
}
