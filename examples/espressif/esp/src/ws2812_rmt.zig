//! Cycles a WS2812 LED through red, green and blue, using the RMT peripheral for the timing.
//! Compared to `ws2812_blinky.zig`, the SPI bus stays free.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const rmt = hal.rmt;
const WS2812 = hal.drivers.WS2812_RMT;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = hal.usb_serial_jtag.logger.log,
});

comptime {
    _ = microzig.export_startup();
}

const led_pin = gpio.num(8);
const channel = rmt.instance.TX0;

// 40 MHz crystal, undivided: 25 ns ticks.
const rmt_config: rmt.Config = .{ .clock_config = hal.clock_config };
const channel_config: rmt.Tx.Config = .{};

pub fn main() !void {
    rmt.apply(rmt_config);
    channel.apply(channel_config);
    channel.connect_pin(led_pin);

    var ws2812: WS2812 = .init(channel, comptime channel_config.tick_freq(rmt_config), .{});

    const colors: [3]WS2812.Color = .{
        .{ .r = 10, .g = 0, .b = 0 },
        .{ .r = 0, .g = 10, .b = 0 },
        .{ .r = 0, .g = 0, .b = 10 },
    };

    while (true) {
        for (colors) |color| {
            try ws2812.write(&.{color});
            std.log.info("r={} g={} b={}", .{ color.r, color.g, color.b });
            hal.time.sleep_ms(1_000);
        }
    }
}
