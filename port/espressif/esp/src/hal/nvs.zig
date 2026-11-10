//! Non-volatile key-value storage in ESP-IDF's NVS format (version 2), so that partitions can be
//! generated and inspected with Espressif's tools and shared with ESP-IDF firmware.
//!
//! This file only depends on `std`: the flash is a type parameter, which lets the tests run on the
//! host against a simulated NOR flash.
//!
//! Format, see https://docs.espressif.com/projects/esp-idf/en/stable/esp32c6/api-reference/storage/nvs_flash.html
//!   - The partition is a set of 4096 byte pages. A page has a 32 byte header (state, sequence
//!     number, CRC), a bitmap with the state of each entry (2 bits) and 126 entries of 32 bytes.
//!   - An item is one entry (namespace index, type, key, 8 bytes of data), followed for strings
//!     and blob chunks by the entries that hold their data.
//!   - Flash bits can only be cleared, so nothing is updated in place: a new item is appended, then
//!     the old one is marked erased in the bitmap. Page states also only clear bits.
//!   - One page is always kept free. When the others are full, the page with the most erased
//!     entries is copied into the free one and erased.
//!
//! Not supported: encryption, version 1 partitions, iterating over keys, and blobs written by
//! ESP-IDF older than v4 (single entry type 0x41).
const std = @import("std");
const assert = std.debug.assert;

pub const page_size = 4096;
pub const max_key_len = 15;
/// Longest string, including the terminating zero ESP-IDF stores with it.
pub const max_str_len = 4000;

/// Most pages a partition can have here (256 KiB). Each costs 8 bytes of RAM.
pub const max_pages = 64;

const entry_size = 32;
const entries_per_page = 126;
const header_size = 32;
const bitmap_offset = 32;
const entries_offset = 64;
const version_2 = 0xFE;
/// Most data in one item: all the entries of a page but the item's own.
const max_item_data = (entries_per_page - 1) * entry_size;
const max_blob_chunks = 127;

const PageState = enum(u32) {
    uninitialized = 0xFFFF_FFFF,
    active = 0xFFFF_FFFE,
    full = 0xFFFF_FFFC,
    freeing = 0xFFFF_FFF8,
    corrupt = 0xFFFF_FFF0,
    _,
};

const EntryState = enum(u2) {
    erased = 0b00,
    illegal = 0b01,
    written = 0b10,
    empty = 0b11,
};

const type_u8 = 0x01;
const type_str = 0x21;
const type_blob_data = 0x42;
const type_blob_index = 0x48;

const no_chunk = 0xFF;

/// The on-flash layout of an entry that starts an item.
const Item = extern struct {
    ns: u8,
    type: u8,
    span: u8,
    chunk_index: u8,
    crc32: [4]u8,
    key: [16]u8,
    data: [8]u8,

    comptime {
        assert(@sizeOf(Item) == entry_size);
    }

    fn compute_crc(item: *const Item) u32 {
        const bytes = std.mem.asBytes(item);
        var crc = crc32(0xFFFF_FFFF, bytes[0..4]);
        crc = crc32(crc, bytes[8..24]);
        return crc32(crc, bytes[24..32]);
    }

    fn seal(item: *Item) void {
        std.mem.writeInt(u32, &item.crc32, item.compute_crc(), .little);
    }

    fn crc_ok(item: *const Item) bool {
        return std.mem.readInt(u32, &item.crc32, .little) == item.compute_crc();
    }

    fn key_slice(item: *const Item) []const u8 {
        return std.mem.sliceTo(&item.key, 0);
    }

    /// Strings and blob chunks: byte count of the data that follows.
    fn data_len(item: *const Item) u16 {
        return std.mem.readInt(u16, item.data[0..2], .little);
    }

    fn data_crc(item: *const Item) u32 {
        return std.mem.readInt(u32, item.data[4..8], .little);
    }

    /// Blob index: total size, number of chunks and index of the first one.
    fn blob_size(item: *const Item) u32 {
        return std.mem.readInt(u32, item.data[0..4], .little);
    }
};

/// CRC-32 as computed by the ROM's `crc32_le`: `seed` is the value returned for the data before.
/// ESP-IDF's NVS starts from 0xFFFFFFFF, which is not the standard CRC-32 (that one starts at 0).
pub fn crc32(seed: u32, data: []const u8) u32 {
    var crc = ~seed;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (0 -% (crc & 1)));
        }
    }
    return ~crc;
}

pub const OpenMode = enum { read_only, read_write };

pub const Error = error{
    /// The key, or the namespace when opening read only, doesn't exist.
    NotFound,
    /// The key exists with another type.
    TypeMismatch,
    /// Keys and namespace names are 1 to 15 bytes long, without zeros.
    InvalidName,
    /// The value is longer than the format or the partition allows.
    ValueTooLong,
    /// The destination buffer is smaller than the stored value.
    BufferTooSmall,
    /// No room left, even after reclaiming erased entries.
    NotEnoughSpace,
    /// All 254 namespaces are in use.
    TooManyNamespaces,
    /// The namespace was opened read only.
    ReadOnly,
    /// The stored value doesn't match its checksum.
    Corrupt,
    /// The partition is smaller than 3 pages, larger than `max_pages`, or not a whole number
    /// of pages.
    InvalidPartition,
    /// The partition was written by ESP-IDF older than v3.3 (format version 1).
    UnsupportedVersion,
};

