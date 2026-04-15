//! An authenticated D-Bus connection.
//!
//! There is no internal thread.  Drive the event loop with:
//!
//!   var loop = try std.Io.concurrent(io, Connection.run, .{conn});
//!   defer _ = loop.cancel(io);
//!
//! Or manually:
//!
//!   while (try conn.advance(null)) |pair|
//!       try conn.handleMessage(pair);

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const atomic = std.atomic;
const Io = std.Io;
const net = std.Io.net;
const Thread = std.Thread;

const tree_mod = @import("tree.zig");
const dbus_types = @import("types/dbus_types.zig");
const String = dbus_types.String;
const zbus = @import("zbus.zig");
const transport = zbus.transport;
const Message = zbus.types.Message;
const Promise = zbus.types.Promise;
const PromiseOpaque = zbus.types.PromiseOpaque;
const DBusError = zbus.types.DBusError;
const Interface = zbus.types.Interface;
const MatchRule = zbus.types.MatchRule;
const Proxy = zbus.types.Proxy;

const Connection = @This();

const logger = std.log.scoped(.zbus_conn);

const TreeNode = tree_mod.Tree(InterfaceManaged).Branch.Node;

const default_buf: usize = 8192;

// ─────────────────────────────────────────────────────────────────────────────
//  Internal types
// ─────────────────────────────────────────────────────────────────────────────

const InterfaceManaged = struct {
    interface: *Interface,
    allocator: mem.Allocator,
};

const ListenerManaged = struct {
    proxy: *Proxy,
    rule: MatchRule,
    allocator: mem.Allocator,
    conn: *Connection,
    id: usize,
};

// ─────────────────────────────────────────────────────────────────────────────
//  Fields
// ─────────────────────────────────────────────────────────────────────────────

gpa: mem.Allocator,
io: Io,
stream: net.Stream,
fd: posix.fd_t,

reader: transport.Reader,

fd_queue: std.ArrayList(i32),
next_serial: atomic.Value(u32) = .init(1),
next_listener_id: atomic.Value(usize) = .init(1),

pending_message: ?Message = null,
pending_arena: ?*std.heap.ArenaAllocator = null,

tracker: struct {
    hash: std.AutoArrayHashMapUnmanaged(u32, *PromiseOpaque) = .{},
    mutex: Io.Mutex = .init,
} = .{},

object_tree: struct {
    mutex: Io.Mutex,
    tree: tree_mod.Tree(InterfaceManaged),
},

listeners: struct {
    mutex: Io.Mutex,
    list: std.ArrayListUnmanaged(ListenerManaged),
},

dbus_proxy: zbus.proxies.DBus = undefined,
unique_name: ?[]const u8 = null,

state: enum { Connected, Disconnected } = .Connected,
refcount: atomic.Value(usize) = .init(1),

// ─────────────────────────────────────────────────────────────────────────────
//  Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

pub fn init(gpa: mem.Allocator, io: Io, stream: net.Stream, fd: posix.fd_t) !*Connection {
    const reader = try transport.Reader.init(gpa, fd, default_buf);
    const c = try gpa.create(Connection);
    errdefer gpa.destroy(c);
    c.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .fd = fd,
        .reader = reader,
        .fd_queue = std.ArrayList(i32).empty,
        .object_tree = .{ .mutex = .init, .tree = .empty },
        .listeners = .{ .mutex = .init, .list = .empty },
    };
    logger.debug("{*} created fd={}", .{ c, fd });
    return c;
}

pub fn reference(c: *Connection) *Connection {
    _ = c.refcount.fetchAdd(1, .seq_cst);
    return c;
}

pub fn release(c: *Connection) usize {
    return c.refcount.fetchSub(1, .seq_cst);
}

pub fn disconnect(c: *Connection, io: Io) void {
    if (c.state == .Disconnected) return;
    c.state = .Disconnected;
    c.stream.shutdown(c.io, .both) catch {};

    c.tracker.mutex.lockUncancelable(io);
    defer c.tracker.mutex.unlock(io);
    var it = c.tracker.hash.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.*;
        p.vtable.errored(p, io, error.Disconnected);
        if (p.vtable.release(p) == 1) p.vtable.destroy(p, io);
    }
    c.tracker.hash.deinit(c.gpa);
    c.tracker.hash = .{};
}

