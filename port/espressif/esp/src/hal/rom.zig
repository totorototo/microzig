const compatibility = @import("compatibility.zig");

/// Microsecond delay using rom function.
pub fn delay_us(us: u32) void {
    switch (compatibility.chip) {
        .esp32_c3, .esp32_c6 => functions.ets_delay_us(us),
    }
}

/// Resets the whole chip, like the reset button, and boots again.
pub fn software_reset() noreturn {
    functions.esp_rom_software_reset_system();
}

/// Resets only the CPU (peripherals keep their state) and boots again through the ROM.
/// Unlike `software_reset`, this also works in Wokwi, which ignores the C6 system reset.
pub fn software_reset_cpu() noreturn {
    functions.esp_rom_software_reset_cpu(0);
}

pub const functions = switch (compatibility.chip) {
    .esp32_c3 => struct {
        pub extern fn ets_delay_us(us: u32) callconv(.c) void;
        pub extern fn ets_get_cpu_frequency() callconv(.c) u32;
        pub extern fn ets_update_cpu_frequency(ticks_per_us: u32) callconv(.c) void;
        pub extern fn esp_rom_software_reset_system() callconv(.c) noreturn;
        pub extern fn esp_rom_software_reset_cpu(cpu_no: u32) callconv(.c) noreturn;

        pub extern fn esp_rom_regi2c_read(block: u8, host_id: u8, reg_add: u8) callconv(.c) u8;
        pub extern fn esp_rom_regi2c_read_mask(block: u8, host_id: u8, reg_add: u8, msb: u8, lsb: u8) callconv(.c) u8;
        pub extern fn esp_rom_regi2c_write(block: u8, host_id: u8, reg_add: u8, data: u8) callconv(.c) void;
        pub extern fn esp_rom_regi2c_write_mask(block: u8, host_id: u8, reg_add: u8, msb: u8, lsb: u8, data: u8) callconv(.c) void;

        pub extern fn Cache_Enable_ICache(autoload: u32) callconv(.c) void;
    },
    // The C6 ROM has no analog-I2C (regi2c) helpers; ESP-IDF drives I2C_ANA_MST directly.
    .esp32_c6 => struct {
        pub extern fn ets_delay_us(us: u32) callconv(.c) void;
        pub extern fn ets_get_cpu_frequency() callconv(.c) u32;
        pub extern fn ets_update_cpu_frequency(ticks_per_us: u32) callconv(.c) void;
        pub extern fn esp_rom_software_reset_system() callconv(.c) noreturn;
        pub extern fn esp_rom_software_reset_cpu(cpu_no: u32) callconv(.c) noreturn;
    },
};
