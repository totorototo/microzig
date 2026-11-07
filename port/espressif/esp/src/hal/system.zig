//! Peripheral clock gating and reset, plus CPU-to-CPU software interrupts.
//! The API is the same on every chip; peripherals that a chip doesn't have aren't in its mask.
const compatibility = @import("compatibility.zig");

const chip_specific = switch (compatibility.chip) {
    .esp32_c3 => @import("system/esp32_c3.zig"),
    .esp32_c6 => @import("system/esp32_c6.zig"),
};

pub const PeripheralMask = chip_specific.PeripheralMask;
pub const CPU_Interrupt = chip_specific.CPU_Interrupt;

pub const init = chip_specific.init;
pub const clocks_enable_set = chip_specific.clocks_enable_set;
pub const clocks_enable_clear = chip_specific.clocks_enable_clear;
pub const peripheral_reset = chip_specific.peripheral_reset;
pub const peripheral_reset_set = chip_specific.peripheral_reset_set;
pub const peripheral_reset_clear = chip_specific.peripheral_reset_clear;
pub const enable_clocks_and_release_reset = chip_specific.enable_clocks_and_release_reset;