/// A key-value store on `Flash`, which needs, with offsets relative to the start of the partition:
///   - `pub const Error`
///   - `fn read(flash, offset: u32, dest: []u8) Error!void`
///   - `fn write(flash, offset: u32, data: []const u8) Error!void`: clears bits only (NOR flash).
///     Offsets and lengths are multiples of 4.
///   - `fn erase(flash, offset: u32) Error!void`: sets one 4096 byte sector to 0xFF.
pub fn Storage(comptime Flash: type) type {
    return struct {
        const Self = @This();

        /// `Flash` can be a pointer to the type that has the declarations.
        const FlashImpl = switch (@typeInfo(Flash)) {
            .pointer => |pointer| pointer.child,
            else => Flash,
        };

        pub const Err = Error || FlashImpl.Error;

        const PageInfo = struct {
            state: PageState = .uninitialized,
            seq: u32 = 0,
        };

        const Location = struct {
            page: u8,
            index: u8,
        };

        flash: Flash,
        page_count: u8,
        pages: [max_pages]PageInfo = @splat(.{}),
        /// The page items are appended to, and its first unused entry.
        active: ?u8 = null,
        next_free: u8 = 0,
        /// A copy of page `cached`. Every scan goes through it.
        cached: ?u8 = null,
        buf: [page_size]u8 align(4) = undefined,

        /// Opens the partition, repairing what an interrupted write may have left behind. A blank
        /// partition is valid and empty. `self` is initialized in place because it holds a 4 KiB
        /// page buffer.
        pub fn init(self: *Self, flash: Flash, partition_size: u32) Err!void {
            if (partition_size % page_size != 0) return error.InvalidPartition;
            const page_count = partition_size / page_size;
            if (page_count < 3 or page_count > max_pages) return error.InvalidPartition;

            self.* = .{ .flash = flash, .page_count = @intCast(page_count) };

            for (0..self.page_count) |i| try self.load_header(@intCast(i));

            // The page with the highest sequence number is the one being filled. An older page
            // still marked active was about to be marked full.
            var newest: ?u8 = null;
            for (0..self.page_count) |i| {
                const info = self.pages[i];
                if (info.state == .uninitialized) continue;
                if (newest == null or info.seq > self.pages[newest.?].seq) newest = @intCast(i);
            }
            for (0..self.page_count) |i| {
                if (self.pages[i].state != .active) continue;
                if (i == newest.?) {
                    self.active = newest;
                } else {
                    try self.set_page_state(@intCast(i), .full);
                }
            }

            try self.finish_reclaim();
            if (self.count_free() == 0) return error.NotEnoughSpace;

            if (self.active) |active| try self.repair_active(active);
            try self.remove_stale_items();
        }

        /// Opens a namespace, creating it in read-write mode if it doesn't exist.
        pub fn open(self: *Self, namespace: []const u8, mode: OpenMode) Err!Handle {
            try check_name(namespace);

            if (try self.find(0, type_u8, namespace, no_chunk)) |loc| {
                return .{ .storage = self, .ns = (try self.item_at(loc)).data[0], .mode = mode };
            }
            if (mode == .read_only) return error.NotFound;

            // Take the first index that no namespace entry uses.
            var used: [256]bool = @splat(false);
            for (0..self.page_count) |page| {
                if (self.pages[page].state == .uninitialized) continue;
                try self.load(@intCast(page));
                var it: Iterator = .{};
                while (it.next(self)) |index| {
                    const item = self.item_in_buf(index);
                    if (item.ns == 0 and item.type == type_u8) used[item.data[0]] = true;
                }
            }
            const ns: u8 = for (1..255) |candidate| {
                if (!used[candidate]) break @intCast(candidate);
            } else return error.TooManyNamespaces;

            var item = make_item(0, type_u8, namespace, no_chunk);
            item.data[0] = ns;
            _ = try self.append(&item, &.{}, &.{});
            return .{ .storage = self, .ns = ns, .mode = mode };
        }

        pub const Handle = struct {
            storage: *Self,
            ns: u8,
            mode: OpenMode,

            /// Reads an integer: `T` is u8, i8, u16, i16, u32, i32, u64 or i64, and must be the
            /// type the value was stored with.
            pub fn get(handle: Handle, comptime T: type, key: []const u8) Err!T {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, int_type(T), key);
                const item = try self.item_at(loc);
                return std.mem.readInt(T, item.data[0..@sizeOf(T)], .little);
            }

            /// Stores an integer. Nothing is written if the key already holds this value.
            pub fn set(handle: Handle, comptime T: type, key: []const u8, value: T) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);

                var item = make_item(handle.ns, int_type(T), key, no_chunk);
                std.mem.writeInt(T, item.data[0..@sizeOf(T)], value, .little);

                const maybe_old = try self.find_primary(handle.ns, key);
                if (maybe_old) |old| {
                    const old_item = try self.item_at(old);
                    if (old_item.type != item.type) return error.TypeMismatch;
                    if (std.mem.eql(u8, &old_item.data, &item.data)) return;
                }

                _ = try self.append(&item, &.{}, &.{});
                if (maybe_old) |old| try self.erase_item(old);
            }

            /// Reads a string into `dest` and returns the part of it that was filled.
            pub fn get_str(handle: Handle, key: []const u8, dest: []u8) Err![]u8 {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, type_str, key);
                const data = try self.item_data(loc);
                // ESP-IDF stores the terminating zero with the string.
                const str = if (data.len > 0 and data[data.len - 1] == 0) data[0 .. data.len - 1] else data;
                if (str.len > dest.len) return error.BufferTooSmall;
                @memcpy(dest[0..str.len], str);
                return dest[0..str.len];
            }

            pub fn set_str(handle: Handle, key: []const u8, value: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                if (value.len + 1 > max_str_len) return error.ValueTooLong;
                if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidName;

                const maybe_old = try self.find_primary(handle.ns, key);
                if (maybe_old) |old| {
                    if ((try self.item_at(old)).type != type_str) return error.TypeMismatch;
                }

                var item = make_item(handle.ns, type_str, key, no_chunk);
                const new = try self.append(&item, value, &.{0});
                // The append may have moved the old item to another page.
                if (try self.find_other(handle.ns, type_str, key, no_chunk, new)) |old| {
                    try self.erase_item(old);
                }
            }

            /// Size of the blob stored under `key`.
            pub fn blob_len(handle: Handle, key: []const u8) Err!usize {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, type_blob_index, key);
                return (try self.item_at(loc)).blob_size();
            }

            /// Reads a blob into `dest` and returns the part of it that was filled.
            pub fn get_blob(handle: Handle, key: []const u8, dest: []u8) Err![]u8 {
                const self = handle.storage;
                try check_name(key);
                const loc = try self.find_typed(handle.ns, type_blob_index, key);
                const index = (try self.item_at(loc)).*;

                const size = index.blob_size();
                if (size > dest.len) return error.BufferTooSmall;

                var done: usize = 0;
                for (0..index.data[4]) |i| {
                    const chunk_index = index.data[5] +% @as(u8, @intCast(i));
                    const chunk_loc = try self.find(handle.ns, type_blob_data, key, chunk_index) orelse
                        return error.Corrupt;
                    const data = try self.item_data(chunk_loc);
                    if (done + data.len > size) return error.Corrupt;
                    @memcpy(dest[done..][0..data.len], data);
                    done += data.len;
                }
                if (done != size) return error.Corrupt;
                return dest[0..size];
            }

            /// Stores a blob, split into one chunk per page it touches.
            pub fn set_blob(handle: Handle, key: []const u8, value: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                // One page stays free and each chunk needs an entry for itself.
                if (value.len > @as(usize, self.page_count - 1) * max_item_data) return error.ValueTooLong;

                const maybe_old = try self.find_primary(handle.ns, key);
                var chunk_start: u8 = 0;
                if (maybe_old) |old| {
                    const old_item = try self.item_at(old);
                    if (old_item.type != type_blob_index) return error.TypeMismatch;
                    // Two versions live side by side until the new index is written: they use
                    // different chunk numbers.
                    chunk_start = old_item.data[5] ^ 0x80;
                }

                var chunk_count: u8 = 0;
                var done: usize = 0;
                errdefer self.erase_chunks(handle.ns, key, chunk_start, chunk_count) catch {};
                while (done < value.len) {
                    if (chunk_count == max_blob_chunks) return error.ValueTooLong;

                    // Fill what is left of the page, or start a new one.
                    var room = try self.data_room();
                    if (room == 0) {
                        try self.reserve(2);
                        room = try self.data_room();
                    }
                    const len = @min(value.len - done, room);

                    var chunk = make_item(handle.ns, type_blob_data, key, chunk_start + chunk_count);
                    _ = try self.append(&chunk, value[done..][0..len], &.{});
                    done += len;
                    chunk_count += 1;
                }

                var index = make_item(handle.ns, type_blob_index, key, no_chunk);
                std.mem.writeInt(u32, index.data[0..4], @intCast(value.len), .little);
                index.data[4] = chunk_count;
                index.data[5] = chunk_start;
                const new = try self.append(&index, &.{}, &.{});

                if (try self.find_other(handle.ns, type_blob_index, key, no_chunk, new)) |old| {
                    const old_item = (try self.item_at(old)).*;
                    try self.erase_item(old);
                    try self.erase_chunks(handle.ns, key, old_item.data[5], old_item.data[4]);
                }
            }

            /// Removes a key, whatever its type.
            pub fn erase_key(handle: Handle, key: []const u8) Err!void {
                const self = handle.storage;
                try handle.check_writable(key);
                const loc = try self.find_primary(handle.ns, key) orelse return error.NotFound;
                const item = (try self.item_at(loc)).*;
                try self.erase_item(loc);
                if (item.type == type_blob_index) {
                    try self.erase_chunks(handle.ns, key, item.data[5], item.data[4]);
                }
            }

            fn check_writable(handle: Handle, key: []const u8) Err!void {
                if (handle.mode == .read_only) return error.ReadOnly;
                try check_name(key);
            }
        };

        // ----- items -----

        fn check_name(name: []const u8) Error!void {
            if (name.len == 0 or name.len > max_key_len) return error.InvalidName;
            if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
        }

        fn int_type(comptime T: type) u8 {
            const info = @typeInfo(T).int;
            const size: u8 = switch (info.bits) {
                8, 16, 32, 64 => @divExact(info.bits, 8),
                else => @compileError("NVS stores 8, 16, 32 and 64 bit integers"),
            };
            return size | (if (info.signedness == .signed) @as(u8, 0x10) else 0);
        }

        fn make_item(ns: u8, item_type: u8, key: []const u8, chunk_index: u8) Item {
            var item: Item = .{
                .ns = ns,
                .type = item_type,
                .span = 1,
                .chunk_index = chunk_index,
                .crc32 = undefined,
                .key = @splat(0),
                .data = @splat(0xFF),
            };
            @memcpy(item.key[0..key.len], key);
            return item;
        }

        /// Walks the items of the cached page, yielding the index of each one's first entry.
        const Iterator = struct {
            index: usize = 0,

            fn next(it: *Iterator, self: *Self) ?u8 {
                while (it.index < entries_per_page) {
                    const index = it.index;
                    if (self.entry_state(index) != .written) {
                        it.index += 1;
                        continue;
                    }
                    const item = self.item_in_buf(index);
                    // A bad header can't be trusted for its span: skip one entry.
                    if (!item.crc_ok() or item.span == 0 or index + item.span > entries_per_page) {
                        it.index += 1;
                        continue;
                    }
                    it.index += item.span;
                    return @intCast(index);
                }
                return null;
            }
        };

        fn matches(item: *const Item, ns: u8, item_type: u8, key: []const u8, chunk_index: u8) bool {
            return item.ns == ns and item.type == item_type and item.chunk_index == chunk_index and
                std.mem.eql(u8, item.key_slice(), key);
        }

        /// Finds the newest item with this exact type, optionally ignoring the one at `skip`.
        fn find_other(self: *Self, ns: u8, item_type: u8, key: []const u8, chunk_index: u8, skip: ?Location) Err!?Location {
            var result: ?Location = null;
            var result_seq: u32 = 0;
            for (0..self.page_count) |page| {
                const info = self.pages[page];
                if (info.state == .uninitialized) continue;
                if (result != null and info.seq < result_seq) continue;

                try self.load(@intCast(page));
                var it: Iterator = .{};
                while (it.next(self)) |index| {
                    if (skip) |s| if (s.page == page and s.index == index) continue;
                    if (matches(self.item_in_buf(index), ns, item_type, key, chunk_index)) {
                        result = .{ .page = @intCast(page), .index = index };
                        result_seq = info.seq;
                    }
                }
            }
            return result;
        }

        fn find(self: *Self, ns: u8, item_type: u8, key: []const u8, chunk_index: u8) Err!?Location {
            return self.find_other(ns, item_type, key, chunk_index, null);
        }

        /// Finds the item a key is known by: anything but a blob's data chunks.
        fn find_primary(self: *Self, ns: u8, key: []const u8) Err!?Location {
            var result: ?Location = null;
            var result_seq: u32 = 0;
            for (0..self.page_count) |page| {
                const info = self.pages[page];
                if (info.state == .uninitialized) continue;
                if (result != null and info.seq < result_seq) continue;

                try self.load(@intCast(page));
                var it: Iterator = .{};
                while (it.next(self)) |index| {
                    const item = self.item_in_buf(index);
                    if (item.ns == ns and item.type != type_blob_data and std.mem.eql(u8, item.key_slice(), key)) {
                        result = .{ .page = @intCast(page), .index = index };
                        result_seq = info.seq;
                    }
                }
            }
            return result;
        }

        fn find_typed(self: *Self, ns: u8, item_type: u8, key: []const u8) Err!Location {
            const loc = try self.find_primary(ns, key) orelse return error.NotFound;
            if ((try self.item_at(loc)).type != item_type) return error.TypeMismatch;
            return loc;
        }

        fn item_at(self: *Self, loc: Location) Err!*const Item {
            try self.load(loc.page);
            return self.item_in_buf(loc.index);
        }

        /// The data of a string or blob chunk, checked against its CRC. Valid until the next call.
        fn item_data(self: *Self, loc: Location) Err![]const u8 {
            const item = try self.item_at(loc);
            const len = item.data_len();
            if (len > @as(usize, item.span - 1) * entry_size) return error.Corrupt;
            const data = self.buf[entries_offset + (@as(usize, loc.index) + 1) * entry_size ..][0..len];
            if (crc32(0xFFFF_FFFF, data) != item.data_crc()) return error.Corrupt;
            return data;
        }

        /// Bytes of data an item appended now could carry in the active page.
        fn data_room(self: *Self) Err!usize {
            if (self.active == null) return 0;
            const free = entries_per_page - @as(usize, self.next_free);
            return if (free < 2) 0 else (free - 1) * entry_size;
        }

        /// Appends an item whose data is `data` followed by `suffix`, and returns where it went.
        fn append(self: *Self, item: *Item, data: []const u8, suffix: []const u8) Err!Location {
            const len = data.len + suffix.len;
            if (len > max_item_data) return error.ValueTooLong;
            const span = 1 + (len + entry_size - 1) / entry_size;
            item.span = @intCast(span);

            const has_data = item.type == type_str or item.type == type_blob_data;
            if (has_data) {
                std.mem.writeInt(u16, item.data[0..2], @intCast(len), .little);
                std.mem.writeInt(u16, item.data[2..4], 0xFFFF, .little);
                std.mem.writeInt(u32, item.data[4..8], crc32(crc32(0xFFFF_FFFF, data), suffix), .little);
            }
            item.seal();

            try self.reserve(@intCast(span));
            const page = self.active.?;
            const index = self.next_free;
            try self.load(page);

            // Build the entries in the page copy, then write them in one go.
            const bytes = self.buf[entries_offset + @as(usize, index) * entry_size ..][0 .. span * entry_size];
            @memset(bytes, 0xFF);
            @memcpy(bytes[0..entry_size], std.mem.asBytes(item));
            @memcpy(bytes[entry_size..][0..data.len], data);
            @memcpy(bytes[entry_size + data.len ..][0..suffix.len], suffix);
            try self.flash.write(page_offset(page) + entries_offset + @as(u32, index) * entry_size, bytes);

            // The item only exists once its entries are marked written. If power is lost before
            // that, `repair_active` discards them.
            try self.set_entry_states(page, index, @intCast(span), .written);
            self.next_free += @intCast(span);
            return .{ .page = page, .index = index };
        }

        fn erase_item(self: *Self, loc: Location) Err!void {
            const span = (try self.item_at(loc)).span;
            try self.set_entry_states(loc.page, loc.index, span, .erased);
        }

        fn erase_chunks(self: *Self, ns: u8, key: []const u8, chunk_start: u8, chunk_count: u8) Err!void {
            for (0..chunk_count) |i| {
                const chunk_index = chunk_start +% @as(u8, @intCast(i));
                if (try self.find(ns, type_blob_data, key, chunk_index)) |loc| try self.erase_item(loc);
            }
        }

        // ----- pages -----

        fn page_offset(page: u8) u32 {
            return @as(u32, page) * page_size;
        }

        fn load(self: *Self, page: u8) Err!void {
            if (self.cached == page) return;
            self.cached = null;
            try self.flash.read(page_offset(page), &self.buf);
            self.cached = page;
        }

        fn item_in_buf(self: *Self, index: usize) *const Item {
            return @ptrCast(self.buf[entries_offset + index * entry_size ..][0..entry_size]);
        }

        fn entry_state(self: *const Self, index: usize) EntryState {
            const word = std.mem.readInt(u32, self.buf[bitmap_offset + index / 16 * 4 ..][0..4], .little);
            return @fromBackingInt(@intCast(@as(u2, @truncate(word >> @intCast(index % 16 * 2)))));
        }

        /// Changes the state of `count` entries of a page, in its copy and in flash.
        fn set_entry_states(self: *Self, page: u8, first: u8, count: u8, state: EntryState) Err!void {
            try self.load(page);
            for (first..@as(usize, first) + count) |index| {
                const bytes = self.buf[bitmap_offset + index / 16 * 4 ..][0..4];
                const shift: u5 = @intCast(index % 16 * 2);
                const word = std.mem.readInt(u32, bytes, .little);
                // Only clears bits, like the flash.
                std.mem.writeInt(u32, bytes, word & ~(@as(u32, ~@backingInt(state) & 0b11) << shift), .little);
            }
            const first_word = @as(u32, first) / 16;
            const last_word = (@as(u32, first) + count - 1) / 16;
            const bytes = self.buf[bitmap_offset + first_word * 4 .. bitmap_offset + (last_word + 1) * 4];
            try self.flash.write(page_offset(page) + bitmap_offset + first_word * 4, bytes);
        }

        fn set_page_state(self: *Self, page: u8, state: PageState) Err!void {
            var bytes: [4]u8 align(4) = undefined;
            std.mem.writeInt(u32, &bytes, @backingInt(state), .little);
            try self.flash.write(page_offset(page), &bytes);
            if (self.cached == page) @memcpy(self.buf[0..4], &bytes);
            self.pages[page].state = state;
        }

        fn erase_page(self: *Self, page: u8) Err!void {
            if (self.cached == page) self.cached = null;
            try self.flash.erase(page_offset(page));
            self.pages[page] = .{};
        }

        /// Reads a page header at init. Pages that can't be used as they are get erased.
        fn load_header(self: *Self, page: u8) Err!void {
            try self.load(page);
            const header = self.buf[0..header_size];
            const state: PageState = @fromBackingInt(@intCast(std.mem.readInt(u32, header[0..4], .little)));

            switch (state) {
                .uninitialized => {
                    // An interrupted erase can leave a page that looks free but isn't blank.
                    if (!std.mem.allEqual(u8, &self.buf, 0xFF)) try self.erase_page(page);
                    self.pages[page] = .{};
                },
                .active, .full, .freeing => {
                    const crc = std.mem.readInt(u32, header[28..32], .little);
                    if (crc != crc32(0xFFFF_FFFF, header[4..28])) return self.erase_page(page);
                    if (header[8] != version_2) return error.UnsupportedVersion;
                    self.pages[page] = .{
                        .state = state,
                        .seq = std.mem.readInt(u32, header[4..8], .little),
                    };
                },
                else => try self.erase_page(page),
            }
        }

        fn count_free(self: *const Self) usize {
            var count: usize = 0;
            for (self.pages[0..self.page_count]) |info| count += @intFromBool(info.state == .uninitialized);
            return count;
        }

        fn first_free(self: *const Self) ?u8 {
            for (self.pages[0..self.page_count], 0..) |info, i| {
                if (info.state == .uninitialized) return @intCast(i);
            }
            return null;
        }

        /// Turns a free page into the active one.
        fn activate(self: *Self, page: u8) Err!void {
            var seq: u32 = 0;
            for (self.pages[0..self.page_count]) |info| {
                if (info.state != .uninitialized) seq = @max(seq, info.seq + 1);
            }

            var header: [header_size]u8 align(4) = @splat(0xFF);
            std.mem.writeInt(u32, header[0..4], @backingInt(PageState.active), .little);
            std.mem.writeInt(u32, header[4..8], seq, .little);
            header[8] = version_2;
            std.mem.writeInt(u32, header[28..32], crc32(0xFFFF_FFFF, header[4..28]), .little);
            try self.flash.write(page_offset(page), &header);

            if (self.cached == page) self.cached = null;
            self.pages[page] = .{ .state = .active, .seq = seq };
            self.active = page;
            self.next_free = 0;
        }

        /// Makes sure the active page has `span` unused entries, moving on to a new page if not.
        fn reserve(self: *Self, span: u8) Err!void {
            // Each round frees at least one entry or fails, so this ends.
            for (0..@as(usize, self.page_count) + 1) |_| {
                if (self.active != null and entries_per_page - self.next_free >= span) return;
                try self.new_page();
            }
            return error.NotEnoughSpace;
        }

        fn new_page(self: *Self) Err!void {
            if (self.active) |active| {
                try self.set_page_state(active, .full);
                self.active = null;
            }

            if (self.count_free() > 1) return self.activate(self.first_free().?);

            // Only the reserve page is left: reclaim the full page that wastes the most entries.
            var victim: ?u8 = null;
            var victim_live: usize = entries_per_page;
            for (0..self.page_count) |page| {
                if (self.pages[page].state != .full) continue;
                try self.load(@intCast(page));
                var live: usize = 0;
                for (0..entries_per_page) |index| live += @intFromBool(self.entry_state(index) == .written);
                if (live < victim_live) {
                    victim = @intCast(page);
                    victim_live = live;
                }
            }
            const page = victim orelse return error.NotEnoughSpace;

            try self.activate(self.first_free().?);
            try self.set_page_state(page, .freeing);
            try self.copy_and_erase(page);
        }

        /// Copies the live items of a page being freed into the fresh active page, then erases it.
        fn copy_and_erase(self: *Self, from: u8) Err!void {
            const to = self.active.?;
            assert(self.next_free == 0);

            try self.load(from);
            var bitmap: [32]u8 align(4) = @splat(0xFF);
            var count: u8 = 0;
            var it: Iterator = .{};
            while (it.next(self)) |index| {
                const span = self.item_in_buf(index).span;
                const bytes = self.buf[entries_offset + @as(usize, index) * entry_size ..][0 .. @as(usize, span) * entry_size];
                try self.flash.write(page_offset(to) + entries_offset + @as(u32, count) * entry_size, bytes);
                for (count..count + span) |entry| {
                    // written = 0b10: clear the low bit of the entry's pair.
                    bitmap[entry / 4] &= ~(@as(u8, 1) << @intCast(entry % 4 * 2));
                }
                count += span;
            }
            // Until this bitmap write, the copies don't count.
            if (count > 0) try self.flash.write(page_offset(to) + bitmap_offset, &bitmap);

            try self.erase_page(from);
            self.next_free = count;
        }

        /// Completes a reclaim that was interrupted, at init.
        fn finish_reclaim(self: *Self) Err!void {
            const from: u8 = for (0..self.page_count) |page| {
                if (self.pages[page].state == .freeing) break @intCast(page);
            } else return;

            // The page being freed is intact until it is erased, and its destination is only ever
            // the fresh page of this reclaim. How far the copy went can't be told reliably (its
            // bitmap write may be half done), so start it again from a blank page.
            if (self.active) |to| {
                try self.erase_page(to);
                try self.activate(to);
            } else {
                try self.activate(self.first_free() orelse return error.NotEnoughSpace);
            }
            try self.copy_and_erase(from);
        }

        /// Finds the first unused entry of the active page at init, and discards what an
        /// interrupted append left: data without the "written" mark, or items that don't check out.
        fn repair_active(self: *Self, page: u8) Err!void {
            try self.load(page);

            var next_free: u8 = 0;
            var index: u8 = 0;
            while (index < entries_per_page) {
                switch (self.entry_state(index)) {
                    .empty => {
                        const blank = std.mem.allEqual(u8, std.mem.asBytes(self.item_in_buf(index)), 0xFF);
                        if (!blank) {
                            try self.set_entry_states(page, index, 1, .erased);
                            next_free = index + 1;
                        }
                        index += 1;
                    },
                    .written => {
                        const item = self.item_in_buf(index);
                        const span = item.span;
                        var valid = item.crc_ok() and span >= 1 and @as(usize, index) + span <= entries_per_page;
                        if (valid) {
                            for (index..@as(usize, index) + span) |entry| {
                                if (self.entry_state(entry) != .written) valid = false;
                            }
                        }
                        if (valid) {
                            index += span;
                        } else {
                            try self.set_entry_states(page, index, 1, .erased);
                            index += 1;
                        }
                        next_free = index;
                    },
                    .erased, .illegal => {
                        index += 1;
                        next_free = index;
                    },
                }
            }
            self.next_free = next_free;
        }

        /// A new item is written before the old one is erased, so a power loss in between leaves
        /// both. Only the last write can be in that state: at init, drop what the newest item of
        /// the active page replaces, and blob chunks that no index refers to.
        fn remove_stale_items(self: *Self) Err!void {
            if (self.active) |page| {
                try self.load(page);
                var last: ?u8 = null;
                var it: Iterator = .{};
                while (it.next(self)) |index| last = index;

                if (last) |index| {
                    const item = self.item_in_buf(index).*;
                    const loc: Location = .{ .page = page, .index = index };
                    if (item.type != type_blob_data) {
                        while (try self.find_other(item.ns, item.type, item.key_slice(), item.chunk_index, loc)) |old| {
                            try self.erase_item(old);
                        }
                    }
                }
            }

            // Chunks of a blob whose index was never written, or was already erased.
            for (0..self.page_count) |page| {
                if (self.pages[page].state == .uninitialized) continue;
                var start: usize = 0;
                while (true) {
                    try self.load(@intCast(page));
                    var it: Iterator = .{ .index = start };
                    const index = while (it.next(self)) |i| {
                        if (self.item_in_buf(i).type == type_blob_data) break i;
                    } else break;
                    start = it.index;

                    const chunk = self.item_in_buf(index).*;
                    const owned = if (try self.find(chunk.ns, type_blob_index, chunk.key_slice(), no_chunk)) |index_loc| owned: {
                        const blob = try self.item_at(index_loc);
                        break :owned chunk.chunk_index -% blob.data[5] < blob.data[4];
                    } else false;
                    if (!owned) try self.erase_item(.{ .page = @intCast(page), .index = index });
                }
            }
        }
    };
}

