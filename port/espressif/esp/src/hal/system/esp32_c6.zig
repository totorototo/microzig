const std = @import("std");
const microzig = @import("microzig");

const peripherals = microzig.chip.peripherals;
const INTPRI = peripherals.INTPRI;

/// Peripherals with a clock-enable/reset register in PCR.
///
/// Unlike the C3, the C6 has one `*_CONF` register per peripheral in PCR. Field names match the C3
/// mask where the peripheral exists on both chips, so drivers don't need to change.
pub const PeripheralMask = packed struct {
    pub const empty: PeripheralMask = .{};
    pub const all: PeripheralMask = empty.inverse();

    pub const keep_enabled: PeripheralMask = .{
        .uart0 = true,
        .usb_device = true,
        .systimer = true,
        // Internal (flash/PSRAM) and required for the CPU to run or route interrupts.
        .spi01 = true,
        .intmtx = true,
        .iomux = true,
        .cache = true,
    };

    pub const all_but_keep_enabled: PeripheralMask = all.subtract(keep_enabled.inverse());

    uart0: bool = false,
    uart1: bool = false,
    spi01: bool = false,
    i2c_ext0: bool = false,
    uhci0: bool = false,
    rmt: bool = false,
    ledc: bool = false,
    timergroup0: bool = false,
    timergroup1: bool = false,
    systimer: bool = false,
    twai: bool = false,
    twai1: bool = false,
    i2s0: bool = false,
    apb_saradc: bool = false,
    tsens: bool = false,
    usb_device: bool = false,
    intmtx: bool = false,
    pcnt: bool = false,
    etm: bool = false,
    mcpwm: bool = false,
    parl_io: bool = false,
    sdio_slave: bool = false,
    dma: bool = false,
    spi2: bool = false,
    crypto_aes: bool = false,
    crypto_sha: bool = false,
    crypto_rsa: bool = false,
    crypto_ecc: bool = false,
    crypto_ds: bool = false,
    crypto_hmac: bool = false,
    iomux: bool = false,
    mem_monitor: bool = false,
    trace: bool = false,
    assist_debug: bool = false,
    cache: bool = false,

    const Bits = @typeInfo(PeripheralMask).@"struct".backing_integer.?;

    /// Combines two peripherals masks. Binary or.
    pub fn combine(self: PeripheralMask, other: PeripheralMask) PeripheralMask {
        return @bitCast(@as(Bits, @bitCast(self)) | @as(Bits, @bitCast(other)));
    }

    /// Subtracts two peripherals masks. Binary and.
    pub fn subtract(self: PeripheralMask, other: PeripheralMask) PeripheralMask {
        return @bitCast(@as(Bits, @bitCast(self)) & @as(Bits, @bitCast(other)));
    }

    /// Inverses the peripheral mask. Binary not.
    pub fn inverse(self: PeripheralMask) PeripheralMask {
        return @bitCast(~@as(Bits, @bitCast(self)));
    }
};

const ConfReg = struct {
    /// Offset of the `*_CONF` register from the PCR base address.
    offset: u16,
    clk_en_bit: u5 = 0,
    rst_en_bit: u5 = 1,
};

/// Offsets and bit positions extracted from the ESP32-C6 SVD (PCR peripheral).
const MaskField = std.meta.FieldEnum(PeripheralMask);

const conf_regs = std.enums.EnumArray(MaskField, ConfReg).init(.{
    .uart0 = .{ .offset = 0x00 },
    .uart1 = .{ .offset = 0x0c },
    .spi01 = .{ .offset = 0x18 },
    .i2c_ext0 = .{ .offset = 0x20 },
    .uhci0 = .{ .offset = 0x28 },
    .rmt = .{ .offset = 0x2c },
    .ledc = .{ .offset = 0x34 },
    .timergroup0 = .{ .offset = 0x3c },
    .timergroup1 = .{ .offset = 0x48 },
    .systimer = .{ .offset = 0x54 },
    .twai = .{ .offset = 0x5c },
    .twai1 = .{ .offset = 0x64 },
    .i2s0 = .{ .offset = 0x6c },
    .apb_saradc = .{ .offset = 0x80 },
    .tsens = .{ .offset = 0x88, .clk_en_bit = 22, .rst_en_bit = 23 },
    .usb_device = .{ .offset = 0x8c },
    .intmtx = .{ .offset = 0x90 },
    .pcnt = .{ .offset = 0x94 },
    .etm = .{ .offset = 0x98 },
    .mcpwm = .{ .offset = 0x9c },
    .parl_io = .{ .offset = 0xa4 },
    .sdio_slave = .{ .offset = 0xb0 },
    .dma = .{ .offset = 0xbc },
    .spi2 = .{ .offset = 0xc0 },
    .crypto_aes = .{ .offset = 0xc8 },
    .crypto_sha = .{ .offset = 0xcc },
    .crypto_rsa = .{ .offset = 0xd0 },
    .crypto_ecc = .{ .offset = 0xd8 },
    .crypto_ds = .{ .offset = 0xe0 },
    .crypto_hmac = .{ .offset = 0xe4 },
    .iomux = .{ .offset = 0xe8 },
    .mem_monitor = .{ .offset = 0xf0 },
    .trace = .{ .offset = 0xfc },
    .assist_debug = .{ .offset = 0x100 },
    .cache = .{ .offset = 0x104 },
});

