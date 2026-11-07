const builtin = @import("builtin");
const std = @import("std");

pub const esp_image = @import("esp_image");
const microzig = @import("microzig");

pub const cache = @import("hal/cache.zig");
pub const clocks = @import("hal/clocks.zig");
pub const compatibility = @import("hal/compatibility.zig");
pub const drivers = @import("hal/drivers.zig");
pub const efuse = @import("hal/efuse.zig");
pub const gpio = @import("hal/gpio.zig");
pub const i2c = @import("hal/i2c.zig");
pub const ledc = @import("hal/ledc.zig");
pub const radio = @import("hal/radio.zig");
pub const rng = @import("hal/rng.zig");
pub const rom = @import("hal/rom.zig");
pub const rtos = @import("hal/rtos.zig");
pub const spi = @import("hal/spi.zig");
pub const system = @import("hal/system.zig");
pub const systimer = @import("hal/systimer.zig");
pub const time = @import("hal/time.zig");
pub const uart = @import("hal/uart.zig");
pub const usb_serial_jtag = @import("hal/usb_serial_jtag.zig");

comptime {
    if (!builtin.is_test) {
        // export atomic intrinsics
        _ = @import("hal/atomic.zig");

        @export(&app_desc, .{
            .name = "esp_app_desc",
            .section = ".app_desc",
        });
    }
}

pub const HAL_Options = struct {
    info: struct {
        project_name: []const u8 = "Untitled Project",
        secure_version: u32 = 0,
        version: []const u8 = "0.0.0",
    } = .{},
    rtos: rtos.Options = .{},
    radio: radio.Options = .{},
};

/// Clock config applied by the default `init()` function of the hal.
pub const clock_config: clocks.Config = .default;

pub fn init() void {
    init_sequence(clock_config);
}

/// Allows you to easily swap the clock config while using the recommended init sequence. To be used
/// with a custom `init()` function.
pub fn init_sequence(clock_cfg: clocks.Config) void {
    cache.init();

    // TODO: disable watchdogs in a more elegant way (with a hal).
    disable_watchdogs();

    if (compatibility.chip == .esp32_c6)
        disable_access_permission_filters_c6();

    rng.init();

    clock_cfg.apply();

    system.init();

    time.init();

    if (microzig.options.hal.rtos.enable)
        rtos.init();
}

// NOTE: temporary until timers hal.
fn disable_watchdogs() void {
    switch (compatibility.chip) {
        .esp32_c3 => disable_watchdogs_c3(),
        .esp32_c6 => disable_watchdogs_c6(),
    }
}

fn disable_watchdogs_c6() void {
    const peripherals = microzig.chip.peripherals;
    const TIMG0 = peripherals.TIMG0;
    const TIMG1 = peripherals.TIMG1;
    const LP_WDT = peripherals.LP_WDT;

    // On the C6 the same key unlocks the main, RTC and super watchdogs.
    const wkey = 0x50D83AA1;

    inline for (.{ TIMG0, TIMG1 }) |timg| {
        timg.WDTWPROTECT.raw = wkey;
        timg.WDTCONFIG0.raw = 0;
        timg.WDTWPROTECT.raw = 0;
    }

    LP_WDT.WDTWPROTECT.raw = wkey;
    LP_WDT.WDTCONFIG0.raw = 0;
    LP_WDT.WDTWPROTECT.raw = 0;

    // The super watchdog has no disable bit on the C6: enable auto-feed instead.
    LP_WDT.SWD_WPROTECT.raw = wkey;
    LP_WDT.SWD_CONF.modify(.{ .SWD_AUTO_FEED_EN = 1 });
    LP_WDT.SWD_WPROTECT.raw = 0;
}

/// All bus masters except the HP CPU boot in REE mode, and the default access path
/// filters only allow TEE masters. Open them, like ESP-IDF and esp-hal do at startup,
/// so DMA and the LP core can reach memory and peripherals.
fn disable_access_permission_filters_c6() void {
    const peripherals = microzig.chip.peripherals;
    peripherals.LP_APM.FUNC_CTRL.raw = 0;
    peripherals.LP_APM0.FUNC_CTRL.raw = 0;
    peripherals.HP_APM.FUNC_CTRL.raw = 0;
}

fn disable_watchdogs_c3() void {
    const peripherals = microzig.chip.peripherals;
    const TIMG0 = peripherals.TIMG0;
    const RTC_CNTL = peripherals.RTC_CNTL;

    const dogfood = 0x50D83AA1;
    const super_dogfood = 0x8F1D312A;

    // Feed and disable watchdog 0
    TIMG0.WDTWPROTECT.raw = dogfood;
    TIMG0.WDTCONFIG0.raw = 0;
    TIMG0.WDTWPROTECT.raw = 0;

    // Feed and disable rtc watchdog
    RTC_CNTL.WDTWPROTECT.raw = dogfood;
    RTC_CNTL.WDTCONFIG0.raw = 0;
    RTC_CNTL.WDTWPROTECT.raw = 0;

    // Feed and disable rtc super watchdog
    RTC_CNTL.SWD_WPROTECT.raw = super_dogfood;
    RTC_CNTL.SWD_CONF.modify(.{ .SWD_DISABLE = 1 });
    RTC_CNTL.SWD_WPROTECT.raw = 0;
}

// Don't change the name of this export, it is checked by espflash tool. Only
// these fields are populated here. The others will be set by elf2image.
const app_desc: esp_image.AppDesc = .{
    .secure_version = microzig.options.hal.info.secure_version,
    .version = str(32, microzig.options.hal.info.version),
    .project_name = str(32, microzig.options.hal.info.project_name),
};

fn str(comptime l: usize, comptime s: []const u8) [l]u8 {
    // l - 1 because we need to add a null byte at the end
    if (s.len > l - 1) {
        @compileError(std.fmt.comptimePrint("string `{s}` doesn't fit in buffer with len {d}", .{ s, l }));
    }

    var buf = std.mem.zeroes([l]u8);
    std.mem.copyForwards(u8, buf[0..s.len], s);
    return buf;
}

test {
    _ = rtos;
    _ = radio;
}