// ----- tests -----

/// NOR flash in RAM: writes can only clear bits, and it can "lose power" after a number of
/// operations, leaving the last one half done.
const TestFlash = struct {
    pub const Error = error{PowerLoss};

    mem: []u8,
    /// Operations left before the power fails.
    budget: ?usize = null,
    writes: usize = 0,

    /// Set once the power has failed: nothing reaches the flash after that.
    dead: bool = false,

    fn spend(flash: *TestFlash) bool {
        const budget = flash.budget orelse return true;
        if (budget == 0) return false;
        flash.budget = budget - 1;
        return true;
    }

    fn restore_power(flash: *TestFlash) void {
        flash.budget = null;
        flash.dead = false;
    }

    pub fn read(flash: *TestFlash, offset: u32, dest: []u8) TestFlash.Error!void {
        @memcpy(dest, flash.mem[offset..][0..dest.len]);
    }

    pub fn write(flash: *TestFlash, offset: u32, data: []const u8) TestFlash.Error!void {
        std.debug.assert(offset % 4 == 0 and data.len % 4 == 0);
        if (flash.dead) return error.PowerLoss;
        const complete = flash.spend();
        flash.dead = !complete;
        // A write cut short has stored the first half of its bytes.
        const len = if (complete) data.len else data.len / 2;
        for (flash.mem[offset..][0..len], data[0..len]) |*dst, src| dst.* &= src;
        flash.writes += 1;
        if (!complete) return error.PowerLoss;
    }

    pub fn erase(flash: *TestFlash, offset: u32) TestFlash.Error!void {
        std.debug.assert(offset % page_size == 0);
        if (flash.dead) return error.PowerLoss;
        const complete = flash.spend();
        flash.dead = !complete;
        // An erase cut short has blanked half of the sector.
        @memset(flash.mem[offset..][0..if (complete) page_size else page_size / 2], 0xFF);
        if (!complete) return error.PowerLoss;
    }
};

