//! SASL EXTERNAL authentication.
//! Operates directly over std.Io.Reader / std.Io.Writer.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Io = std.Io;

const logger = std.log.scoped(.zbus_sasl);

pub const Error = error{
    MechanismRejected,
    UnexpectedResponse,
    UnixFdNegotiationFailed,
} || Io.Reader.Error || Io.Writer.Error;

/// Performs SASL EXTERNAL + NEGOTIATE_UNIX_FD over `r` / `w`.
///
/// Sends:
///   \0AUTH EXTERNAL <hex-uid>\r\n
///   DATA\r\n
///   NEGOTIATE_UNIX_FD\r\n
///
/// Then reads lines until it gets AGREE_UNIX_FD (or ERROR) and sends BEGIN.
pub fn authenticate(r: *Io.Reader, w: *Io.Writer) !void {
    var uid_hex_buf: [32]u8 = undefined;
    const uid_hex = std.fmt.bufPrint(
        &uid_hex_buf,
        "{x}",
        .{std.os.linux.getuid()},
    ) catch unreachable;

    // All three lines in one logical write to avoid partial sends.
    try w.writeAll("\x00AUTH EXTERNAL ");
    try w.writeAll(uid_hex);
    try w.writeAll("\r\nDATA\r\nNEGOTIATE_UNIX_FD\r\n");
    try w.flush();

    logger.debug("sasl: sent AUTH EXTERNAL {s}", .{uid_hex});

    // State machine
    const State = enum { mech, data_ok, unix_fd };
    var state: State = .mech;

    while (true) {
        // takeDelimiterInclusive returns a slice from the reader's internal
        // buffer – no allocation needed.
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = mem.trimEnd(u8, line, "\r\n");
        logger.debug("sasl rx: '{s}'", .{trimmed});

        switch (state) {
            .mech => {
                if (mem.startsWith(u8, trimmed, "REJECTED"))
                    return error.MechanismRejected;
                if (mem.startsWith(u8, trimmed, "DATA")) {
                    state = .data_ok;
                } else if (mem.startsWith(u8, trimmed, "OK")) {
                    // Some daemons skip the DATA challenge and send OK directly.
                    state = .unix_fd;
                } else {
                    return error.UnexpectedResponse;
                }
            },
            .data_ok => {
                if (mem.startsWith(u8, trimmed, "OK")) {
                    state = .unix_fd;
                } else {
                    return error.UnexpectedResponse;
                }
            },
            .unix_fd => {
                if (mem.startsWith(u8, trimmed, "AGREE_UNIX_FD") or
                    mem.startsWith(u8, trimmed, "ERROR"))
                {
                    try w.writeAll("BEGIN\r\n");
                    try w.flush();
                    logger.debug("sasl: done ({s})", .{trimmed[0..@min(trimmed.len, 13)]});
                    return;
                }
                return error.UnixFdNegotiationFailed;
            },
        }
    }
}
