//! RMT (remote control transceiver): generates pulse trains with tick-accurate timing.
//!
//! Only the two TX channels are implemented for now (no RX, no carrier, no loop mode).
//!
//! Each channel owns one block of 48 pulse codes in the RMT RAM. Transmissions that don't fit are
//! streamed in wrap mode: the hardware reads the memory as a ring and raises a threshold event
//! every half ring, and `transmit_blocking` refills the half that was just sent. The refill is
//! polled, so anything that keeps the CPU away for more than half a ring (an interrupt, a task
//! switch) is reported as `error.Underrun`. A channel can borrow the blocks of the channels after
//! it (`Tx.Config.memory_blocks`) to get a longer ring.
//!
//! helpful links:
//! - https://github.com/esp-rs/esp-hal/blob/main/esp-hal/src/rmt.rs
//! - https://github.com/espressif/esp-idf/blob/master/components/hal/esp32c6/include/hal/rmt_ll.h
const std = @import("std");
const microzig = @import("microzig");
const Mmio = microzig.mmio.Mmio;

const clocks = @import("clocks.zig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");
const rmt = @This();

/// Number of pulse codes in one RAM block.
pub const block_len = 48;
/// Number of RAM blocks (one per channel: TX0, TX1, RX2, RX3).
pub const block_count = 4;

/// One RMT RAM entry: two (level, duration) phases. Durations are in channel ticks. A zero duration
/// ends the transmission.
pub const Pulse = packed struct(u32) {
    duration0: u15,
    level0: u1,
    duration1: u15,
    level1: u1,

    pub const end_marker: Pulse = .{ .duration0 = 0, .level0 = 0, .duration1 = 0, .level1 = 0 };

    pub fn is_end_marker(pulse: Pulse) bool {
        return pulse.duration0 == 0 or pulse.duration1 == 0;
    }
};

pub const ClockSource = enum {
    /// 40 MHz crystal. Doesn't depend on the CPU clock config.
    xtal,
    /// ESP32-C3 only: APB clock (80 MHz when the CPU runs from the PLL).
    apb,
    /// ESP32-C6 only: 80 MHz PLL tap. Needs the PLL to be running.
    pll_f80m,
};

pub const Config = struct {
    clock_config: clocks.Config,
    clock_source: ClockSource = .xtal,
    /// Divides the source clock for all channels (1-256).
    clock_divider: u9 = 1,

    /// Frequency of the clock that feeds the channel dividers.
    pub fn sclk_freq(comptime config: Config) u32 {
        const source_freq: u32 = switch (config.clock_source) {
            .xtal => clocks.xtal_clk_freq,
            .apb => switch (compatibility.chip) {
                .esp32_c3 => config.clock_config.apb_clk_freq,
                .esp32_c6 => @compileError("the ESP32-C6 RMT has no APB clock source, use .pll_f80m"),
            },
            .pll_f80m => switch (compatibility.chip) {
                .esp32_c3 => @compileError("the ESP32-C3 RMT has no PLL_F80M clock source, use .apb"),
                .esp32_c6 => 80_000_000,
            },
        };
        if (config.clock_divider == 0 or config.clock_divider > 256)
            @compileError("the RMT clock divider must be between 1 and 256");
        return source_freq / config.clock_divider;
    }
};

