const std = @import("std");
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const PCR = peripherals.PCR;
const LP_AON = peripherals.LP_AON;
const PMU = peripherals.PMU;
const I2C_ANA_MST = peripherals.I2C_ANA_MST;
const regi2c = @import("../regi2c_esp32_c6.zig");
const rom = microzig.hal.rom;
const clocks = microzig.hal.clocks;

// helpful links:
// - https://github.com/espressif/esp-idf/blob/master/components/esp_hw_support/port/esp32c6/rtc_clk.c
// - https://github.com/esp-rs/esp-hal/blob/main/esp-metadata/devices/esp32c6/clocks.toml
//
// Clock tree (40 MHz XTAL):
//   SOC_ROOT = XTAL (40 MHz) | PLL (480 MHz)
//   HP_ROOT  = SOC_ROOT / 1 for XTAL, / 3 for PLL (160 MHz)
//   CPU      = HP_ROOT / (CPU_{HS,LS}_DIV_NUM + 1)
//   AHB      = HP_ROOT / (AHB_{HS,LS}_DIV_NUM + 1)
//   APB      = AHB / (APB_DIV_NUM + 1)
//
// Peripherals like UART, LEDC and I2C pick their own function clock in PCR, so most drivers
// don't depend on the CPU clock.
//
// PLL: if the CPU already runs from the BBPLL (the ESP-IDF 2nd stage bootloader leaves it that
// way), `apply` only changes dividers. Otherwise it powers up and calibrates the BBPLL first
// (`enable_pll`), so a PLL config also works from a cold XTAL start.

pub const xtal_clk_freq: u32 = 40_000_000;

const pll_hp_root_freq: u32 = 160_000_000;

pub const CpuClockSource = union(enum) {
    pub const PllClock = struct {
        pub const CpuFreq = enum {
            @"80mhz",
            @"160mhz",
        };

        cpu_freq: CpuFreq,
    };

    pll_clk: PllClock,
    /// XTAL divider (CPU = 40 MHz / div). Valid: 1, 2, 4, 8, 16, 32.
    xtal_clk: u6,
};

pub const Config = struct {
    /// Default clock config.
    pub const default: Config = .init_comptime(80_000_000);

    cpu_clk_source: CpuClockSource,

    cpu_clk_freq: u32,
    ahb_clk_freq: u32,
    apb_clk_freq: u32,

    /// Initializes a clock config for this cpu frequency.
    pub fn init(cpu_clk_freq: u32) clocks.Error!Config {
        const cpu_clk_source: CpuClockSource = switch (cpu_clk_freq) {
            160_000_000 => .{ .pll_clk = .{ .cpu_freq = .@"160mhz" } },
            80_000_000 => .{ .pll_clk = .{ .cpu_freq = .@"80mhz" } },
            40_000_000 => .{ .xtal_clk = 1 },
            20_000_000 => .{ .xtal_clk = 2 },
            10_000_000 => .{ .xtal_clk = 4 },
            5_000_000 => .{ .xtal_clk = 8 },
            2_500_000 => .{ .xtal_clk = 16 },
            1_250_000 => .{ .xtal_clk = 32 },
            else => return error.InvalidCpuClockFrequency,
        };

        return init_from_cpu_clock_source(cpu_clk_source);
    }

    /// Initializes a clock config for this cpu frequency at comptime. Triggers a compilation error
    /// if the frequency is invalid.
    pub fn init_comptime(cpu_clk_freq: u32) Config {
        return init(cpu_clk_freq) catch {
            @compileError(std.fmt.comptimePrint("Invalid cpu clock frequency: {}", .{cpu_clk_freq}));
        };
    }

    /// Initializes a clock config from a cpu clock source.
    pub fn init_from_cpu_clock_source(cpu_clk_source: CpuClockSource) Config {
        return switch (cpu_clk_source) {
            .pll_clk => |pll_clk| .{
                .cpu_clk_source = cpu_clk_source,
                .cpu_clk_freq = switch (pll_clk.cpu_freq) {
                    .@"80mhz" => 80_000_000,
                    .@"160mhz" => 160_000_000,
                },
                // AHB_HS_DIV_NUM = 3 -> 160 / 4
                .ahb_clk_freq = 40_000_000,
                .apb_clk_freq = 40_000_000,
            },
            .xtal_clk => |div| .{
                .cpu_clk_source = cpu_clk_source,
                .cpu_clk_freq = xtal_clk_freq / div,
                // AHB follows the CPU divider on XTAL, as in ESP-IDF.
                .ahb_clk_freq = xtal_clk_freq / div,
                .apb_clk_freq = xtal_clk_freq / div,
            },
        };
    }

    /// Applies this clock config.
    pub fn apply(config: Config) void {
        const cs = microzig.interrupt.enter_critical_section();
        defer cs.leave();

        switch (config.cpu_clk_source) {
            .pll_clk => |pll_clk| {
                // Never recalibrate the PLL the CPU is running from (ESP-IDF does the same).
                if (PCR.SYSCLK_CONF.read().SOC_CLK_SEL != soc_clk_sel_pll) enable_pll();
                switch_to_pll(pll_clk.cpu_freq);
            },
            .xtal_clk => |div| switch_to_xtal(div),
        }

        apb_freq_update(config.apb_clk_freq);
        rom_cpu_frequency_update(config.cpu_clk_freq);
    }
};