const TestStorage = Storage(*TestFlash);
const testing = std.testing;

fn test_flash(mem: []u8) TestFlash {
    @memset(mem, 0xFF);
    return .{ .mem = mem };
}

test "crc32 matches the ROM's crc32_le" {
    // zlib.crc32(b"123456789", 0xFFFFFFFF) and the standard check value with seed 0.
    try testing.expectEqual(@as(u32, 0xCBF4_3926), crc32(0, "123456789"));
    try testing.expectEqual(@as(u32, 0xD202_D277), crc32(0xFFFF_FFFF, "123456789"));
}

test "integers, strings and blobs round trip and survive a reopen" {
    var mem: [6 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);

    const cfg = try nvs.open("config", .read_write);
    try cfg.set(u8, "boot", 7);
    try cfg.set(i32, "offset", -123456);
    try cfg.set(u64, "big", 0x0123_4567_89AB_CDEF);
    try cfg.set_str("ssid", "Wokwi-GUEST");
    var blob: [300]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = @truncate(i * 7);
    try cfg.set_blob("cal", &blob);

    // A second namespace has its own keys.
    const other = try nvs.open("other", .read_write);
    try other.set(u8, "boot", 99);

    var reopened: TestStorage = undefined;
    try reopened.init(&flash, mem.len);
    const cfg2 = try reopened.open("config", .read_only);
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(u8, 7), try cfg2.get(u8, "boot"));
    try testing.expectEqual(@as(i32, -123456), try cfg2.get(i32, "offset"));
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), try cfg2.get(u64, "big"));
    try testing.expectEqualStrings("Wokwi-GUEST", try cfg2.get_str("ssid", &buf));
    try testing.expectEqual(@as(usize, 300), try cfg2.blob_len("cal"));
    try testing.expectEqualSlices(u8, &blob, try cfg2.get_blob("cal", &buf));
    try testing.expectEqual(@as(u8, 99), try (try reopened.open("other", .read_only)).get(u8, "boot"));

    try testing.expectError(error.NotFound, cfg2.get(u8, "missing"));
    try testing.expectError(error.TypeMismatch, cfg2.get(u16, "boot"));
    try testing.expectError(error.ReadOnly, cfg2.set(u8, "boot", 1));
    try testing.expectError(error.NotFound, reopened.open("nope", .read_only));
    try testing.expectError(error.InvalidName, cfg.set(u8, "a_key_that_is_too_long", 1));
    try testing.expectError(error.BufferTooSmall, cfg2.get_str("ssid", buf[0..3]));
}