fn conf_reg_ptr(reg: ConfReg) *volatile u32 {
    return @ptrFromInt(@intFromPtr(peripherals.PCR) + reg.offset);
}

fn update(mask: PeripheralMask, comptime which: enum { clk, rst }, set: bool) void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(PeripheralMask).@"struct".field_names) |field_name| {
        if (@field(mask, field_name)) {
            const reg = comptime conf_regs.get(@field(MaskField, field_name));
            const bit: u32 = @as(u32, 1) << switch (which) {
                .clk => reg.clk_en_bit,
                .rst => reg.rst_en_bit,
            };
            const ptr = conf_reg_ptr(reg);
            if (set) ptr.* |= bit else ptr.* &= ~bit;
        }
    }
}

/// Disables most peripheral clocks and puts peripherals in the reset state to bring them to a known state.
pub fn init() void {
    clocks_enable_clear(.all_but_keep_enabled);
    peripheral_reset_set(.all_but_keep_enabled);
}

/// Enables the bus clocks of the peripherals in the mask.
pub fn clocks_enable_set(mask: PeripheralMask) void {
    update(mask, .clk, true);
}

/// Disables the bus clocks of the peripherals in the mask.
pub fn clocks_enable_clear(mask: PeripheralMask) void {
    update(mask, .clk, false);
}

/// Pulses reset for the peripherals in the mask.
pub fn peripheral_reset(mask: PeripheralMask) void {
    peripheral_reset_set(mask);
    peripheral_reset_clear(mask);
}

/// Holds the peripherals in the mask in reset.
pub fn peripheral_reset_set(mask: PeripheralMask) void {
    update(mask, .rst, true);
}

/// Releases the peripherals in the mask from reset.
pub fn peripheral_reset_clear(mask: PeripheralMask) void {
    update(mask, .rst, false);
}

/// Enable clocks and release peripherals from reset.
pub fn enable_clocks_and_release_reset(mask: PeripheralMask) void {
    clocks_enable_set(mask);
    peripheral_reset_clear(mask);
}

pub const CPU_Interrupt = enum {
    cpu_interrupt_0,
    cpu_interrupt_1,
    cpu_interrupt_2,
    cpu_interrupt_3,

    pub fn source(cpu_interrupt: CPU_Interrupt) microzig.cpu.interrupt.Source {
        return switch (cpu_interrupt) {
            .cpu_interrupt_0 => .from_cpu_intr0,
            .cpu_interrupt_1 => .from_cpu_intr1,
            .cpu_interrupt_2 => .from_cpu_intr2,
            .cpu_interrupt_3 => .from_cpu_intr3,
        };
    }

    pub fn set_pending(cpu_interrupt: CPU_Interrupt, enabled: bool) void {
        // The four registers have identical layouts but distinct generated types.
        const reg: @TypeOf(&INTPRI.CPU_INTR_FROM_CPU0) = switch (cpu_interrupt) {
            .cpu_interrupt_0 => @ptrCast(&INTPRI.CPU_INTR_FROM_CPU0),
            .cpu_interrupt_1 => @ptrCast(&INTPRI.CPU_INTR_FROM_CPU1),
            .cpu_interrupt_2 => @ptrCast(&INTPRI.CPU_INTR_FROM_CPU2),
            .cpu_interrupt_3 => @ptrCast(&INTPRI.CPU_INTR_FROM_CPU3),
        };
        reg.write(.{ .CPU_INTR = @intFromBool(enabled) });
    }
};
