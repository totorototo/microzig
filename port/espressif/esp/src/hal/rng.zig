const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");

/// Hardware RNG. Output is only truly random while an entropy source runs (RF on, or SAR ADC).
pub fn random_u32() u32 {
    return switch (compatibility.chip) {
        .esp32_c3 => microzig.chip.peripherals.RNG.DATA,
        // On the C6 the RNG lives in LP_PERI; its clock is enabled in `init` (hal.init_sequence).
        .esp32_c6 => microzig.chip.peripherals.LP_PERI.RNG_DATA.raw,
    };
}

/// Enables the RNG clock (ESP32-C6, mirrors ESP-IDF's rng_ll_enable). No-op on the C3.
pub fn init() void {
    if (compatibility.chip == .esp32_c6)
        microzig.chip.peripherals.LP_PERI.CLK_EN.modify(.{ .RNG_CK_EN = 1 });
}

pub fn read(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        const count = @min(buf.len - i, 4);
        const value = random_u32();
        @memcpy(buf[i .. i + count], std.mem.asBytes(&value)[0..count]);
    }
}
