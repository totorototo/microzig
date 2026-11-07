//! GPIO and pin configuration
//!
//! The GPIO matrix and IO mux allow input from any pin to be routed to any peripheral,
//! and any peripheral output to be routed to any pin.
//!
//! See the "IO MUX and GPIO Matrix" chapter of the Technical Reference Manual:
//! https://www.espressif.com/sites/default/files/documentation/esp32-c3_technical_reference_manual_en.pdf
//! https://www.espressif.com/sites/default/files/documentation/esp32-c6_technical_reference_manual_en.pdf
//!
const std = @import("std");
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const IO_MUX = peripherals.IO_MUX;
const GPIO = peripherals.GPIO;
const compatibility = @import("compatibility.zig");

/// Number of GPIO pins on this chip.
pub const pin_count = switch (compatibility.chip) {
    .esp32_c3 => 22,
    .esp32_c6 => 31,
};

/// Pins shared with the USB-Serial-JTAG peripheral (D-, D+).
const usb_pins: [2]u5 = switch (compatibility.chip) {
    .esp32_c3 => .{ 18, 19 },
    .esp32_c6 => .{ 12, 13 },
};

pub const DriveStrength = enum {
    @"5mA",
    @"10mA",
    @"20mA",
    @"40mA",

    /// Get the appropriate value of DriveStrength based on the pin number.
    /// See section 5.15.2 (IO MUX Registers) of the Technical Reference Manual
    fn to_value(strength: DriveStrength, pin: Pin) u2 {
        // The swapped encoding is an ESP32-C3 quirk; the C6 uses the plain encoding on every pin.
        if (compatibility.chip != .esp32_c3) return @backingInt(strength);

        return switch (@backingInt(pin)) {
            2, 3, 5, 18, 19 => switch (strength) {
                .@"5mA" => 0,
                .@"10mA" => 2,
                .@"20mA" => 1,
                .@"40mA" => 3,
            },
            else => switch (strength) {
                .@"5mA" => 0,
                .@"10mA" => 1,
                .@"20mA" => 2,
                .@"40mA" => 3,
            },
        };
    }
};

/// Alternative pin functions
pub const AlternateFunction = enum(u2) {
    function0 = 0,
    function1 = 1,
    function2 = 2,
    function3 = 3,
};

/// Interrupt events
pub const Event = enum(u3) {
    rising_edge = 1,
    falling_edge = 2,
    any_edge = 3,
    low_level = 4,
    high_level = 5,
};

const InputSignal_C3 = enum(u8) {
    spiq = 0,
    spid = 1,
    spihd = 2,
    spiwp = 3,

    u0rxd = 6,
    u0cts = 7,
    u0dsr = 8,
    u1rxd = 9,
    u1cts = 10,
    u1dsr = 11,

    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2si_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,

    gpio_bt_priority = 18,
    gpio_bt_active = 19,

    cpu_gpio0 = 28,
    cpu_gpio1 = 29,
    cpu_gpio2 = 30,
    cpu_gpio3 = 31,
    cpu_gpio4 = 32,
    cpu_gpio5 = 33,
    cpu_gpio6 = 34,
    cpu_gpio7 = 35,

    ext_adc_start = 45,

    rmt_sig0 = 51,
    rmt_sig1 = 52,

    i2cext0_scl = 53,
    i2cext0_sda = 54,

    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,

    twai_rx = 74,

    sig_in_func_97 = 97,
    sig_in_func_98 = 98,
    sig_in_func_99 = 99,
    sig_in_func_100 = 100,

    pub const always_low: InputSignal = .cpu_gpio3;
    pub const always_high: InputSignal = .cpu_gpio2;
};