/// Enables the peripheral and selects its clock. Call once, before configuring channels.
pub fn apply(comptime config: Config) void {
    _ = comptime config.sclk_freq(); // validates the config

    system.enable_clocks_and_release_reset(.{ .rmt = true });

    // Same encoding on both chips: 1 = APB / PLL_F80M, 2 = RC_FAST, 3 = XTAL.
    const sclk_sel = switch (config.clock_source) {
        .apb, .pll_f80m => 1,
        .xtal => 3,
    };
    const div_num: u8 = @intCast(config.clock_divider - 1);

    switch (compatibility.chip) {
        .esp32_c3 => regs().SYS_CONF.modify(.{
            .C3_SCLK_DIV_NUM = div_num,
            .C3_SCLK_DIV_A = 0,
            .C3_SCLK_DIV_B = 0,
            .C3_SCLK_SEL = sclk_sel,
            .C3_SCLK_ACTIVE = 1,
        }),
        // The C6 moved the function clock setup to PCR.
        .esp32_c6 => microzig.chip.peripherals.PCR.RMT_SCLK_CONF.modify(.{
            .SCLK_DIV_NUM = div_num,
            .SCLK_DIV_A = 0,
            .SCLK_DIV_B = 0,
            .SCLK_SEL = sclk_sel,
            .SCLK_EN = 1,
        }),
    }

    regs().SYS_CONF.modify(.{
        // Access the RAM directly (at `ram()`) instead of through the CHnDATA FIFO registers.
        .APB_FIFO_MASK = 1,
        .MEM_CLK_FORCE_ON = 1,
        .MEM_FORCE_PD = 0,
        .MEM_FORCE_PU = 0,
        .CLK_EN = 1,
    });
}

pub const instance = struct {
    pub const TX0 = tx(0);
    pub const TX1 = tx(1);

    pub fn tx(n: u1) Tx {
        return @fromBackingInt(@intCast(n));
    }
};

pub const Level = enum(u1) { low = 0, high = 1 };