const soc_clk_sel_xtal = 0;
const soc_clk_sel_pll = 1;

/// Powers up the BBPLL and calibrates it to 480 MHz from the 40 MHz XTAL.
/// Port of esp-hal `enable_pll_clk_impl` / ESP-IDF `rtc_clk_bbpll_enable` + `_configure`.
fn enable_pll() void {
    // Power up the BBPLL and its I2C interface. These are write-trigger bits.
    PMU.IMM_HP_CK_POWER.write(.{
        .TIE_HIGH_XPD_BB_I2C = 1,
        .TIE_HIGH_XPD_BBPLL = 1,
        .TIE_HIGH_XPD_BBPLL_I2C = 1,
    });
    PMU.IMM_HP_CK_POWER.write(.{ .TIE_HIGH_GLOBAL_BBPLL_ICG = 1 });

    // Calibration start.
    I2C_ANA_MST.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_HIGH = 0, .BBPLL_STOP_FORCE_LOW = 1 });

    const div_ref: u8 = 0; // don't divide the reference clock
    const dchgp: u8 = 5;
    const dcur: u8 = 3;
    regi2c.write(.bbpll, regi2c.bbpll.oc_ref, (dchgp << 4) | div_ref);
    regi2c.write(.bbpll, regi2c.bbpll.oc_div, 8); // 40 MHz * (8 + 4) = 480 MHz
    regi2c.write_mask(.bbpll, regi2c.bbpll.oc_dr, 2, 0, 0); // OC_DR1
    regi2c.write_mask(.bbpll, regi2c.bbpll.oc_dr, 6, 4, 0); // OC_DR3
    regi2c.write(.bbpll, regi2c.bbpll.reg6, (1 << 6) | (3 << 4) | dcur); // DLREF/DHREF/DCUR
    regi2c.write_mask(.bbpll, regi2c.bbpll.reg9, 1, 0, 2); // OC_VCO_DBIAS

    while (I2C_ANA_MST.ANA_CONF0.read().CAL_DONE == 0) {}
    // Calibration might stop early (esp-hal / ESP-IDF workaround).
    rom.delay_us(10);

    // Calibration stop.
    I2C_ANA_MST.ANA_CONF0.modify(.{ .BBPLL_STOP_FORCE_HIGH = 1, .BBPLL_STOP_FORCE_LOW = 0 });
}

/// Powers down the BBPLL. The CPU must already run from XTAL (apply an XTAL config first).
/// Stops everything clocked from PLL taps, notably USB-Serial-JTAG (48 MHz); peripherals on
/// PLL_F80M etc. stop until a PLL config is applied again.
pub fn disable_pll() void {
    std.debug.assert(PCR.SYSCLK_CONF.read().SOC_CLK_SEL != soc_clk_sel_pll);
    PMU.IMM_HP_CK_POWER.write(.{ .TIE_LOW_GLOBAL_BBPLL_ICG = 1 });
    PMU.IMM_HP_CK_POWER.write(.{
        .TIE_LOW_XPD_BB_I2C = 1,
        .TIE_LOW_XPD_BBPLL = 1,
        .TIE_LOW_XPD_BBPLL_I2C = 1,
    });
}

fn switch_to_pll(cpu_freq: CpuClockSource.PllClock.CpuFreq) void {
    // The MSPI (flash) clock's default HS divider gives 120 MHz, which the flash can't take.
    // Set it to PLL / 6 = 80 MHz before routing the root clock through the HS path.
    PCR.MSPI_CLK_CONF.modify(.{ .MSPI_FAST_HS_DIV_NUM = 5 });

    PCR.AHB_FREQ_CONF.modify(.{ .AHB_HS_DIV_NUM = 3 });
    PCR.APB_FREQ_CONF.modify(.{ .APB_DIV_NUM = 0 });
    PCR.CPU_FREQ_CONF.modify(.{
        .CPU_HS_DIV_NUM = @as(u8, switch (cpu_freq) {
            .@"160mhz" => 0,
            .@"80mhz" => 1,
        }),
    });

    PCR.SYSCLK_CONF.modify(.{ .SOC_CLK_SEL = soc_clk_sel_pll });
}

fn switch_to_xtal(div: u6) void {
    const div_num: u8 = div - 1;
    PCR.AHB_FREQ_CONF.modify(.{ .AHB_LS_DIV_NUM = div_num });
    PCR.APB_FREQ_CONF.modify(.{ .APB_DIV_NUM = 0 });
    PCR.CPU_FREQ_CONF.modify(.{ .CPU_LS_DIV_NUM = div_num });

    PCR.SYSCLK_CONF.modify(.{ .SOC_CLK_SEL = soc_clk_sel_xtal });
}

/// Same encoding ESP-IDF uses for RTC_APB_FREQ_REG (LP_AON_STORE5 on the C6).
fn apb_freq_update(freq: u32) void {
    const v = (freq >> 12) & @as(u32, std.math.maxInt(u16));
    LP_AON.STORE5.write_raw(v | (v << 16));
}

fn rom_cpu_frequency_update(freq: u32) void {
    rom.functions.ets_update_cpu_frequency(freq / 1_000_000);
}