const OutputSignal_C3 = enum(u8) {
    spiq = 0,
    spid = 1,
    spihd = 2,
    spiwp = 3,
    spiclk = 4,
    spics0 = 5,

    u0txd = 6,
    u0rts = 7,
    u0dtr = 8,
    u1txd = 9,
    u1rts = 10,
    u1dtr = 11,

    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2si_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,

    gpio_wlan_priority = 18,
    gpio_wlan_active = 19,

    cpu_gpio0 = 28,
    cpu_gpio1 = 29,
    cpu_gpio2 = 30,
    cpu_gpio3 = 31,
    cpu_gpio4 = 32,
    cpu_gpio5 = 33,
    cpu_gpio6 = 34,
    cpu_gpio7 = 35,

    usb_jtag_tck = 36,
    usb_jtag_tms = 37,
    usb_jtag_tdi = 38,
    usb_jtag_tdo = 39,

    ledc_ls_sig0 = 45,
    ledc_ls_sig1 = 46,
    ledc_ls_sig2 = 47,
    ledc_ls_sig3 = 48,
    ledc_ls_sig4 = 49,
    ledc_ls_sig5 = 50,

    rmt_sig0 = 51,
    rmt_sig1 = 52,

    i2cext0_scl = 53,
    i2cext0_sda = 54,

    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,
    fspics1 = 69,
    fspics2 = 70,
    fspics3 = 71,
    fspics4 = 72,
    fspics5 = 73,

    twai_tx = 74,
    twai_bus_off_on = 75,
    twai_clk = 76,

    ant_sel0 = 89,
    ant_sel1 = 90,
    ant_sel2 = 91,
    ant_sel3 = 92,
    ant_sel4 = 93,
    ant_sel5 = 94,
    ant_sel6 = 95,
    ant_sel7 = 96,

    sig_in_func_97 = 97,
    sig_in_func_98 = 98,
    sig_in_func_99 = 99,
    sig_in_func_100 = 100,

    clk_out1 = 123,
    clk_out2 = 124,
    clk_out3 = 125,

    spics1 = 126,

    usb_jtag_trst = 127,

    gpio = 128,
};

pub const InputSignal = switch (compatibility.chip) {
    .esp32_c3 => InputSignal_C3,
    .esp32_c6 => InputSignal_C6,
};

pub const OutputSignal = switch (compatibility.chip) {
    .esp32_c3 => OutputSignal_C3,
    .esp32_c6 => OutputSignal_C6,
};

// ESP32-C6 GPIO matrix signals. Generated from esp-hal esp-metadata/devices/esp32c6/gpio.toml
// (which mirrors ESP-IDF soc/esp32c6/include/soc/gpio_sig_map.h). IO MUX-only functions are omitted.
const InputSignal_C6 = enum(u8) {
    ext_adc_start = 0,
    u0rxd = 6,
    u0cts = 7,
    u0dsr = 8,
    u1rxd = 9,
    u1cts = 10,
    u1dsr = 11,
    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2si_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,
    usb_jtag_tdo_bridge = 19,
    cpu_testbus0 = 20,
    cpu_testbus1 = 21,
    cpu_testbus2 = 22,
    cpu_testbus3 = 23,
    cpu_testbus4 = 24,
    cpu_testbus5 = 25,
    cpu_testbus6 = 26,
    cpu_testbus7 = 27,
    cpu_gpio_0 = 28,
    cpu_gpio_1 = 29,
    cpu_gpio_2 = 30,
    cpu_gpio_3 = 31,
    cpu_gpio_4 = 32,
    cpu_gpio_5 = 33,
    cpu_gpio_6 = 34,
    cpu_gpio_7 = 35,
    usb_jtag_tms = 37,
    usb_extphy_oen = 40,
    usb_extphy_vm = 41,
    usb_extphy_vpo = 42,
    i2cext0_scl = 45,
    i2cext0_sda = 46,
    parl_rx_data0 = 47,
    parl_rx_data1 = 48,
    parl_rx_data2 = 49,
    parl_rx_data3 = 50,
    parl_rx_data4 = 51,
    parl_rx_data5 = 52,
    parl_rx_data6 = 53,
    parl_rx_data7 = 54,
    parl_rx_data8 = 55,
    parl_rx_data9 = 56,
    parl_rx_data10 = 57,
    parl_rx_data11 = 58,
    parl_rx_data12 = 59,
    parl_rx_data13 = 60,
    parl_rx_data14 = 61,
    parl_rx_data15 = 62,
    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,
    parl_rx_clk = 69,
    parl_tx_clk = 70,
    rmt_sig_0 = 71,
    rmt_sig_1 = 72,
    twai0_rx = 73,
    twai1_rx = 77,
    pwm0_sync0 = 87,
    pwm0_sync1 = 88,
    pwm0_sync2 = 89,
    pwm0_f0 = 90,
    pwm0_f1 = 91,
    pwm0_f2 = 92,
    pwm0_cap0 = 93,
    pwm0_cap1 = 94,
    pwm0_cap2 = 95,
    sig_in_func97 = 97,
    sig_in_func98 = 98,
    sig_in_func99 = 99,
    sig_in_func100 = 100,
    pcnt0_sig_ch0 = 101,
    pcnt0_sig_ch1 = 102,
    pcnt0_ctrl_ch0 = 103,
    pcnt0_ctrl_ch1 = 104,
    pcnt1_sig_ch0 = 105,
    pcnt1_sig_ch1 = 106,
    pcnt1_ctrl_ch0 = 107,
    pcnt1_ctrl_ch1 = 108,
    pcnt2_sig_ch0 = 109,
    pcnt2_sig_ch1 = 110,
    pcnt2_ctrl_ch0 = 111,
    pcnt2_ctrl_ch1 = 112,
    pcnt3_sig_ch0 = 113,
    pcnt3_sig_ch1 = 114,
    pcnt3_ctrl_ch0 = 115,
    pcnt3_ctrl_ch1 = 116,
    spiq = 121,
    spid = 122,
    spihd = 123,
    spiwp = 124,
};