/// A transmit channel.
pub const Tx = enum(u1) {
    _,

    pub const Config = struct {
        /// Divides the RMT clock (`rmt.Config.sclk_freq`) down to the channel tick (1-256).
        clock_divider: u9 = 1,
        /// Level of the pin while nothing is being transmitted.
        idle_level: Level = .low,
        /// Number of RAM blocks used by this channel. More than one takes the blocks of the
        /// following channels, which then can't be used.
        memory_blocks: u3 = 1,

        /// Frequency of the channel tick, the unit of `Pulse` durations.
        pub fn tick_freq(comptime config: Tx.Config, comptime rmt_config: rmt.Config) u32 {
            return rmt_config.sclk_freq() / config.clock_divider;
        }
    };

    pub const Error = error{
        /// The RAM wasn't refilled in time, the pulse train sent is wrong.
        Underrun,
        /// The peripheral reported a transmit error.
        TransmitFailed,
    };

    pub fn apply(self: Tx, comptime config: Tx.Config) void {
        const n = @backingInt(self);

        comptime {
            if (config.clock_divider == 0 or config.clock_divider > 256)
                @compileError("the RMT channel clock divider must be between 1 and 256");
            if (config.memory_blocks == 0)
                @compileError("an RMT channel needs at least one memory block");
        }
        std.debug.assert(@as(usize, n) + config.memory_blocks <= block_count);

        regs().CH_TX_CONF0[n].modify(.{
            // 0 selects a division by 256.
            .DIV_CNT = @as(u8, @truncate(config.clock_divider)),
            .MEM_SIZE = config.memory_blocks,
            .IDLE_OUT_LV = @backingInt(config.idle_level),
            .IDLE_OUT_EN = 1,
            .TX_CONTI_MODE = 0,
            .MEM_TX_WRAP_EN = 0,
            .CARRIER_EN = 0,
            .TX_STOP = 0,
        });
        self.update();
    }

    /// Routes the channel output to a pin through the GPIO matrix.
    pub fn connect_pin(self: Tx, pin: gpio.Pin) void {
        const signal: gpio.OutputSignal = switch (compatibility.chip) {
            .esp32_c3 => switch (@backingInt(self)) {
                0 => .rmt_sig0,
                1 => .rmt_sig1,
            },
            .esp32_c6 => switch (@backingInt(self)) {
                0 => .rmt_sig_0,
                1 => .rmt_sig_1,
            },
        };
        pin.apply(.{ .output_enable = true });
        // The channel drives the output enable itself, as in ESP-IDF and esp-hal. Forcing it
        // from the GPIO enable register instead makes Wokwi output the signal inverted.
        pin.connect_peripheral_to_output(.{
            .signal = signal,
            .output_enable_signal_controlled_by_peripheral = true,
        });
    }

    /// Transmits the pulses and waits for the end of the transmission. An end marker in `pulses`
    /// stops the transmission early.
    pub fn write_blocking(self: Tx, pulses: []const Pulse) Error!void {
        var source: SliceSource = .{ .pulses = pulses };
        return self.transmit_blocking(&source);
    }

    /// Transmits the pulses returned by `source.next()` (a `?Pulse`) until it returns null, and
    /// waits for the end of the transmission. Lets a driver encode its data on the fly instead of
    /// buffering one pulse code per bit.
    pub fn transmit_blocking(self: Tx, source: anytype) Error!void {
        const n = @backingInt(self);
        const conf0 = &regs().CH_TX_CONF0[n];
        const len = @as(usize, conf0.read().MEM_SIZE) * block_len;
        const half = len / 2;

        // Fill the whole ring. If the end marker fits, the hardware never wraps.
        var done = self.fill(source, 0, len);

        regs().CH_TX_LIM[n].modify(.{ .TX_LIM = @as(u9, @intCast(half)) });
        conf0.modify(.{ .MEM_TX_WRAP_EN = @intFromBool(!done) });
        self.update();

        // Restart the channel tick divider so that the first pulse has its full length.
        regs().REF_CNT_RST.write_raw(self.mask(1));
        regs().REF_CNT_RST.write_raw(0);

        regs().INT_CLR.write_raw(self.mask(int_all));
        conf0.modify(.{ .MEM_RD_RST = 1, .APB_MEM_RST = 1, .TX_START = 1 });

        var next_half: usize = 0;
        while (true) {
            const status = regs().INT_RAW.raw;

            if (status & self.mask(int_tx_err) != 0) return error.TransmitFailed;
            if (status & self.mask(int_tx_end) != 0) return;
            if (status & self.mask(int_tx_thr) == 0) continue;

            regs().INT_CLR.write_raw(self.mask(int_tx_thr));
            if (done) continue;

            // The hardware just left `next_half` and reads the other one.
            done = self.fill(source, next_half * half, half);
            next_half ^= 1;

            // A second threshold event means that the hardware came back into the half that was
            // being written: part of what it sent was stale.
            if (!done and regs().INT_RAW.raw & self.mask(int_tx_thr) != 0) {
                self.stop();
                return error.Underrun;
            }
        }
    }

    /// Writes up to `count` pulses at `offset`. Returns true once the end marker is written.
    fn fill(self: Tx, source: anytype, offset: usize, count: usize) bool {
        const mem = ram()[@as(usize, @backingInt(self)) * block_len + offset ..][0..count];
        for (mem) |*word| {
            const pulse: Pulse = source.next() orelse .end_marker;
            word.* = @bitCast(pulse);
            if (pulse.is_end_marker()) return true;
        }
        return false;
    }

    /// Aborts the transmission. The stop is immediate on the C3 and C6 and doesn't raise an end
    /// event, so there is nothing to wait for.
    fn stop(self: Tx) void {
        const n = @backingInt(self);
        regs().CH_TX_CONF0[n].modify(.{ .TX_STOP = 1 });
        self.update();
        regs().CH_TX_CONF0[n].modify(.{ .TX_STOP = 0, .MEM_TX_WRAP_EN = 0 });
        self.update();
    }

    /// Syncs the channel config into the RMT clock domain.
    fn update(self: Tx) void {
        regs().CH_TX_CONF0[@backingInt(self)].modify(.{ .CONF_UPDATE = 1 });
    }

    /// Shifts a channel 0 bit mask to this channel.
    fn mask(self: Tx, ch0_mask: u32) u32 {
        return ch0_mask << @backingInt(self);
    }
};

const SliceSource = struct {
    pulses: []const Pulse,

    fn next(source: *SliceSource) ?Pulse {
        if (source.pulses.len == 0) return null;
        defer source.pulses = source.pulses[1..];
        return source.pulses[0];
    }
};

