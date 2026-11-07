//! Bring-up smoke test, meant for the first run on an ESP32-C6 (real board or Wokwi).
//!
//! Logs over UART0 (TX = GPIO16 on the C6, already set up at 115200 baud by the bootloader),
//! so it doesn't depend on the USB-Serial-JTAG driver. Checks, in order:
//!   1. startup reaches main (watchdogs off, clocks applied)
//!   2. which CPU clock is actually in use, and a PLL cold start (power down + recalibrate)
//!   3. the systimer counts at the expected rate (compared to ROM delay)
//!   4. a systimer alarm interrupt is delivered through the interrupt matrix + CPU controller
//!   5. GPIO output toggles (LED on GPIO3)
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const systimer = hal.systimer;
const time = hal.time;

pub const panic = microzig.panic;

pub const std_options = microzig.std_options(.{
    .logFn = uart_log,
});

comptime {
    _ = microzig.export_startup();
}

pub const microzig_options: microzig.Options = .{
    .interrupts = .{
        .interrupt1 = .{ .c = timer_interrupt },
    },
};

const alarm = systimer.alarm(0);
var interrupt_count: u32 = 0;

fn timer_interrupt(_: *microzig.cpu.TrapFrame) linksection(".ram_text") callconv(.c) void {
    interrupt_count += 1;
    alarm.clear_interrupt();
}

var log_buf: [256]u8 = undefined;

fn uart_log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const line = std.fmt.bufPrint(&log_buf, "[" ++ level.asText() ++ "] " ++ format ++ "\r\n", args) catch return;
    hal.uart.write(0, line);
}

pub fn main() !void {
    std.log.info("ESP32-C6 smoke test: reached main", .{});

    // 2. clocks
    const cfg = hal.clock_config;
    std.log.info("clock config: cpu={} Hz apb={} Hz", .{ cfg.cpu_clk_freq, cfg.apb_clk_freq });

    // 2b. PLL cold start: the bootloader leaves the PLL running, so force the cold path by
    //     dropping to XTAL and powering the PLL down. No logging while it's off: UART0 may be
    //     clocked from a PLL tap.
    if (hal.compatibility.chip == .esp32_c6 and cfg.cpu_clk_source == .pll_clk) {
        hal.rom.delay_us(20_000); // let the UART TX FIFO drain
        (comptime hal.clocks.Config.init_comptime(40_000_000)).apply();
        hal.clocks.disable_pll();
        const p0 = systimer.unit(0).read();
        cfg.apply();
        const p1 = systimer.unit(0).read();
        std.log.info("PLL cold start: back on PLL in {} us", .{(p1 - p0) / systimer.ticks_per_us()});
    }

    // 3. systimer rate vs ROM delay (the ROM delay counts CPU cycles, so this also checks
    //    that the ROM was told the right CPU frequency).
    const t0 = systimer.unit(0).read();
    hal.rom.delay_us(100_000);
    const t1 = systimer.unit(0).read();
    const measured_us = (t1 - t0) / systimer.ticks_per_us();
    std.log.info("systimer: 100000 us ROM delay measured as {} us", .{measured_us});
    if (measured_us < 90_000 or measured_us > 110_000)
        std.log.err("systimer/ROM delay mismatch: clock config or systimer rate is wrong", .{});

    // 3b. Split the suspects without the ROM delay: what the ROM believes the CPU runs at,
    //     and how many CPU cycles (performance counter) elapse per systimer microsecond.
    std.log.info("ROM cpu ticks/us: {}", .{hal.rom.functions.ets_get_cpu_frequency()});
    {
        const csr = microzig.cpu.csr;
        csr.mpcer.write(.{ .cycle = 1 });
        csr.mpcmr.write(.{ .count_en = 1 });
        const window_us = 10_000;
        const s0 = systimer.unit(0).read();
        const c0 = csr.mpccr.read_raw();
        while ((systimer.unit(0).read() - s0) / systimer.ticks_per_us() < window_us) {}
        const c1 = csr.mpccr.read_raw();
        std.log.info("cpu cycles per systimer us: {} (expected {})", .{
            (c1 -% c0) / window_us,
            cfg.cpu_clk_freq / 1_000_000,
        });
    }

    // 4. alarm interrupt every 100 ms
    alarm.set_unit(.unit0);
    alarm.set_period(@intCast(100_000 * systimer.ticks_per_us()));
    alarm.set_mode(.target);
    alarm.set_mode(.period);
    alarm.set_interrupt_enabled(true);
    alarm.set_enabled(true);

    microzig.cpu.interrupt.set_priority_threshold(.zero);
    microzig.cpu.interrupt.set_type(.interrupt1, .level);
    microzig.cpu.interrupt.set_priority(.interrupt1, .highest);
    microzig.cpu.interrupt.map(.systimer_target0, .interrupt1);
    microzig.cpu.interrupt.enable(.interrupt1);
    microzig.cpu.interrupt.enable_interrupts();

    time.sleep_ms(1000);
    const count = @atomicLoad(u32, &interrupt_count, .monotonic);
    std.log.info("interrupts in 1 s: {} (expected ~10)", .{count});
    if (count == 0)
        std.log.err("no systimer interrupt delivered: check interrupt routing", .{});

    // 5. GPIO
    const led = gpio.num(3);
    led.apply(.{ .output_enable = true });

    std.log.info("smoke test done, blinking GPIO3", .{});

    var on: u1 = 0;
    while (true) {
        on ^= 1;
        led.put(on);
        std.log.info("led={} ticks={}", .{ on, @atomicLoad(u32, &interrupt_count, .monotonic) });
        time.sleep_ms(500);
    }
}