const OutputSignal_C6 = enum(u8) {
    ledc_ls_sig0 = 0,
    ledc_ls_sig1 = 1,
    ledc_ls_sig2 = 2,
    ledc_ls_sig3 = 3,
    ledc_ls_sig4 = 4,
    ledc_ls_sig5 = 5,
    u0txd = 6,
    u0rts = 7,
    u0dtr = 8,
    u1txd = 9,
    u1rts = 10,
    u1dtr = 11,
    i2s_mclk = 12,
    i2so_bck = 13,
    i2so_ws = 14,
    i2so_sd = 15,
    i2si_bck = 16,
    i2si_ws = 17,
    i2so_sd1 = 18,
    usb_jtag_tdo_bridge = 19,
    cpu_testbus0 = 20,
    cpu_testbus1 = 21,
    cpu_testbus2 = 22,
    cpu_testbus3 = 23,
    cpu_testbus4 = 24,
    cpu_testbus5 = 25,
    cpu_testbus6 = 26,
    cpu_testbus7 = 27,
    cpu_gpio_0 = 28,
    cpu_gpio_1 = 29,
    cpu_gpio_2 = 30,
    cpu_gpio_3 = 31,
    cpu_gpio_4 = 32,
    cpu_gpio_5 = 33,
    cpu_gpio_6 = 34,
    cpu_gpio_7 = 35,
    usb_jtag_tck = 36,
    usb_jtag_tms = 37,
    usb_jtag_tdi = 38,
    usb_jtag_tdo = 39,
    i2cext0_scl = 45,
    i2cext0_sda = 46,
    parl_tx_data0 = 47,
    parl_tx_data1 = 48,
    parl_tx_data2 = 49,
    parl_tx_data3 = 50,
    parl_tx_data4 = 51,
    parl_tx_data5 = 52,
    parl_tx_data6 = 53,
    parl_tx_data7 = 54,
    parl_tx_data8 = 55,
    parl_tx_data9 = 56,
    parl_tx_data10 = 57,
    parl_tx_data11 = 58,
    parl_tx_data12 = 59,
    parl_tx_data13 = 60,
    parl_tx_data14 = 61,
    parl_tx_data15 = 62,
    fspiclk = 63,
    fspiq = 64,
    fspid = 65,
    fspihd = 66,
    fspiwp = 67,
    fspics0 = 68,
    sdio_tohost_int = 69,
    parl_tx_clk = 70,
    rmt_sig_0 = 71,
    rmt_sig_1 = 72,
    twai0_tx = 73,
    twai0_bus_off_on = 74,
    twai0_clkout = 75,
    twai0_standby = 76,
    twai1_tx = 77,
    twai1_bus_off_on = 78,
    twai1_clkout = 79,
    twai1_standby = 80,
    gpio_sd0 = 83,
    gpio_sd1 = 84,
    gpio_sd2 = 85,
    gpio_sd3 = 86,
    pwm0_0a = 87,
    pwm0_0b = 88,
    pwm0_1a = 89,
    pwm0_1b = 90,
    pwm0_2a = 91,
    pwm0_2b = 92,
    sig_in_func97 = 97,
    sig_in_func98 = 98,
    sig_in_func99 = 99,
    sig_in_func100 = 100,
    fspics1 = 101,
    fspics2 = 102,
    fspics3 = 103,
    fspics4 = 104,
    fspics5 = 105,
    spiclk = 114,
    spics0 = 115,
    spics1 = 116,
    gpio_task_matrix_out0 = 117,
    gpio_task_matrix_out1 = 118,
    gpio_task_matrix_out2 = 119,
    gpio_task_matrix_out3 = 120,
    spiq = 121,
    spid = 122,
    spihd = 123,
    spiwp = 124,
    clk_out_out1 = 125,
    clk_out_out2 = 126,
    clk_out_out3 = 127,
    gpio = 128,
};

