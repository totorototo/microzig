const std = @import("std");
const microzig = @import("microzig");
const LEDC = microzig.chip.peripherals.LEDC;

const clocks = @import("clocks.zig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");
const system = @import("system.zig");

pub const ClockSource = enum(u2) {
    /// Fast clock source. ESP32-C3: APB clock. ESP32-C6: PLL_F80M (80 MHz), selected in PCR.
    apb_clk = 1,
    xtal_clk = 3,

    fn frequency(source: ClockSource, clock_config: clocks.Config) u32 {
        return switch (source) {
            .apb_clk => switch (compatibility.chip) {
                .esp32_c3 => clock_config.apb_clk_freq,
                .esp32_c6 => 80_000_000,
            },
            .xtal_clk => clocks.xtal_clk_freq,
        };
    }
};

/// Enables the LEDC peripheral and sets the clock source.
pub fn apply(clock_source: ClockSource) void {
    system.enable_clocks_and_release_reset(.{ .ledc = true });

    set_clock_source(clock_source);
}

/// Timers configuration is specific to a clock source. If changed, all active
/// timers must be reconfigured.
pub fn set_clock_source(clock_source: ClockSource) void {
    switch (compatibility.chip) {
        .esp32_c3 => LEDC.CONF.modify(.{
            .APB_CLK_SEL = @backingInt(clock_source),
        }),
        .esp32_c6 => microzig.chip.peripherals.PCR.LEDC_SCLK_CONF.modify(.{
            .LEDC_SCLK_SEL = @backingInt(clock_source),
            .LEDC_SCLK_EN = 1,
        }),
    }
}

pub fn get_clock_source() ClockSource {
    return switch (compatibility.chip) {
        .esp32_c3 => @fromBackingInt(LEDC.CONF.read().APB_CLK_SEL),
        .esp32_c6 => @fromBackingInt(microzig.chip.peripherals.PCR.LEDC_SCLK_CONF.read().LEDC_SCLK_SEL),
    };
}

pub fn timer(num: u4) Timer {
    return @fromBackingInt(num);
}

pub fn channel(num: u4) Channel {
    return @fromBackingInt(num);
}

inline fn comptime_fail_or_error(msg: []const u8, fmt_args: anytype, err: anytype) !void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(msg, fmt_args));
    } else {
        return err;
    }
}

