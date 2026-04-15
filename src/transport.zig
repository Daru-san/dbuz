//! Low-level transport using recvmsg/sendmsg for Unix SCM_RIGHTS (FD passing).
//!
//! std.Io.net.Stream's readVec path uses readv, which silently drops ancillary
//! data (SCM_RIGHTS, SCM_CREDENTIALS).  We hold the raw fd and call the POSIX
//! messaging syscalls ourselves.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Io = std.Io;

const cmsg = @import("cmsg.zig");
const posixe = @import("posix_extended.zig");

const logger = std.log.scoped(.zbus_transport);

// ─────────────────────────────────────────────────────────────────────────────
//  Reader
// ─────────────────────────────────────────────────────────────────────────────

pub const Reader = struct {
    fd: posix.fd_t,
    buf: []u8,
    allocator: mem.Allocator,
    interface: Io.Reader,

    // 512 bytes can hold >100 SCM_RIGHTS file descriptors.
    ctrl_buf: [512]u8 align(@alignOf(cmsg.cmsghdr)) = undefined,
    ctrl_used: bool = false,

    pub fn init(allocator: mem.Allocator, fd: posix.fd_t, buf_size: usize) !Reader {
        const buf = try allocator.alloc(u8, buf_size);
        return .{
            .fd = fd,
            .buf = buf,
            .allocator = allocator,
            .interface = .{
                .buffer = buf,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVecImpl,
                },
            },
        };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.buf);
    }

    // ── Io.Reader vtable ──────────────────────────────────────────────────────

    fn readVecImpl(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        return r.doRecv(data);
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var bufs: [1][]u8 = .{dest};
        const n = try readVecImpl(io_r, &bufs);
        io_w.advance(n);
        return n;
    }

    // ── syscall ───────────────────────────────────────────────────────────────

    fn doRecv(self: *Reader, data: [][]u8) Io.Reader.Error!usize {
        if (!posixe.has_recvmsg) return self.doRecvFallback(data);

        var iovecs: [8]posix.iovec = undefined;
        var iov_n: usize = 0;
        var data_size: usize = 0;
        for (data) |buf| {
            if (iov_n >= iovecs.len) break;
            if (buf.len == 0) continue;
            iovecs[iov_n] = .{ .base = buf.ptr, .len = buf.len };
            iov_n += 1;
            data_size += buf.len;
        }
        if (iov_n == 0) return error.ReadFailed;

        var msghdr = posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = @panic("Don't know what to do here!"),
            .iovlen = iov_n,
            .control = @ptrCast(&self.ctrl_buf),
            .controllen = self.ctrl_buf.len,
            .flags = 0,
        };

        const rc: isize = @bitCast(posixe.recvmsg(self.fd, &msghdr, 0));
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) return error.EndOfStream;

        self.ctrl_used = msghdr.controllen > 0;

        const n: usize = @intCast(rc);
        // If the kernel wrote into trailing buffer space, advance end pointer.
        if (n > data_size) {
            self.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn doRecvFallback(self: *Reader, data: [][]u8) Io.Reader.Error!usize {
        var iovecs: [8]posix.iovec = undefined;
        var iov_n: usize = 0;
        for (data) |buf| {
            if (iov_n >= iovecs.len) break;
            if (buf.len == 0) continue;
            iovecs[iov_n] = .{ .base = buf.ptr, .len = buf.len };
            iov_n += 1;
        }
        if (iov_n == 0) return error.ReadFailed;
        const rc = posix.readv(self.fd, iovecs[0..iov_n]) catch
            return error.ReadFailed;
        if (rc == 0) return error.EndOfStream;
        return rc;
    }

    // ── Ancillary data helpers ────────────────────────────────────────────────

    pub fn pendingCmsgType(self: *const Reader) ?cmsg.SCM {
        if (!self.ctrl_used) return null;
        const hdr = cmsg.bufferAsCmsghdr(@ptrCast(@constCast(&self.ctrl_buf)));
        return @enumFromInt(hdr.type);
    }

    pub fn takeFds(self: *Reader, out: []i32) !usize {
        if (!self.ctrl_used) return error.NoPendingControl;
        const hdr = cmsg.bufferAsCmsghdr(&self.ctrl_buf);
        const count = try cmsg.getRightsLength(hdr);
        if (out.len < count) return error.BufferTooSmall;
        try cmsg.getRights(hdr, out[0..count]);
        self.ctrl_used = false;
        return count;
    }

    pub fn discardCmsg(self: *Reader) void {
        if (!self.ctrl_used) return;
        defer self.ctrl_used = false;

        const hdr = cmsg.bufferAsCmsghdr(&self.ctrl_buf);
        if (@as(cmsg.SCM, @enumFromInt(hdr.type)) == .RIGHTS) {
            var fds: [128]i32 = undefined;
            const n = cmsg.getRightsLength(hdr) catch return;
            cmsg.getRights(hdr, fds[0..n]) catch return;
            for (fds[0..n]) |fd| _ = std.os.linux.close(fd);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
//  Writer
// ─────────────────────────────────────────────────────────────────────────────

pub const Writer = struct {
    fd: posix.fd_t,
    allocator: mem.Allocator,
    /// Accumulates bytes between drain calls; flushed via sendmsg.
    acc: std.ArrayList(u8),
    interface: Io.Writer,

    ctrl_buf: [512]u8 align(@alignOf(cmsg.cmsghdr)) = undefined,
    ctrl_len: usize = 0,

    pub fn init(allocator: mem.Allocator, fd: posix.fd_t, capacity: usize) !Writer {
        return .{
            .fd = fd,
            .allocator = allocator,
            .acc = try std.ArrayList(u8).initCapacity(allocator, capacity),
            .interface = .{
                // buffer = &.{} → unbuffered: every Io.Writer.write call goes
                // straight to drain (our acc ArrayList).
                .buffer = &.{},
                .end = 0,
                .vtable = &.{
                    .drain = drainImpl,
                    .flush = flushImpl,
                },
            },
        };
    }

    pub fn deinit(self: *Writer) void {
        self.acc.deinit(self.allocator);
    }

    // ── Io.Writer vtable ──────────────────────────────────────────────────────

    fn drainImpl(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        var total: usize = 0;
        for (data, 0..) |buf, i| {
            // The last buffer is repeated `splat` times; all others appear once.
            const reps: usize = if (i == data.len - 1 and splat > 1) splat else 1;
            for (0..reps) |_| {
                w.acc.appendSliceAssumeCapacity(buf);
                total += buf.len;
            }
        }
        return total;
    }

    fn flushImpl(io_w: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const payload = w.acc.items;
        if (payload.len == 0 and w.ctrl_len == 0) return;

        const iov = [1]posix.iovec_const{
            .{ .base = payload.ptr, .len = payload.len },
        };
        const msghdr = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = if (w.ctrl_len > 0) @ptrCast(&w.ctrl_buf) else null,
            .controllen = w.ctrl_len,
            .flags = 0,
        };

        if (std.os.linux.sendmsg(w.fd, &msghdr, 0) != 0) return error.WriteFailed;

        w.ctrl_len = 0;
        w.acc.clearRetainingCapacity();
    }

    /// Attach fds to the next flush as SCM_RIGHTS ancillary data.
    pub fn attachFds(self: *Writer, fds: []const i32) !void {
        var fba = std.heap.FixedBufferAllocator.init(&self.ctrl_buf);
        _ = try cmsg.initRights(fba.allocator(), fds);
        self.ctrl_len = fba.end_index;
    }
};
