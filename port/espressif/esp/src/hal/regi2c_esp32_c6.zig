//! Internal analog I2C bus ("regi2c") of the ESP32-C6.
//!
//! The analog blocks (BBPLL, bias, regulators, ULP calibration, SAR ADC) are configured through
//! I2C_ANA_MST. Unlike the C3, the C6 ROM has no regi2c helpers, so this drives the master
//! directly, as ESP-IDF (`regi2c_ctrl_ll.h`) and esp-hal (`soc/esp32c6/regi2c.rs`) do.
//!
//! Not thread safe: callers must hold a critical section (the PHY blob uses the same bus).
const microzig = @import("microzig");
const peripherals = microzig.chip.peripherals;
const I2C_ANA_MST = peripherals.I2C_ANA_MST;
const MODEM_LPCON = peripherals.MODEM_LPCON;

/// Analog block (I2C slave address).
pub const Block = enum(u8) {
    bbpll = 0x66,
    bias = 0x6a,
    dig_reg = 0x6d,
    ulp_cal = 0x61,
    sar_i2c = 0x69,
};

/// Register addresses and fields of the BBPLL block that the clock code uses.
pub const bbpll = struct {
    pub const oc_ref: u8 = 2;
    pub const oc_div: u8 = 3;
    pub const oc_dr: u8 = 5;
    pub const reg6: u8 = 6;
    pub const reg9: u8 = 9;
};

/// Enables the master clock and routes `block` to its master. Returns which of the two
/// masters (I2C0_CTRL / I2C1_CTRL) serves it.
fn select(block: Block) u1 {
    MODEM_LPCON.CLK_CONF.modify(.{ .CLK_I2C_MST_EN = 1 });
    MODEM_LPCON.I2C_MST_CLK_CONF.modify(.{ .CLK_I2C_MST_SEL_160M = 1 });

    const sel = I2C_ANA_MST.ANA_CONF2.read();
    const on_master0 = switch (block) {
        .bbpll => sel.BBPLL_MST_SEL,
        .bias => sel.BIAS_MST_SEL,
        .dig_reg => sel.DIG_REG_MST_SEL,
        .ulp_cal => sel.ULP_CAL_MST_SEL,
        .sar_i2c => sel.SAR_I2C_MST_SEL,
    } == 1;

    // Power down all slaves' read paths except this block's (ESP-IDF writes the 24-bit mask,
    // then clears the block's bit).
    const rd_bit: u5 = switch (block) {
        .bias => 6,
        .bbpll => 7,
        .ulp_cal => 8,
        .sar_i2c => 9,
        .dig_reg => 10,
    };
    I2C_ANA_MST.ANA_CONF1.write_raw(0x00FF_FFFF & ~(@as(u32, 1) << rd_bit));

    return if (on_master0) 0 else 1;
}

const Ctrl = @TypeOf(I2C_ANA_MST.I2C0_CTRL);

fn ctrl(master: u1) *volatile Ctrl {
    return switch (master) {
        0 => &I2C_ANA_MST.I2C0_CTRL,
        1 => @ptrCast(&I2C_ANA_MST.I2C1_CTRL),
    };
}

fn wait_idle(c: *volatile Ctrl) void {
    while (c.read().BUSY == 1) {}
}

pub fn read(block: Block, reg: u8) u8 {
    const c = ctrl(select(block));
    wait_idle(c);
    c.write(.{ .SLAVE_ADDR = @intFromEnum(block), .SLAVE_REG_ADDR = reg });
    wait_idle(c);
    return c.read().DATA;
}

pub fn write(block: Block, reg: u8, data: u8) void {
    const c = ctrl(select(block));
    wait_idle(c);
    c.write(.{
        .SLAVE_ADDR = @intFromEnum(block),
        .SLAVE_REG_ADDR = reg,
        .DATA = data,
        .READ_WRITE = 1,
    });
    wait_idle(c);
}

/// Read-modify-write of bits `lsb..msb` (inclusive) of `reg`.
pub fn write_mask(block: Block, reg: u8, msb: u3, lsb: u3, data: u8) void {
    const width: u4 = @as(u4, msb) - lsb + 1;
    const mask: u8 = @truncate(((@as(u16, 1) << width) - 1) << lsb);
    const old = read(block, reg);
    write(block, reg, (old & ~mask) | ((data << lsb) & mask));
}