// Interrupt bits of channel 0 in INT_RAW / INT_ST / INT_ENA / INT_CLR. Channel 1 is one bit up.
const int_tx_end: u32 = 1 << 0;
const int_tx_err: u32 = 1 << 4;
const int_tx_thr: u32 = 1 << 8;
const int_tx_loop: u32 = 1 << 12;
const int_all: u32 = int_tx_end | int_tx_err | int_tx_thr | int_tx_loop;

/// The SVDs name the same registers differently on each chip (`CH0STATUS` on the C3,
/// `CH0_TX_STATUS` on the C6) and regz drops the `CH%s_*` interrupt fields, so the layout is
/// declared here. It is the same on both chips, except for the clock fields of SYS_CONF.
const Regs = extern struct {
    CH_DATA: [4]u32,
    CH_TX_CONF0: [2]Mmio(packed struct(u32) {
        TX_START: u1,
        MEM_RD_RST: u1,
        APB_MEM_RST: u1,
        TX_CONTI_MODE: u1,
        MEM_TX_WRAP_EN: u1,
        IDLE_OUT_LV: u1,
        IDLE_OUT_EN: u1,
        TX_STOP: u1,
        DIV_CNT: u8,
        MEM_SIZE: u3,
        reserved20: u1,
        CARRIER_EFF_EN: u1,
        CARRIER_EN: u1,
        CARRIER_OUT_LV: u1,
        AFIFO_RST: u1,
        CONF_UPDATE: u1,
        padding: u7,
    }),
    CH_RX_CONF: [2]extern struct { CONF0: u32, CONF1: u32 },
    CH_TX_STATUS: [2]u32,
    CH_RX_STATUS: [2]u32,
    INT_RAW: Mmio(u32),
    INT_ST: Mmio(u32),
    INT_ENA: Mmio(u32),
    INT_CLR: Mmio(u32),
    CH_CARRIER_DUTY: [2]u32,
    CH_RX_CARRIER_RM: [2]u32,
    CH_TX_LIM: [2]Mmio(packed struct(u32) {
        TX_LIM: u9,
        TX_LOOP_NUM: u10,
        TX_LOOP_CNT_EN: u1,
        LOOP_COUNT_RESET: u1,
        /// ESP32-C6 only.
        LOOP_STOP_EN: u1,
        padding: u10,
    }),
    CH_RX_LIM: [2]u32,
    SYS_CONF: Mmio(packed struct(u32) {
        APB_FIFO_MASK: u1,
        MEM_CLK_FORCE_ON: u1,
        MEM_FORCE_PD: u1,
        MEM_FORCE_PU: u1,
        // ESP32-C3 only, reserved on the C6 (see PCR.RMT_SCLK_CONF).
        C3_SCLK_DIV_NUM: u8,
        C3_SCLK_DIV_A: u6,
        C3_SCLK_DIV_B: u6,
        C3_SCLK_SEL: u2,
        C3_SCLK_ACTIVE: u1,
        reserved27: u4,
        CLK_EN: u1,
    }),
    TX_SIM: u32,
    REF_CNT_RST: Mmio(u32),
};

comptime {
    std.debug.assert(@offsetOf(Regs, "CH_TX_CONF0") == 0x10);
    std.debug.assert(@offsetOf(Regs, "INT_RAW") == 0x38);
    std.debug.assert(@offsetOf(Regs, "CH_TX_LIM") == 0x58);
    std.debug.assert(@offsetOf(Regs, "SYS_CONF") == 0x68);
    std.debug.assert(@offsetOf(Regs, "REF_CNT_RST") == 0x70);
}

inline fn regs() *volatile Regs {
    return @ptrCast(microzig.chip.peripherals.RMT);
}

/// The pulse code RAM of all channels, `block_len` words per channel.
inline fn ram() *volatile [block_count * block_len]u32 {
    return @ptrFromInt(@intFromPtr(microzig.chip.peripherals.RMT) + 0x400);
}