pub const Timer = enum(u2) {
    timer0 = 0,
    timer1 = 1,
    timer2 = 2,
    timer3 = 3,

    pub const Config = struct {
        clock_config: clocks.Config,
        /// The frequency of the timer in Hz.
        frequency: u32,
        /// The number of precision bits for the timer. Takes values from 1 to 14.
        precision: u4,

        pub const Error = error{
            InvalidFrequency,
            InvalidPrecision,
        };

        fn resolve(config: Config, clock_source: ClockSource) Error!u18 {
            const src_freq = clock_source.frequency(config.clock_config);

            if (config.frequency == 0) try comptime_fail_or_error("frequency must be greater than 0", .{}, error.InvalidFrequency);

            if (config.precision <= 0 or config.precision > 14) try comptime_fail_or_error(
                "invalid precision: {} (must be greater than 0 and less than or equal to 14)",
                .{config.precision},
                error.InvalidPrecision,
            );

            const divider = (@as(u64, src_freq) << 8) / config.frequency / (@as(u64, 1) << config.precision);
            if (divider < 256) try comptime_fail_or_error("frequency too high: {}", .{config.frequency}, error.InvalidFrequency);
            if (divider > std.math.maxInt(u18)) try comptime_fail_or_error("frequency too low: {}", .{config.frequency}, error.InvalidFrequency);

            return @truncate(divider);
        }
    };

    /// Applies the configuration to the timer and validates it at comptime.
    /// Requires the clock source to be provided.
    pub fn apply(tim: Timer, comptime config: Config, comptime clock_source: ClockSource) void {
        const resolved_config = comptime config.resolve(clock_source) catch unreachable;
        apply_internal(tim, config, resolved_config);
    }

    /// Applies the configuration to the timer and returns an error if invalid.
    /// Doesn't require the clock source to be provided as it is fetched at
    /// runtime.
    pub fn apply_runtime(tim: Timer, config: Config) Config.Error!void {
        const clock_source = get_clock_source();
        const resolved_config = try config.resolve(clock_source);
        apply_internal(tim, config, resolved_config);
    }

    fn apply_internal(tim: Timer, config: Config, divider: u18) void {
        switch (compatibility.chip) {
            .esp32_c3 => {
                const regs = tim.get_regs();

                regs.conf.modify(.{
                    .LSTIMER0_DUTY_RES = config.precision,
                    .CLK_DIV_LSTIMER0 = divider,
                    .LSTIMER0_PAUSE = 0,
                    .LSTIMER0_RST = 0,
                    .TICK_SEL_LSTIMER0 = 0,
                });

                regs.conf.modify(.{
                    .LSTIMER0_PARA_UP = 1,
                });
            },
            .esp32_c6 => {
                const regs: @TypeOf(&LEDC.TIMER0) = switch (tim) {
                    .timer0 => &LEDC.TIMER0,
                    .timer1 => @ptrCast(&LEDC.TIMER1),
                    .timer2 => @ptrCast(&LEDC.TIMER2),
                    .timer3 => @ptrCast(&LEDC.TIMER3),
                };

                regs.CONF.modify(.{
                    .DUTY_RES = config.precision,
                    .CLK_DIV = divider,
                    .PAUSE = 0,
                    .RST = 0,
                    .TICK_SEL = 0,
                });

                regs.CONF.modify(.{ .PARA_UP = 1 });
            },
        }
    }

    inline fn get_regs(tim: Timer) *volatile extern struct {
        conf: @TypeOf(LEDC.LSTIMER0_CONF),
        value: @TypeOf(LEDC.LSTIMER0_VALUE),
    } {
        return switch (tim) {
            .timer0 => @ptrCast(@alignCast(&LEDC.LSTIMER0_CONF)),
            .timer1 => @ptrCast(@alignCast(&LEDC.LSTIMER1_CONF)),
            .timer2 => @ptrCast(@alignCast(&LEDC.LSTIMER2_CONF)),
            .timer3 => @ptrCast(@alignCast(&LEDC.LSTIMER3_CONF)),
        };
    }
};

