//! ESP32-C6 modem power and clock control for the radio drivers.
//!
//! Ported from esp-hal (esp-hal/src/rtc_cntl/rtc/esp32c6.rs, esp-radio/src/radio_clocks,
//! esp-phy/src/phy_clocks), which mirror ESP-IDF's modem_clock and pmu code.
//!
//! Only what the radios need in the PMU active state is done here. ESP-IDF's full `pmu_init`
//! (sleep-state regulator/clock tables, OCode calibration) is not ported yet, so light sleep and
//! modem sleep are not supported.
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const PMU = peripherals.PMU;
const MODEM_SYSCON = peripherals.MODEM_SYSCON;
const MODEM_LPCON = peripherals.MODEM_LPCON;
const LP_AON = peripherals.LP_AON;

const icg_modem_code_active = 2;
const icg_nogating_modem: u4 = 1 << 1;
const icg_nogating_active: u4 = 1 << 2;
const icg_nogating_active_modem: u4 = icg_nogating_active | icg_nogating_modem;

/// Powers the Wi-Fi domain and sets up modem clock gating and the Wi-Fi low-power clock.
/// Call once before any radio driver starts.
pub fn init() void {
    // Let the PMU state machine control the Wi-Fi power domain (no forced power down / isolation).
    PMU.POWER_PD_HPWIFI_CNTL.modify(.{
        .FORCE_HP_WIFI_RESET = 0,
        .FORCE_HP_WIFI_ISO = 0,
        .FORCE_HP_WIFI_PU = 0,
        .FORCE_HP_WIFI_NO_RESET = 0,
        .FORCE_HP_WIFI_NO_ISO = 0,
        .FORCE_HP_WIFI_PD = 0,
    });

    // modem_clock_domain_power_state_icg_map_init: bit 0/1/2 of each map = SLEEP/MODEM/ACTIVE
    // states in which the clock domain is not gated.
    MODEM_SYSCON.CLK_CONF_POWER_ST.modify(.{
        .CLK_MODEM_APB_ST_MAP = icg_nogating_active_modem,
        .CLK_MODEM_PERI_ST_MAP = icg_nogating_active,
        .CLK_WIFI_ST_MAP = icg_nogating_active_modem,
        .CLK_BT_ST_MAP = icg_nogating_active_modem,
        .CLK_FE_ST_MAP = icg_nogating_active_modem,
        .CLK_ZB_ST_MAP = icg_nogating_active_modem,
    });
    MODEM_LPCON.CLK_CONF_POWER_ST.modify(.{
        .CLK_LP_APB_ST_MAP = icg_nogating_active_modem,
        .CLK_I2C_MST_ST_MAP = icg_nogating_active_modem,
        .CLK_COEX_ST_MAP = icg_nogating_active_modem,
        .CLK_WIFIPWR_ST_MAP = icg_nogating_active_modem,
    });

    // Wi-Fi low-power clock follows the system slow clock: RC_SLOW, no divider.
    MODEM_LPCON.WIFI_LP_CLK_CONF.modify(.{
        .CLK_WIFIPWR_LP_SEL_OSC_SLOW = 1,
        .CLK_WIFIPWR_LP_SEL_OSC_FAST = 0,
        .CLK_WIFIPWR_LP_SEL_XTAL = 0,
        .CLK_WIFIPWR_LP_SEL_XTAL32K = 0,
        .CLK_WIFIPWR_LP_DIV_NUM = 0,
    });
    MODEM_LPCON.CLK_CONF.modify(.{ .CLK_WIFIPWR_EN = 1 });

    // modem_clk_domain_active_state_icg_map_preinit
    PMU.HP_ACTIVE_ICG_MODEM.modify(.{ .HP_ACTIVE_DIG_ICG_MODEM_CODE = icg_modem_code_active });
    MODEM_SYSCON.CLK_CONF_POWER_ST.modify(.{ .CLK_MODEM_APB_ST_MAP = 1 << icg_modem_code_active });
    MODEM_LPCON.CLK_CONF_POWER_ST.modify(.{
        .CLK_I2C_MST_ST_MAP = 1 << icg_modem_code_active,
        .CLK_LP_APB_ST_MAP = 1 << icg_modem_code_active,
    });
    PMU.IMM_MODEM_ICG.write(.{ .UPDATE_DIG_ICG_MODEM_EN = 1 });
    PMU.IMM_SLEEP_SYSCLK.write(.{ .UPDATE_DIG_ICG_SWITCH = 1 });
}

/// Wi-Fi MAC/baseband clocks. `CLK_WIFIPWR_EN` stays on: it drives the timer that wakes the
/// modem for the next beacon while the driver dozes.
pub fn wifi_clocks_set_enabled(enable: bool) void {
    const en = @intFromBool(enable);
    MODEM_SYSCON.CLK_CONF1.modify(.{
        .CLK_WIFI_APB_EN = en,
        .CLK_WIFIMAC_EN = en,
        .CLK_WIFIBB_160X1_EN = en,
        .CLK_WIFIBB_80X1_EN = en,
        .CLK_WIFIBB_40X1_EN = en,
        .CLK_WIFIBB_80X_EN = en,
        .CLK_WIFIBB_40X_EN = en,
        .CLK_WIFIBB_80M_EN = en,
        .CLK_WIFIBB_44M_EN = en,
        .CLK_WIFIBB_40M_EN = en,
        .CLK_WIFIBB_22M_EN = en,
    });
    // Coexistence clock, shared by all radios. Only Wi-Fi is supported for now.
    MODEM_LPCON.CLK_CONF.modify(.{ .CLK_COEX_EN = en });
}

/// Front-end clocks owned by the PHY (ESP-IDF's PHY_CLOCK_DEPS), plus the analog I2C master
/// the PHY uses for calibration.
pub fn phy_clocks_set_enabled(enable: bool) void {
    const en = @intFromBool(enable);
    MODEM_SYSCON.CLK_CONF1.modify(.{
        .CLK_FE_APB_EN = en,
        .CLK_FE_CAL_160M_EN = en,
        .CLK_FE_160M_EN = en,
        .CLK_FE_80M_EN = en,
    });
    MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = en });
    MODEM_LPCON.I2C_MST_CLK_CONF.modify(.{ .CLK_I2C_MST_SEL_160M = en });
}

/// RTC slow clock period for the Wi-Fi driver, in microseconds with 12 fractional bits.
pub fn slowclk_cal() u32 {
    // ESP-IDF stores the calibrated slow clock period in LP_AON_STORE1 (µs, 19 fractional bits).
    const rtc_clk_cal_fract = 19;
    const wifi_clk_width = 12;
    const stored = LP_AON.STORE1.raw;
    if (stored != 0) return stored >> (rtc_clk_cal_fract - wifi_clk_width);
    // Not calibrated: nominal 136 kHz RC_SLOW -> 7.35 µs.
    return (1_000_000 << wifi_clk_width) / 136_000;
}