pub fn deinit(c: *Connection, io: Io) void {
    c.disconnect(io);

    if (c.unique_name) |n| c.gpa.free(n);

    for (c.fd_queue.items) |fd| _ = std.os.linux.close(fd);
    c.fd_queue.deinit(c.gpa);

    {
        c.listeners.mutex.lockUncancelable(io);
        defer c.listeners.mutex.unlock(io);
        for (c.listeners.list.items) |lm|
            if (lm.proxy.release() == 1) lm.proxy.destroy(lm.allocator);
        c.listeners.list.deinit(c.gpa);
    }
    {
        c.object_tree.mutex.lockUncancelable(io);
        defer c.object_tree.mutex.unlock(io);
        c.object_tree.tree.deinit(c.gpa);
    }

    if (c.pending_message) |*m| m.deinit();
    if (c.pending_arena) |a| {
        a.deinit();
        a.child_allocator.destroy(a);
    }

    c.tracker.hash.deinit(c.gpa);
    c.reader.deinit();
    c.stream.close(c.io);
    c.gpa.destroy(c);
}

// ─────────────────────────────────────────────────────────────────────────────
//  hello
// ─────────────────────────────────────────────────────────────────────────────

fn helloCb(
    _: *Promise(String, DBusError),
    io: Io,
    result: DBusError!String,
    _: ?*std.heap.ArenaAllocator,
    userdata: ?*anyopaque,
) void {
    const c: *Connection = @ptrCast(@alignCast(userdata));
    const name = result catch |err| {
        logger.err("Hello failed: {s}", .{@errorName(err)});
        return;
    };
    c.unique_name = c.gpa.dupe(u8, name.value) catch return;

    // Initialise the DBus proxy and subscribe to its signals.
    c.dbus_proxy = zbus.proxies.DBus.bind(c, .{
        .NameOwnerChanged = null,
        .NameAcquired = null,
        .NameLost = null,
        .ActivatableServicesChanged = null,
        .userdata = null,
    });
    const p = c.registerListenerAsync(
        io,
        &c.dbus_proxy,
        .{ .interface = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus" },
        null,
        c.gpa,
    ) catch return;
    if (p.release() == 1) p.destroy(io);

    logger.debug("unique name: {s}", .{name.value});
}

pub fn helloAsync(c: *Connection, io: std.Io) !*Promise(String, DBusError) {
    const p = try zbus.proxies.DBus.Hello(c, io);
    p.setupCallback(io, &helloCb, c);
    return p;
}

/// Blocking Hello.  Requires the event loop (`run`) to be active on another task.
pub fn hello(c: *Connection, io: std.Io) !void {
    const p = try c.helloAsync(io);
    defer if (p.release() == 1) p.destroy(io);
    const result, _ = try p.wait(io);
    _ = result catch return error.HelloFailed;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Message helpers
// ─────────────────────────────────────────────────────────────────────────────

pub fn startMessage(c: *Connection, gpa: ?mem.Allocator) !Message {
    const serial = c.next_serial.fetchAdd(1, .seq_cst);
    var m = try Message.initWriting(gpa orelse c.gpa, .little, true);
    m.serial = serial;
    return m;
}

pub fn sendMessage(c: *Connection, m: *Message) !void {
    var tw = try transport.Writer.init(c.gpa, c.fd, default_buf);
    defer tw.deinit();

    var fds: []const i32 = &.{};
    try m.write(&tw.interface, &fds);
    if (fds.len > 0) try tw.attachFds(fds);
    try tw.interface.flush();

    logger.debug("[{}] → {?s}@{?s}.{?s}", .{
        m.serial,
        m.fields.path,
        m.fields.interface,
        m.fields.member,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Promise tracking
// ─────────────────────────────────────────────────────────────────────────────

pub fn trackResponse(
    c: *Connection,
    io: Io,
    message: Message,
    comptime T: type,
    comptime E: type,
) !*Promise(T, E) {
    const p = try Promise(T, E).create(c.gpa);
    errdefer p.destroy(io);

    c.tracker.mutex.lockUncancelable(io);
    defer c.tracker.mutex.unlock(io);

    const entry = try c.tracker.hash.getOrPut(c.gpa, message.serial);
    if (entry.found_existing) return error.SerialAlreadyTracked;
    entry.value_ptr.* = &p.interface;

    return p.reference();
}

pub fn promiseTimedOut(c: *Connection, serial: u32) void {
    c.tracker.mutex.lock();
    defer c.tracker.mutex.unlock();
    const entry = c.tracker.hash.fetchSwapRemove(serial) orelse return;
    const p = entry.value;
    p.vtable.timedout(p);
    if (p.vtable.release(p) == 1) p.vtable.destroy(p);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Event loop
// ─────────────────────────────────────────────────────────────────────────────

/// Returns one complete message when ready, null when more data is needed.
/// The caller owns both the Message and *ArenaAllocator; pass them to
/// `handleMessage` which takes ownership.
pub fn advance(c: *Connection, gpa: ?mem.Allocator) !?struct { Message, *std.heap.ArenaAllocator } {
    if (c.state == .Disconnected) return error.Disconnected;

    const alloc = gpa orelse c.gpa;
    const r = &c.reader.interface;

    // Collect any pending ancillary data (file descriptors) from the last recv.
    if (c.reader.pendingCmsgType()) |scm| {
        switch (scm) {
            .RIGHTS => {
                var rights: [128]i32 = undefined;
                const n = c.reader.takeFds(&rights) catch 0;
                c.fd_queue.appendSlice(c.gpa, rights[0..n]) catch {};
            },
            else => c.reader.discardCmsg(),
        }
    }

    // Start a new message or continue an in-progress one.
    const msg: *Message = if (c.pending_message) |*pm| pm else blk: {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }

        c.pending_message = try Message.initReading(arena.allocator(), r, &c.fd_queue);
        c.pending_arena = arena;
        break :blk &c.pending_message.?;
    };

    while (true) {
        if (msg.isComplete()) {
            const m = c.pending_message.?;
            const a = c.pending_arena.?;
            c.pending_message = null;
            c.pending_arena = null;
            logger.debug("[{}] ← {?s}@{?s}.{?s}", .{
                m.serial, m.fields.path, m.fields.interface, m.fields.member,
            });
            return .{ m, a };
        }
        _ = msg.continueReading() catch |err| switch (err) {
            error.ReadFailed => break,
            else => return err,
        };
    }
    return null;
}

/// Blocking event-loop function.  Pass to `std.Io.concurrent`:
///
///   var f = try std.Io.concurrent(io, Connection.run, .{conn});
///   defer _ = f.cancel(io);
pub fn run(c: *Connection, io: Io) !void {
    logger.debug("run() started", .{});
    while (c.state == .Connected) {
        const pair = c.advance(null) catch |err| switch (err) {
            error.Disconnected, error.EndOfStream => break,
            else => return err,
        };
        if (pair) |p| c.handleMessage(io, p) catch |err|
            logger.warn("handleMessage: {s}", .{@errorName(err)});
    }
    logger.debug("run() ended", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
//  handleMessage
// ─────────────────────────────────────────────────────────────────────────────

pub fn handleMessage(c: *Connection, io: Io, pair: struct { Message, *std.heap.ArenaAllocator }) !void {
    var message, const arena_ptr = pair;
    var owned = true;
    defer if (owned) {
        message.deinit();
        arena_ptr.deinit();
        arena_ptr.child_allocator.destroy(arena_ptr);
    };

    const arena = arena_ptr.allocator();

    switch (message.type) {
        .method_response, .@"error" => {
            const serial = message.fields.reply_serial orelse return;

            c.tracker.mutex.lockUncancelable(io);
            const entry = c.tracker.hash.fetchSwapRemove(serial);
            c.tracker.mutex.unlock(io);

            const p = (entry orelse return).value;
            p.vtable.received(p, io, message, arena_ptr);
            if (p.vtable.release(p) == 1) p.vtable.destroy(p, io);
            owned = false;
        },

        .method_call => {
            if (message.fields.path == null or
                message.fields.interface == null or
                message.fields.member == null) return;

            const iface_name = message.fields.interface.?;

            if (mem.eql(u8, iface_name, "org.freedesktop.DBus.Properties")) {
                c.handleProperties(io, &message, arena) catch {};
                return;
            }
            if (mem.eql(u8, iface_name, "org.freedesktop.DBus.Introspectable")) {
                c.handleIntrospection(io, &message, arena) catch {};
                return;
            }

            c.object_tree.mutex.lockUncancelable(io);
            defer c.object_tree.mutex.unlock(io);

            const key = try tree_mod.runtimePathWithLastComponent(message.fields.path.?, iface_name, arena);
            if (c.object_tree.tree.get(key)) |node| {
                var reply = node.leaf.interface.vtable.method_call(
                    node.leaf.interface,
                    &message,
                    arena,
                ) catch return;
                if (reply) |*r| try c.sendMessage(r);
            } else {
                var err_msg = try c.startMessage(arena);
                err_msg.type = .@"error";
                err_msg.fields = .{
                    .destination = message.fields.sender,
                    .reply_serial = message.serial,
                    .error_name = "org.freedesktop.DBus.Error.UnknownInterface",
                };
                try c.sendMessage(&err_msg);
            }
        },

        .signal => {
            if (message.fields.path == null or
                message.fields.interface == null or
                message.fields.member == null) return;

            c.listeners.mutex.lockUncancelable(io);
            defer c.listeners.mutex.unlock(io);
            for (c.listeners.list.items) |lm| {
                if (!lm.rule.match(&message)) continue;
                lm.proxy.handleSignal(&message, arena) catch {};
            }
        },

        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Properties / Introspection
// ─────────────────────────────────────────────────────────────────────────────

fn handleProperties(c: *Connection, io: Io, m: *Message, arena: mem.Allocator) !void {
    // Body of Properties.{Get,Set,GetAll}: first field is the interface name.
    const r = try m.reader();
    const iname = (try r.read(String, arena)).value;
    const key = try tree_mod.runtimePathWithLastComponent(m.fields.path.?, iname, arena);

    c.object_tree.mutex.lockUncancelable(io);
    defer c.object_tree.mutex.unlock(io);

    if (c.object_tree.tree.get(key)) |node| {
        var reply = try node.leaf.interface.vtable.property_op(node.leaf.interface, io, m, arena);
        if (reply) |*rp| try c.sendMessage(rp);
    }
}

fn handleIntrospection(c: *Connection, io: Io, m: *Message, arena: mem.Allocator) !void {
    c.object_tree.mutex.lockUncancelable(io);
    defer c.object_tree.mutex.unlock(io);

    // For "/" return root's direct children; for any other path look up the node.
    const maybe_node: ?TreeNode = if (mem.eql(u8, m.fields.path.?, "/"))
        c.object_tree.tree.root
    else blk: {
        const key = try tree_mod.runtimeKey(m.fields.path.?, arena);
        break :blk c.object_tree.tree.get(key);
    };

    if (maybe_node == null) {
        var err_msg = try c.startMessage(arena);
        err_msg.type = .@"error";
        err_msg.fields = .{
            .destination = m.fields.sender,
            .reply_serial = m.serial,
            .error_name = "org.freedesktop.DBus.Error.UnknownObject",
        };
        return c.sendMessage(&err_msg);
    }

    var xml_buf = Io.Writer.Allocating.init(arena);
    defer xml_buf.deinit();
    const xw = &xml_buf.writer;

    try xw.writeAll("<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n" ++
        "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>\n");

    switch (maybe_node.?) {
        .branch => |b| {
            var it = b.branches.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.*) {
                .leaf => |l| try xw.writeAll(l.interface.description),
                .branch => {
                    var tmp: [256]u8 = undefined;
                    try xw.writeAll(try std.fmt.bufPrint(&tmp, "  <node name=\"{s}\"/>\n", .{entry.key_ptr.*}));
                },
            };
        },
        .leaf => return error.PathIsLeafNotObject,
    }
    try xw.writeAll("</node>\n");

    var reply = try c.startMessage(arena);
    reply.type = .method_response;
    reply.fields = .{
        .destination = m.fields.sender,
        .reply_serial = m.serial,
        .signature = "s",
    };
    try reply.writer().write(String{ .value = xml_buf.written() });
    return c.sendMessage(&reply);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Object registration
// ─────────────────────────────────────────────────────────────────────────────

pub fn registerInterface(
    c: *Connection,
    io: Io,
    impl: anytype,
    comptime path: []const u8,
    gpa: mem.Allocator,
) !void {
    _ = impl.interface.reference();
    errdefer if (impl.interface.release() == 1) impl.interface.deinit(gpa);

    c.object_tree.mutex.lockUncancelable(io);
    defer c.object_tree.mutex.unlock(io);

    const key = tree_mod.comptimePathWithLastComponent(path, @TypeOf(impl.*).interface_name);
    try c.object_tree.tree.insert(c.gpa, key, .{ .interface = &impl.interface, .allocator = gpa });
    impl.interface.bind(c, path);
}

pub fn unregisterInterface(c: *Connection, io: Io, impl: anytype, comptime path: []const u8) bool {
    const key = tree_mod.comptimePathWithLastComponent(path, @TypeOf(impl.*).interface_name);
    c.object_tree.mutex.lockUncancelable(io);
    defer c.object_tree.mutex.unlock(io);
    const node = c.object_tree.tree.get(key) orelse return false;
    const managed = node.leaf;
    if (managed.interface.release() == 1) managed.interface.deinit(managed.allocator);
    return c.object_tree.tree.remove(c.gpa, key);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Listener registration
// ─────────────────────────────────────────────────────────────────────────────

fn listenerAddCb(
    _: *Promise(void, DBusError),
    io: Io,
    result: DBusError!void,
    _: ?*std.heap.ArenaAllocator,
    userdata: ?*anyopaque,
) void {
    const lm: *ListenerManaged = @ptrCast(@alignCast(userdata));
    _ = result catch |err| {
        logger.err("AddMatch failed: {s}", .{@errorName(err)});
        lm.conn.listeners.mutex.lockUncancelable(io);
        defer lm.conn.listeners.mutex.unlock(io);
        for (lm.conn.listeners.list.items, 0..) |item, i| {
            if (item.id != lm.id) continue;
            if (item.proxy.release() == 1) item.proxy.destroy(item.allocator);
            _ = lm.conn.listeners.list.swapRemove(i);
            return;
        }
    };
}

pub fn registerListenerAsync(
    c: *Connection,
    io: Io,
    impl: anytype,
    rule: MatchRule,
    id: ?*usize,
    gpa: mem.Allocator,
) !*Promise(void, DBusError) {
    c.listeners.mutex.lockUncancelable(io);
    defer c.listeners.mutex.unlock(io);

    _ = impl.interface.reference();
    errdefer if (impl.interface.release() == 1) impl.interface.destroy(gpa);

    const rule_str = try rule.string(gpa);
    defer gpa.free(rule_str);

    const listener = try c.listeners.list.addOne(c.gpa);
    listener.* = .{
        .proxy = &impl.interface,
        .allocator = gpa,
        .rule = rule,
        .conn = c,
        .id = c.next_listener_id.fetchAdd(1, .monotonic),
    };
    if (id) |ptr| ptr.* = listener.id;

    const p = try c.dbus_proxy.AddMatch(io, rule_str);
    p.setupCallback(io, &listenerAddCb, listener);
    return p;
}

pub fn registerListener(
    c: *Connection,
    io: Io,
    impl: anytype,
    rule: MatchRule,
    gpa: mem.Allocator,
) !usize {
    var id: usize = undefined;
    const p = try c.registerListenerAsync(io, impl, rule, &id, gpa);
    defer if (p.release() == 1) p.destroy(io);
    const result, _ = try p.wait(io);
    _ = result catch return error.AddMatchFailed;
    return id;
}

pub fn unregisterListener(c: *Connection, io: Io, id: usize) void {
    c.listeners.mutex.lockUncancelable(io);
    defer c.listeners.mutex.unlock(io);
    for (c.listeners.list.items, 0..) |lm, i| {
        if (lm.id != id) continue;
        if (lm.proxy.release() == 1) lm.proxy.destroy(lm.allocator);
        _ = c.listeners.list.swapRemove(i);
        // Best-effort RemoveMatch; ignore errors.
        const rule_str = lm.rule.string(c.gpa) catch return;
        defer c.gpa.free(rule_str);
        const p = c.dbus_proxy.RemoveMatch(io, rule_str) catch return;
        if (p.release() == 1) p.destroy(io);
        return;
    }
}

pub fn exportFd(c: *const Connection) posix.fd_t {
    return c.fd;
}
