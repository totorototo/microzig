//! Reads the ESP-IDF partition table, which the 2nd stage bootloader also uses to find the app.
//! See https://docs.espressif.com/projects/esp-idf/en/stable/esp32c6/api-guides/partition-tables.html
const std = @import("std");
const flash = @import("flash.zig");

/// Where the table is, unless the bootloader was built with another offset.
pub const default_offset = 0x8000;
pub const max_entries = 95;

const entry_size = 32;
const entry_magic = 0x50AA;

pub const Type = enum(u8) {
    app = 0x00,
    data = 0x01,
    _,
};

/// Subtypes of `Type.data`.
pub const DataSubtype = enum(u8) {
    ota = 0x00,
    phy = 0x01,
    nvs = 0x02,
    coredump = 0x03,
    nvs_keys = 0x04,
    efuse = 0x05,
    undefined = 0x06,
    fat = 0x81,
    spiffs = 0x82,
    littlefs = 0x83,
    _,
};

pub const Partition = struct {
    type: Type,
    subtype: u8,
    offset: u32,
    size: u32,
    label_buf: [16]u8,

    pub fn label(partition: *const Partition) []const u8 {
        return std.mem.sliceTo(&partition.label_buf, 0);
    }

    pub fn region(partition: Partition) flash.Region {
        return .{ .offset = partition.offset, .size = partition.size };
    }
};

/// Iterates over the entries of the table at `table_offset`.
pub const Iterator = struct {
    table_offset: u32 = default_offset,
    index: u32 = 0,

    pub fn next(it: *Iterator) flash.Error!?Partition {
        if (it.index >= max_entries) return null;

        var raw: [entry_size]u8 align(4) = undefined;
        try flash.read(it.table_offset + it.index * entry_size, &raw);
        // The table ends with an MD5 entry (magic 0xEBEB) or with blank flash.
        if (std.mem.readInt(u16, raw[0..2], .little) != entry_magic) return null;
        it.index += 1;

        return .{
            .type = @fromBackingInt(@intCast(raw[2])),
            .subtype = raw[3],
            .offset = std.mem.readInt(u32, raw[4..8], .little),
            .size = std.mem.readInt(u32, raw[8..12], .little),
            .label_buf = raw[12..28].*,
        };
    }
};

/// Finds the first data partition with this subtype, and with this label if one is given.
pub fn find_data(subtype: DataSubtype, maybe_label: ?[]const u8) flash.Error!?Partition {
    var it: Iterator = .{};
    while (try it.next()) |partition| {
        if (partition.type != .data or partition.subtype != @backingInt(subtype)) continue;
        if (maybe_label) |wanted| {
            if (!std.mem.eql(u8, partition.label(), wanted)) continue;
        }
        return partition;
    }
    return null;
}