test "updates replace, erase removes, same value writes nothing" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);
    const h = try nvs.open("ns", .read_write);

    try h.set(u32, "n", 1);
    const writes = flash.writes;
    try h.set(u32, "n", 1);
    try testing.expectEqual(writes, flash.writes);

    try h.set(u32, "n", 2);
    try testing.expectEqual(@as(u32, 2), try h.get(u32, "n"));
    try testing.expectError(error.TypeMismatch, h.set(u8, "n", 3));
    try testing.expectError(error.TypeMismatch, h.set_str("n", "x"));

    var buf: [64]u8 = undefined;
    try h.set_str("s", "first");
    try h.set_str("s", "second, longer");
    try testing.expectEqualStrings("second, longer", try h.get_str("s", &buf));
    try h.set_str("s", "");
    try testing.expectEqualStrings("", try h.get_str("s", &buf));

    try h.set_blob("b", "one");
    try h.set_blob("b", "two!");
    try h.set_blob("b", "three");
    try testing.expectEqualStrings("three", try h.get_blob("b", &buf));

    try h.erase_key("b");
    try h.erase_key("n");
    try testing.expectError(error.NotFound, h.get_blob("b", &buf));
    try testing.expectError(error.NotFound, h.get(u32, "n"));
    try testing.expectError(error.NotFound, h.erase_key("n"));
}