pub const Channel = enum(u2) {
    channel0 = 0,
    channel1 = 1,
    channel2 = 2,
    channel3 = 3,

    pub const Config = struct {
        timer: Timer,
        initial_duty: u15 = 0,
    };

    /// Applies the configuration to the channel.
    pub fn apply(chan: Channel, config: Config) void {
        switch (compatibility.chip) {
            .esp32_c3 => {
                const regs = chan.get_regs();

                regs.hpoint.write(.{ .HPOINT_LSCH0 = 0 });
                regs.conf0.modify(.{
                    .TIMER_SEL_LSCH0 = @backingInt(config.timer),
                    .SIG_OUT_EN_LSCH0 = 1,
                });
            },
            .esp32_c6 => {
                const regs = chan.get_regs_c6();

                regs.HPOINT.write(.{ .HPOINT = 0 });
                regs.CONF0.modify(.{
                    .TIMER_SEL = @backingInt(config.timer),
                    .SIG_OUT_EN = 1,
                });
            },
        }

        // also calls update()
        chan.set_duty(config.initial_duty);
    }

    /// Connects the channel to the provided pin.
    pub fn connect_pin(chan: Channel, pin: gpio.Pin) void {
        pin.connect_peripheral_to_output(.{
            .signal = switch (chan) {
                .channel0 => .ledc_ls_sig0,
                .channel1 => .ledc_ls_sig1,
                .channel2 => .ledc_ls_sig2,
                .channel3 => .ledc_ls_sig3,
            },
        });
    }

    /// Sets a constant duty cycle.
    pub fn set_duty(chan: Channel, duty: u15) void {
        switch (compatibility.chip) {
            .esp32_c3 => {
                const regs = chan.get_regs();

                regs.duty.write(.{ .DUTY_LSCH0 = @as(u19, duty) << 4 });

                regs.conf1.write(.{
                    .DUTY_START_LSCH0 = 1,
                    .DUTY_INC_LSCH0 = 1,
                    .DUTY_NUM_LSCH0 = 1,
                    .DUTY_CYCLE_LSCH0 = 1,
                    .DUTY_SCALE_LSCH0 = 0,
                });
            },
            // Same as ESP-IDF: a constant duty is a one-entry "fade" with zero scale.
            .esp32_c6 => chan.start_c6(duty, .{ .increment = 0, .cycle = 1, .duration = 1 }),
        }

        chan.update();
    }

    /// ESP32-C6: duty fades are programmed through the channel's gamma RAM. We use a single entry.
    fn start_c6(chan: Channel, duty: u15, options: DutyFadeOptions) void {
        const regs = chan.get_regs_c6();
        const i = @backingInt(chan);
        const stride = @intFromPtr(&LEDC.CH1_GAMMA_WR) - @intFromPtr(&LEDC.CH0_GAMMA_WR);
        const gamma_wr: @TypeOf(&LEDC.CH0_GAMMA_WR) = @ptrFromInt(@intFromPtr(&LEDC.CH0_GAMMA_WR) + stride * i);
        const gamma_wr_addr: @TypeOf(&LEDC.CH0_GAMMA_WR_ADDR) = @ptrFromInt(@intFromPtr(&LEDC.CH0_GAMMA_WR_ADDR) + stride * i);
        const gamma_conf_stride = @intFromPtr(&LEDC.CH1_GAMMA_CONF) - @intFromPtr(&LEDC.CH0_GAMMA_CONF);
        const gamma_conf: @TypeOf(&LEDC.CH0_GAMMA_CONF) = @ptrFromInt(@intFromPtr(&LEDC.CH0_GAMMA_CONF) + gamma_conf_stride * i);

        // GAMMA_RAM_CLK_EN_CH0..5 are consecutive bits starting at CH0.
        const clk_en_ch0 = @bitOffsetOf(@TypeOf(LEDC.CONF.read()), "GAMMA_RAM_CLK_EN_CH0");
        LEDC.CONF.raw |= @as(u32, 1) << @intCast(clk_en_ch0 + @as(u32, i));

        regs.DUTY.write(.{ .DUTY = @as(u25, duty) << 4 });

        gamma_wr.write(.{
            .CH_GAMMA_DUTY_INC = @intFromBool(options.increment >= 0),
            .CH_GAMMA_DUTY_CYCLE = options.cycle,
            .CH_GAMMA_SCALE = @truncate(@abs(options.increment)),
            .CH_GAMMA_DUTY_NUM = options.duration,
        });
        gamma_wr_addr.write(.{ .CH_GAMMA_WR_ADDR = 0 });
        gamma_conf.modify(.{ .CH_GAMMA_ENTRY_NUM = 1 });

        regs.CONF1.write(.{ .DUTY_START = 1 });
    }

    /// ESP32-C6: DUTY_CHNG_END_CHn is bit 4 + n (the generated field only names channel 0).
    fn duty_change_end_bit(chan: Channel) u32 {
        return @as(u32, 1) << (4 + @as(u5, @backingInt(chan)));
    }

    /// Starts a fade duty and waits for it to complete.
    pub fn fade_duty_blocking(chan: Channel, starting_duty: u15, options: DutyFadeOptions) void {
        start_duty_fade(chan, starting_duty, options);
        while (!is_duty_fade_done(chan)) {}
    }

    /// Starts a duty cycle fade.
    pub fn start_duty_fade(chan: Channel, starting_duty: u15, options: DutyFadeOptions) void {
        if (compatibility.chip == .esp32_c6) {
            LEDC.INT_CLR.raw = chan.duty_change_end_bit();
            chan.start_c6(starting_duty, options);
            chan.update();
            return;
        }

        const regs = chan.get_regs();

        regs.duty.write(.{ .DUTY_LSCH0 = @as(u19, starting_duty) << 4 });

        switch (chan) {
            .channel0 => LEDC.INT_CLR.modify(.{ .DUTY_CHNG_END_LSCH0_INT_CLR = 1 }),
            .channel1 => LEDC.INT_CLR.modify(.{ .DUTY_CHNG_END_LSCH1_INT_CLR = 1 }),
            .channel2 => LEDC.INT_CLR.modify(.{ .DUTY_CHNG_END_LSCH2_INT_CLR = 1 }),
            .channel3 => LEDC.INT_CLR.modify(.{ .DUTY_CHNG_END_LSCH3_INT_CLR = 1 }),
        }

        regs.conf1.write(.{
            .DUTY_START_LSCH0 = 1,
            .DUTY_INC_LSCH0 = @intFromBool(options.increment >= 0),
            .DUTY_NUM_LSCH0 = options.duration,
            .DUTY_CYCLE_LSCH0 = options.cycle,
            .DUTY_SCALE_LSCH0 = @truncate(@abs(options.increment)),
        });

        chan.update();
    }

    /// Returns true if the previous duty cycle fade is complete.
    pub fn is_duty_fade_done(chan: Channel) bool {
        return switch (compatibility.chip) {
            .esp32_c3 => switch (chan) {
                .channel0 => LEDC.INT_RAW.read().DUTY_CHNG_END_LSCH0_INT_RAW == 1,
                .channel1 => LEDC.INT_RAW.read().DUTY_CHNG_END_LSCH1_INT_RAW == 1,
                .channel2 => LEDC.INT_RAW.read().DUTY_CHNG_END_LSCH2_INT_RAW == 1,
                .channel3 => LEDC.INT_RAW.read().DUTY_CHNG_END_LSCH3_INT_RAW == 1,
            },
            .esp32_c6 => LEDC.INT_RAW.raw & chan.duty_change_end_bit() != 0,
        };
    }

    pub const DutyFadeOptions = struct {
        increment: i11,
        // Every `cycle` ticks the duty cycle is incremented by `increment`.
        cycle: u10,
        // The fade lasts for `duration` ticks.
        duration: u10,
    };

    fn update(chan: Channel) void {
        switch (compatibility.chip) {
            .esp32_c3 => chan.get_regs().conf0.modify(.{ .PARA_UP_LSCH0 = 1 }),
            .esp32_c6 => chan.get_regs_c6().CONF0.modify(.{ .PARA_UP = 1 }),
        }
    }

    fn get_regs_c6(chan: Channel) @TypeOf(&LEDC.CH0) {
        return switch (chan) {
            .channel0 => &LEDC.CH0,
            .channel1 => @ptrCast(&LEDC.CH1),
            .channel2 => @ptrCast(&LEDC.CH2),
            .channel3 => @ptrCast(&LEDC.CH3),
        };
    }

    inline fn get_regs(chan: Channel) *volatile extern struct {
        conf0: @TypeOf(LEDC.LSCH0_CONF0),
        hpoint: @TypeOf(LEDC.LSCH0_HPOINT),
        duty: @TypeOf(LEDC.LSCH0_DUTY),
        conf1: @TypeOf(LEDC.LSCH0_CONF1),
        duty_r: @TypeOf(LEDC.LSCH0_DUTY_R),
    } {
        return switch (chan) {
            .channel0 => @ptrCast(@alignCast(&LEDC.LSCH0_CONF0)),
            .channel1 => @ptrCast(@alignCast(&LEDC.LSCH1_CONF0)),
            .channel2 => @ptrCast(@alignCast(&LEDC.LSCH2_CONF0)),
            .channel3 => @ptrCast(@alignCast(&LEDC.LSCH3_CONF0)),
        };
    }
};
