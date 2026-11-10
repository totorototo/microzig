//! The SPI flash the firmware boots from: read, write and erase, through the ROM's flash driver.
//!
//! Flash can only be programmed from 1 to 0. `write` clears bits, `erase_sector` sets a whole
//! 4096 byte sector back to 0xFF. Nothing here stops a write to the bootloader or to the running
//! app: use a data partition (see `partition_table.zig`).
//!
//! While the ROM talks to the flash chip, code in flash can't be fetched. The calls run from RAM
//! with interrupts disabled, which holds everything else off, for up to tens of milliseconds
//! during an erase.
//!
//! Based on https://github.com/esp-rs/esp-hal/tree/main/esp-storage.
const std = @import("std");
const microzig = @import("microzig");

pub const partition_table = @import("partition_table.zig");
pub const nvs = @import("nvs.zig");

pub const sector_size = 4096;

pub const Error = error{
    /// The offset or the length isn't a multiple of what the operation needs.
    NotAligned,
    /// Outside of the region.
    OutOfBounds,
    /// The flash chip reported an error, or its write protection couldn't be removed.
    FlashFailed,
    /// The flash chip didn't finish in time.
    FlashTimeout,
};

const rom = struct {
    extern fn esp_rom_spiflash_read(src_addr: u32, data: [*]u32, len: u32) callconv(.c) i32;
    extern fn esp_rom_spiflash_write(dest_addr: u32, data: [*]const u32, len: u32) callconv(.c) i32;
    extern fn esp_rom_spiflash_erase_sector(sector_number: u32) callconv(.c) i32;
    extern fn esp_rom_spiflash_unlock() callconv(.c) i32;
};

const Op = union(enum) {
    read: struct { offset: u32, data: [*]u32, len: u32 },
    write: struct { offset: u32, data: [*]const u32, len: u32 },
    erase: u32,
    unlock,
};

/// Runs one ROM call. In RAM: no instruction may be fetched from flash while the chip is busy.
noinline fn run(op: Op) linksection(".ram_text") i32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();

    return switch (op) {
        .read => |r| rom.esp_rom_spiflash_read(r.offset, r.data, r.len),
        .write => |w| rom.esp_rom_spiflash_write(w.offset, w.data, w.len),
        .erase => |sector| rom.esp_rom_spiflash_erase_sector(sector),
        .unlock => rom.esp_rom_spiflash_unlock(),
    };
}

fn check(rc: i32) Error!void {
    return switch (rc) {
        0 => {},
        2 => error.FlashTimeout,
        else => error.FlashFailed,
    };
}

var unlocked: bool = false;

/// Removes the chip's block protection before the first write or erase.
fn unlock() Error!void {
    if (unlocked) return;
    try check(run(.unlock));
    unlocked = true;
}

const bounce_len = 256;

/// Reads from the flash chip, at any offset and length.
pub fn read(offset: u32, dest: []u8) Error!void {
    // The ROM wants word aligned addresses, buffers and lengths.
    if (offset % 4 == 0 and dest.len % 4 == 0 and @intFromPtr(dest.ptr) % 4 == 0) {
        if (dest.len == 0) return;
        return check(run(.{ .read = .{
            .offset = offset,
            .data = @ptrCast(@alignCast(dest.ptr)),
            .len = @intCast(dest.len),
        } }));
    }

    var bounce: [bounce_len]u8 align(4) = undefined;
    var done: usize = 0;
    while (done < dest.len) {
        const pos = offset + @as(u32, @intCast(done));
        const start = pos & ~@as(u32, 3);
        const skip = pos - start;
        const len = @min(dest.len - done, bounce_len - skip);
        const read_len = std.mem.alignForward(usize, skip + len, 4);
        try check(run(.{ .read = .{
            .offset = start,
            .data = @ptrCast(&bounce),
            .len = @intCast(read_len),
        } }));
        @memcpy(dest[done..][0..len], bounce[skip..][0..len]);
        done += len;
    }
}

/// Programs bytes: only clears bits, erase the sector first to set them. `offset` and `data.len`
/// must be multiples of 4.
pub fn write(offset: u32, data: []const u8) Error!void {
    if (offset % 4 != 0 or data.len % 4 != 0) return error.NotAligned;
    try unlock();

    // Always through a buffer on the stack: `data` may be a constant that lives in the flash
    // itself, which can't be read while the chip is being programmed.
    var bounce: [bounce_len]u8 align(4) = undefined;
    var done: usize = 0;
    while (done < data.len) {
        const len = @min(data.len - done, bounce_len);
        @memcpy(bounce[0..len], data[done..][0..len]);
        try check(run(.{ .write = .{
            .offset = offset + @as(u32, @intCast(done)),
            .data = @ptrCast(&bounce),
            .len = @intCast(len),
        } }));
        done += len;
    }
}

/// Sets the 4096 byte sector that starts at `offset` to 0xFF.
pub fn erase_sector(offset: u32) Error!void {
    if (offset % sector_size != 0) return error.NotAligned;
    try unlock();
    try check(run(.{ .erase = offset / sector_size }));
}

/// A range of the flash, typically a partition. Offsets are relative to its start and checked
/// against its size. Has the interface `nvs.Storage` expects.
pub const Region = struct {
    pub const Error = flash.Error;

    offset: u32,
    size: u32,

    fn check_bounds(region: Region, offset: u32, len: usize) flash.Error!void {
        if (len > region.size or offset > region.size - len) return error.OutOfBounds;
    }

    pub fn read(region: Region, offset: u32, dest: []u8) flash.Error!void {
        try region.check_bounds(offset, dest.len);
        return flash.read(region.offset + offset, dest);
    }

    pub fn write(region: Region, offset: u32, data: []const u8) flash.Error!void {
        try region.check_bounds(offset, data.len);
        return flash.write(region.offset + offset, data);
    }

    pub fn erase(region: Region, offset: u32) flash.Error!void {
        try region.check_bounds(offset, sector_size);
        return flash.erase_sector(region.offset + offset);
    }
};

/// NVS storage on a flash region. Declare it as a global: it holds a 4 KiB buffer.
pub const Nvs = nvs.Storage(Region);

const flash = @This();