test "a counter written many times reclaims pages" {
    var mem: [3 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);
    const h = try nvs.open("ns", .read_write);
    try h.set_str("keep", "still here");

    // 3 pages hold 2 x 126 entries: 2000 updates need many reclaims.
    for (0..2000) |i| try h.set(u32, "count", @intCast(i));
    try testing.expectEqual(@as(u32, 1999), try h.get(u32, "count"));

    var reopened: TestStorage = undefined;
    try reopened.init(&flash, mem.len);
    const h2 = try reopened.open("ns", .read_only);
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(u32, 1999), try h2.get(u32, "count"));
    try testing.expectEqualStrings("still here", try h2.get_str("keep", &buf));
}

test "a blob larger than a page is split, and the partition can fill up" {
    var mem: [4 * page_size]u8 = undefined;
    var flash = test_flash(&mem);
    var nvs: TestStorage = undefined;
    try nvs.init(&flash, mem.len);
    const h = try nvs.open("ns", .read_write);

    var big: [6000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));
    try h.set_blob("big", &big);
    var buf: [6000]u8 = undefined;
    try testing.expectEqualSlices(u8, &big, try h.get_blob("big", &buf));

    // Rewriting it needs both versions for a moment: 12000 bytes don't fit in 3 usable pages
    // with the rest, and the old version must survive the failure.
    big[0] ^= 0xFF;
    try testing.expectError(error.NotEnoughSpace, h.set_blob("big", &big));
    big[0] ^= 0xFF;
    try testing.expectEqualSlices(u8, &big, try h.get_blob("big", &buf));

    var reopened: TestStorage = undefined;
    try reopened.init(&flash, mem.len);
    try testing.expectEqualSlices(u8, &big, try (try reopened.open("ns", .read_only)).get_blob("big", &buf));

    try testing.expectError(error.ValueTooLong, h.set_blob("huge", &(@as([3 * max_item_data + 1]u8, @splat(0)))));
}