pub const Pull = enum {
    up,
    down,
    disabled,
};

pub const Mask = enum(@Int(.unsigned, pin_count)) {
    _,
};

pub fn num(n: u5) Pin {
    std.debug.assert(n < pin_count);
    return @as(Pin, @fromBackingInt(n));
}

pub const Pin = enum(u5) {
    _,

    pub const Config = struct {
        output_enable: bool = false,
        input_enable: bool = false,
        open_drain: bool = false,
        pull: Pull = .disabled,
        drive_strength: DriveStrength = .@"5mA",
        input_filter_enable: bool = false,

        pub const analog: Config = .{
            .output_enable = false,
            .input_enable = false,
            .pull = .disabled,
        };
    };

    fn assert_usb_disabled(self: Pin) void {
        const n = @backingInt(self);

        // NOTE: Assert that the USB_SERIAL_JTAG peripheral which uses the USB pins
        //       is disabled and USB pullup/down resistors are disabled.
        if (n == usb_pins[0] or n == usb_pins[1]) {
            const usb_conf0 = peripherals.USB_DEVICE.CONF0.read();
            std.debug.assert(usb_conf0.USB_PAD_ENABLE == 0 and
                usb_conf0.DP_PULLUP == 0 and
                usb_conf0.DP_PULLDOWN == 0 and
                usb_conf0.DM_PULLUP == 0 and
                usb_conf0.DM_PULLDOWN == 0);
        }
    }

    pub fn apply(self: Pin, config: Config) void {
        self.assert_usb_disabled();

        const n = @backingInt(self);

        GPIO.FUNC_OUT_SEL_CFG[@backingInt(self)].modify(.{
            .OUT_SEL = @backingInt(OutputSignal.gpio),
        });

        IO_MUX.GPIO[n].modify(.{
            .SLP_SEL = 0,
            .FUN_WPD = @intFromBool(config.pull == .down),
            .FUN_WPU = @intFromBool(config.pull == .up),
            .FUN_DRV = config.drive_strength.to_value(self),
            .FUN_IE = @intFromBool(config.input_enable),
            .MCU_SEL = @backingInt(AlternateFunction.function1),
            .FILTER_EN = @intFromBool(config.input_filter_enable),
        });

        set_pad_driver(n, config.open_drain);

        if (config.output_enable) {
            GPIO.ENABLE_W1TS.raw = @as(u32, 1) << n;
        } else {
            GPIO.ENABLE_W1TC.raw = @as(u32, 1) << n;
        }
    }

    pub const ConnectToOutputOptions = struct {
        signal: OutputSignal,
        invert: bool = false,
        output_enable_signal_controlled_by_peripheral: bool = false,
        invert_output_enable_signal: bool = false,
    };

    // TODO: bypass gpio matrix
    pub fn connect_peripheral_to_output(self: Pin, options: ConnectToOutputOptions) void {
        self.assert_usb_disabled();

        GPIO.FUNC_OUT_SEL_CFG[@backingInt(self)].write(.{
            .OUT_SEL = @backingInt(options.signal),
            .OEN_SEL = @intFromBool(!options.output_enable_signal_controlled_by_peripheral),
            .INV_SEL = @intFromBool(options.invert),
            .OEN_INV_SEL = @intFromBool(options.invert_output_enable_signal),
        });
    }

    pub const ConnectToInputOptions = struct {
        signal: InputSignal,
        invert: bool = false,
    };

    // TODO: bypass gpio matrix
    pub fn connect_input_to_peripheral(self: Pin, options: ConnectToInputOptions) void {
        self.assert_usb_disabled();

        GPIO.FUNC_IN_SEL_CFG[@backingInt(options.signal)].write(.{
            .IN_SEL = @backingInt(self),
            .IN_INV_SEL = @intFromBool(options.invert),
            .SEL = 1,
        });
    }

    pub fn set_output_enabled(self: Pin, enable: bool) void {
        const n = @backingInt(self);
        if (enable) {
            GPIO.ENABLE_W1TS.raw = @as(u32, 1) << n;
        } else {
            GPIO.ENABLE_W1TC.raw = @as(u32, 1) << n;
        }
    }

    pub fn set_output_invert(self: Pin, invert: bool) void {
        GPIO.FUNC_OUT_SEL_CFG[@backingInt(self)].write(.{
            .INV_SEL = @intFromBool(invert),
        });
    }

    pub fn set_input_enabled(self: Pin, enable: bool) void {
        IO_MUX.GPIO[@backingInt(self)].modify(.{
            .FUN_IE = @intFromBool(enable),
        });
    }

    pub fn set_input_invert(self: Pin, invert: bool) void {
        GPIO.FUNC_IN_SEL_CFG[@backingInt(self)].write(.{
            .IN_INV_SEL = @intFromBool(invert),
        });
    }

    pub fn set_input_filter_enabled(self: Pin, enable: bool) void {
        GPIO.FUNC_IN_SEL_CFG[@backingInt(self)].write(.{
            .FILTER_EN = @intFromBool(enable),
        });
    }

    pub fn set_pull(self: Pin, pull: Pull) void {
        IO_MUX.GPIO[@backingInt(self)].modify(.{
            .FUN_WPD = @intFromBool(pull == .down),
            .FUN_WPU = @intFromBool(pull == .up),
        });
    }

    pub fn set_drive_strength(self: Pin, drive_strength: DriveStrength) void {
        IO_MUX.GPIO[@backingInt(self)].modify(.{
            .FUN_DRV = drive_strength.to_value(self),
        });
    }

    pub fn set_open_drain(self: Pin, open_drain: bool) void {
        set_pad_driver(@backingInt(self), open_drain);
    }

    pub fn put(self: Pin, level: u1) void {
        const n = @backingInt(self);
        switch (level) {
            0 => {
                GPIO.OUT_W1TC.raw = @as(u32, 1) << n;
            },
            1 => {
                GPIO.OUT_W1TS.raw = @as(u32, 1) << n;
            },
        }
    }

    pub fn read(self: Pin) u1 {
        std.debug.assert(IO_MUX.GPIO[@backingInt(self)].read().FUN_IE == 1);

        return @intCast((GPIO.IN.raw >> @backingInt(self)) & 1);
    }

    pub fn toggle(self: Pin) void {
        switch (self.read()) {
            0 => self.put(1),
            1 => self.put(0),
        }
    }
};

fn set_pad_driver(n: u5, open_drain: bool) void {
    switch (compatibility.chip) {
        .esp32_c3 => GPIO.PIN[n].modify(.{ .PIN_PAD_DRIVER = @intFromBool(open_drain) }),
        .esp32_c6 => GPIO.PIN[n].modify(.{ .PAD_DRIVER = @intFromBool(open_drain) }),
    }
}
