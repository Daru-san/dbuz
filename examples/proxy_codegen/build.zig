//! examples/proxy_codegen/build.zig
//!
//! Demonstrates how a downstream project uses zbus.ProxyScanner to generate
//! typed proxies at build time from D-Bus introspection XML.
//!
//! This mirrors the pattern shown in the original request:
//!
//!   var scanner = ProxyScanner.create(b, zbus_dep);
//!   scanner.addProxy(.{ .interface_name = "org.bluez.Adapter1", ... });
//!   const proxies_mod = scanner.generate();

const std = @import("std");
const Build = std.Build;
const zbus = @import("zbus").ProxyScanner; // re-exported from zbus build.zig

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbus_dep = b.dependency("zbus", .{
        .target = target,
        .optimize = optimize,
    });

    var scanner = zbus.create(b, zbus_dep);

    // ── Proxy declarations ────────────────────────────────────────────────────
    //
    // Each call to addProxy generates one .zig file from the XML.
    // The `interface_name` must match exactly what is in the XML.
    // The `output_name` becomes the Zig struct name (and the import key
    // returned by scanner.generate()).
    //
    // Multiple interfaces from the *same* XML file are fine — the scanner
    // will parse the file once and extract only the requested interface.

    const xml_dir = b.path("xml");

    const ProxyDecl = struct {
        interface_name: []const u8,
        output_name: ?[]const u8 = null,
        xml_file: []const u8,
    };

    const proxy_decls: []const ProxyDecl = &.{
        .{ .interface_name = "org.bluez.Adapter1", .xml_file = "org.bluez.adapter1.xml" },
        .{ .interface_name = "org.bluez.Device1", .xml_file = "org.bluez.device1.xml" },
        .{
            .interface_name = "org.freedesktop.login1.Session",
            .output_name = "Login1Session",
            .xml_file = "org.freedesktop.login1.session.xml",
        },
        .{
            .interface_name = "org.freedesktop.login1.Manager",
            .output_name = "Login1Manager",
            .xml_file = "org.freedesktop.login1.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager",
            .output_name = "NetworkManager",
            .xml_file = "org.freedesktop.networkmanager.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Connection.Active",
            .output_name = "NMConnectionActive",
            .xml_file = "org.freedesktop.networkmanager.connection.active.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.AccessPoint",
            .output_name = "NMAccessPoint",
            .xml_file = "org.freedesktop.networkmanager.accesspoint.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Device",
            .output_name = "NMDevice",
            .xml_file = "org.freedesktop.networkmanager.device.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Device.Wireless",
            .output_name = "NMDeviceWireless",
            .xml_file = "org.freedesktop.networkmanager.device.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Device.Statistics",
            .output_name = "NMDeviceStatistics",
            .xml_file = "org.freedesktop.networkmanager.device.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Settings",
            .output_name = "NMSettings",
            .xml_file = "org.freedesktop.networkmanager.settings.xml",
        },
        .{
            .interface_name = "org.freedesktop.NetworkManager.Settings.Connection",
            .output_name = "NMSettingsConnection",
            .xml_file = "org.freedesktop.networkmanager.settings.connection.xml",
        },
        .{ .interface_name = "org.freedesktop.Notifications", .xml_file = "org.freedesktop.notifications.xml" },
        .{ .interface_name = "org.freedesktop.UPower", .xml_file = "org.freedesktop.upower.xml" },
        .{
            .interface_name = "org.freedesktop.UPower.Device",
            .output_name = "UPowerDevice",
            .xml_file = "org.freedesktop.upower.device.xml",
        },
        .{ .interface_name = "org.kde.kdeconnect.daemon", .xml_file = "org.kde.kdeconnect.daemon.xml" },
        .{ .interface_name = "org.kde.StatusNotifierItem", .xml_file = "org.kde.statusnotifieritem.xml" },
        .{ .interface_name = "org.kde.StatusNotifierWatcher", .xml_file = "org.kde.statusnotifierwatcher.xml" },
        .{ .interface_name = "org.mpris.MediaPlayer2", .xml_file = "org.mpris.mediaplayer2.xml" },
        .{
            .interface_name = "org.mpris.MediaPlayer2.Player",
            .output_name = "MprisPlayer",
            // Multiple interfaces in the same file; the scanner selects the right one.
            .xml_file = "org.mpris.mediaplayer2.xml",
        },
    };

    for (proxy_decls) |decl| {
        scanner.addProxy(.{
            .interface_name = decl.interface_name,
            .output_name = decl.output_name,
            .xml_path = xml_dir.path(b, decl.xml_file),
        });
    }

    const proxies_mod = scanner.generate();

    // ── Example binary that uses the generated proxies ────────────────────────

    const exe = b.addExecutable(.{
        .name = "proxy_codegen_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zbus", .module = zbus_dep.module("zbus") },
                .{ .name = "zbus_proxies", .module = proxies_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run example").dependOn(&run.step);
}