test "power loss at any point leaves the old or the new value" {
    // Runs a workload, cutting the power after every possible number of flash operations, and
    // checks after each cut that the store opens and holds a consistent state.
    var mem: [3 * page_size]u8 = undefined;

    var cut: usize = 0;
    while (true) : (cut += 1) {
        var flash = test_flash(&mem);
        var nvs: TestStorage = undefined;
        try nvs.init(&flash, mem.len);
        const h = try nvs.open("ns", .read_write);
        try h.set(u32, "count", 0);
        try h.set_str("name", "old name");
        try h.set_blob("blob", "old blob contents");

        flash.budget = cut;
        const result = workload(h);
        flash.restore_power();
        errdefer std.debug.print("failed with the power cut after {} flash operations\n", .{cut});

        var after: TestStorage = undefined;
        try after.init(&flash, mem.len);
        const h2 = try after.open("ns", .read_write);
        var buf: [64]u8 = undefined;

        const count = try h2.get(u32, "count");
        try testing.expect(count <= 300);
        const name = try h2.get_str("name", &buf);
        try testing.expect(std.mem.eql(u8, name, "old name") or std.mem.eql(u8, name, "new name, longer"));
        const blob = try h2.get_blob("blob", &buf);
        try testing.expect(std.mem.eql(u8, blob, "old blob contents") or std.mem.eql(u8, blob, "new blob"));

        // The store still works after the repair.
        try h2.set(u32, "count", 1000);
        try testing.expectEqual(@as(u32, 1000), try h2.get(u32, "count"));

        if (result) |_| break else |err| try testing.expectEqual(error.PowerLoss, err);
    }
    // The uncut run takes a few thousand operations: make sure the loop covered them.
    try testing.expect(cut > 600);
}

fn workload(h: TestStorage.Handle) !void {
    // Enough counter updates to go through several page reclaims.
    for (1..151) |i| try h.set(u32, "count", @intCast(i));
    try h.set_str("name", "new name, longer");
    try h.set_blob("blob", "new blob");
    for (151..301) |i| try h.set(u32, "count", @intCast(i));
}
