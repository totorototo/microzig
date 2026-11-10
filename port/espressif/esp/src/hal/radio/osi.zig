const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const c = @import("esp-wifi-driver");
const microzig = @import("microzig");
const enter_critical_section = microzig.interrupt.enter_critical_section;
const peripherals = microzig.chip.peripherals;
const compatibility = @import("../compatibility.zig");
const clocks_c6 = @import("clocks_esp32_c6.zig");
const radio_interrupt = microzig.options.hal.radio.interrupt;

const radio = @import("../radio.zig");
const rng = @import("../rng.zig");
const rtos = @import("../rtos.zig");
const get_time_since_boot = @import("../time.zig").get_time_since_boot;
const timer = @import("timer.zig");
const wifi = @import("wifi.zig");

const log = std.log.scoped(.esp_radio_osi);

// TODO: config
const coex_enabled: bool = false;

pub var gpa: std.mem.Allocator = undefined;

pub var wifi_interrupt_handler: ?struct {
    f: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
} = undefined;

extern fn vsnprintf(buffer: [*c]u8, len: usize, fmt: [*c]const u8, va_list: std.builtin.VaList) callconv(.c) void;

fn syslog(fmt: ?[*:0]const u8, va_list: std.builtin.VaList) callconv(.c) void {
    var buf: [512:0]u8 = undefined;
    vsnprintf(&buf, 512, fmt, va_list);
    log.debug("{s}", .{std.mem.span((&buf).ptr)});
}

// ----- exports -----

pub fn strlen(str: ?[*:0]const u8) callconv(.c) usize {
    const s = str orelse return 0;

    return std.mem.len(s);
}

pub fn strnlen(str: ?[*:0]const u8, n: usize) callconv(.c) usize {
    const s = str orelse return 0;
    return if (std.mem.indexOfScalar(u8, s[0..n], 0)) |index| index else n;
}

test "strnlen" {
    try std.testing.expect(strnlen(&.{ 10, 20, 30, 0 }, 4) == 3);
    try std.testing.expect(strnlen(&.{ 10, 20, 30, 0, 10, 20, 30 }, 7) == 3);
}

pub fn strrchr(str: ?[*:0]const u8, chr: u32) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;

    // Should return even the index of the zero byte if requested. This
    // implementation only works with single byte characters.

    if (std.mem.lastIndexOfScalar(u8, s[0 .. std.mem.len(s) + 1], @intCast(chr))) |index| {
        return @ptrFromInt(@intFromPtr(s) + index);
    } else {
        return null;
    }
}

pub fn __assert_func(
    file: ?[*:0]const u8,
    line: u32,
    func: ?[*:0]const u8,
    failed_expr: ?[*:0]const u8,
) callconv(.c) void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {
            log.err("assertion failed: `{s}` in file {s}, line {}, function {s}", .{
                failed_expr orelse "",
                file orelse "",
                line,
                func orelse "",
            });
            @panic("assertion failed");
        },
        .ReleaseSmall => @panic("assertion failed"),
        .ReleaseFast => unreachable,
    }
}

pub fn malloc(len: usize) callconv(.c) ?*anyopaque {
    log.debug("malloc {}", .{len});

    const buf = gpa.rawAlloc(8 + len, .@"8", @returnAddress()) orelse {
        log.warn("failed to allocate memory: {}", .{len});
        return null;
    };

    const alloc_len: *usize = @ptrCast(@alignCast(buf));
    alloc_len.* = len;
    return @ptrFromInt(@intFromPtr(buf) + 8);
}

pub fn calloc(number: usize, size: usize) callconv(.c) ?*anyopaque {
    const total_size: usize = number * size;
    if (malloc(total_size)) |ptr| {
        @memset(@as([*]u8, @ptrCast(ptr))[0..total_size], 0);
        return ptr;
    }
    return null;
}

pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("free {?}", .{ptr});

    // NOTE: The wifi driver calls this function with null sometimes. Just
    // ignore it.
    if (ptr == null) return;

    // `malloc` put the length in an 8-byte header (8 for the alignment, not @sizeOf(usize)).
    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - 8);
    const buf_len: *usize = @ptrCast(@alignCast(buf_ptr));
    gpa.rawFree(buf_ptr[0 .. 8 + buf_len.*], .@"8", @returnAddress());
}

pub fn puts(ptr: ?*anyopaque) callconv(.c) void {
    const s: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    log.debug("{s}", .{s});
}

pub fn gettimeofday(tv: ?*c.timeval, _: ?*anyopaque) callconv(.c) i32 {
    if (tv) |time_val| {
        const usec = get_time_since_boot().to_us();
        time_val.tv_sec = usec / 1_000_000;
        time_val.tv_usec = @intCast(usec % 1_000_000);
    }

    return 0;
}

pub fn sleep(time_sec: c_uint) callconv(.c) c_int {
    rtos.sleep(.from_us(time_sec * 1_000_000));
    return 0;
}

pub fn usleep(time_us: u32) callconv(.c) c_int {
    rtos.sleep(.from_us(time_us));
    return 0;
}

pub fn vTaskDelay(ticks: u32) callconv(.c) void {
    rtos.sleep(.from_ticks(ticks));
}

pub var WIFI_EVENT: c.esp_event_base_t = "WIFI_EVENT";

pub fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) void {
    syslog(fmt, @cVaStart());
}

/// Referenced by the C6 PHY blob for debug output; dropped, like esp-radio does by default.
pub fn putchar(ch: c_int) callconv(.c) c_int {
    return ch;
}

/// XTAL frequency in MHz, referenced by the C6 PHY blob.
pub fn rtc_clk_xtal_freq_get() callconv(.c) c_int {
    return switch (compatibility.chip) {
        .esp32_c3 => 40,
        .esp32_c6 => peripherals.PCR.SYSCLK_CONF.read().CLK_XTAL_FREQ,
    };
}

pub fn esp_fill_random(buf: [*c]u8, len: usize) callconv(.c) void {
    log.debug("esp_fill_random {any} {}", .{ buf, len });

    rng.read(buf[0..len]);
}

/// Some are weaklinks which can be overriten.
pub fn export_symbols() void {
    @export(&strlen, .{ .name = "strlen", .linkage = .weak });
    @export(&strnlen, .{ .name = "strnlen", .linkage = .weak });
    @export(&strrchr, .{ .name = "strrchr", .linkage = .weak });

    @export(&__assert_func, .{ .name = "__assert_func", .linkage = .weak });

    @export(&malloc, .{ .name = "malloc", .linkage = .weak });
    @export(&calloc, .{ .name = "calloc", .linkage = .weak });
    @export(&free, .{ .name = "free", .linkage = .weak });
    @export(&puts, .{ .name = "puts", .linkage = .weak });

    @export(&gettimeofday, .{ .name = "gettimeofday", .linkage = .weak });
    @export(&sleep, .{ .name = "sleep", .linkage = .weak });
    @export(&usleep, .{ .name = "usleep", .linkage = .weak });
    @export(&vTaskDelay, .{ .name = "vTaskDelay", .linkage = .weak });

    @export(&WIFI_EVENT, .{ .name = "WIFI_EVENT" });
    inline for (&.{
        "rtc_printf",
        "phy_printf",
        "coexist_printf",
        "net80211_printf",
        "pp_printf",
    }) |name| {
        @export(&printf, .{ .name = name });
    }
    @export(&esp_fill_random, .{ .name = "esp_fill_random" });
    @export(&putchar, .{ .name = "putchar", .linkage = .weak });
    @export(&rtc_clk_xtal_freq_get, .{ .name = "rtc_clk_xtal_freq_get", .linkage = .weak });
    @export(&esp_event_post, .{ .name = "esp_event_post" });
}

// ----- end of exports -----

pub fn env_is_chip() callconv(.c) bool {
    return true;
}

pub fn set_intr(cpu_no: i32, intr_source: u32, intr_num: u32, intr_prio: i32) callconv(.c) void {
    log.debug("set_intr {} {} {} {}", .{ cpu_no, intr_source, intr_num, intr_prio });

    // esp32c3
    // these are already set up
    // possible calls:
    // INFO - set_intr 0 2 1 1 (WIFI_PWR)
    // INFO - set_intr 0 0 1 1 (WIFI_MAC)
    //
    // we don't need to do anything as these interrupts are already setup in
    // `radio.init`
}

pub fn clear_intr(intr_source: u32, intr_num: u32) callconv(.c) void {
    log.debug("clear_intr {} {}", .{ intr_source, intr_num });
}

pub fn set_isr(
    n: i32,
    f: ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) void {
    log.debug("set_isr {} {?} {?}", .{ n, f, arg });

    // esp32c3 specific

    switch (n) {
        0, 1 => {
            wifi_interrupt_handler = if (f) |handler| .{
                .f = @ptrCast(@alignCast(handler)),
                .arg = arg,
            } else null;
        },
        else => @panic("invalid interrupt number"),
    }
}

pub fn ints_on(mask: u32) callconv(.c) void {
    log.debug("ints_on {}", .{mask});

    if (mask == 2) {
        microzig.cpu.interrupt.enable(radio_interrupt);
    } else {
        @panic("ints_on: not implemented");
    }
}

pub fn ints_off(mask: u32) callconv(.c) void {
    log.debug("ints_off {}", .{mask});

    if (mask == 2) {
        microzig.cpu.interrupt.disable(radio_interrupt);
    } else {
        @panic("ints_off: not implemented");
    }
}

pub fn is_from_isr() callconv(.c) bool {
    return true;
}

pub fn spin_lock_create() callconv(.c) ?*anyopaque {
    log.debug("spin_lock_create", .{});
    return semphr_create(1, 1);
}

pub fn spin_lock_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("spin_lock_delete {?}", .{ptr});
    return semphr_delete(ptr);
}

pub fn wifi_int_disable(mux_ptr: ?*anyopaque) callconv(.c) u32 {
    log.debug("wifi_int_disable {?}", .{mux_ptr});

    const ints_enabled = microzig.cpu.interrupt.globally_enabled();
    if (ints_enabled) {
        microzig.cpu.interrupt.disable_interrupts();
    }
    return @intFromBool(ints_enabled);
}

pub fn wifi_int_restore(mux_ptr: ?*anyopaque, state: u32) callconv(.c) void {
    log.debug("wifi_int_restore {?} {}", .{ mux_ptr, state });

    // check if interrupts were enabled before.
    if (state != 0) {
        microzig.cpu.interrupt.enable_interrupts();
    }
}

pub fn task_yield_from_isr() callconv(.c) void {
    log.debug("task_yield_from_isr", .{});

    rtos.yield_from_isr();
}

pub fn semphr_create(max_value: u32, init_value: u32) callconv(.c) ?*anyopaque {
    log.debug("semphr_create {} {}", .{ max_value, init_value });

    const sem = gpa.create(rtos.Semaphore) catch {
        log.warn("failed to allocate semaphore", .{});
        return null;
    };
    sem.* = .init(init_value, max_value);

    log.debug(">>>> semaphore create: {*}", .{sem});

    return sem;
}

pub fn semphr_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("semphr_delete {?}", .{ptr});

    gpa.destroy(@as(*rtos.Semaphore, @ptrCast(@alignCast(ptr))));
}

pub fn semphr_take(ptr: ?*anyopaque, tick: u32) callconv(.c) i32 {
    log.debug("semphr_take {?} {}", .{ ptr, tick });

    const sem: *rtos.Semaphore = @ptrCast(@alignCast(ptr));
    const timeout: rtos.Timeout = switch (tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    sem.take_with_timeout(timeout) catch {
        log.debug(">>>> return from semaphore take with timeout: {*}", .{sem});
        return 1;
    };

    return 0;
}

pub fn semphr_give(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("semphr_give {?}", .{ptr});

    const sem: *rtos.Semaphore = @ptrCast(@alignCast(ptr));
    sem.give();
    return 1;
}

pub fn wifi_thread_semphr_get() callconv(.c) ?*anyopaque {
    return &rtos.get_current_task().semaphore;
}

const RecursiveMutex = struct {
    recursive: bool,
    value: u32 = 0,
    owning_task: ?*rtos.Task = null,
    prev_priority: ?rtos.Priority = null,
    wait_queue: rtos.PriorityWaitQueue = .{},

    pub fn lock(mutex: *RecursiveMutex) void {
        const cs = enter_critical_section();
        defer cs.leave();

        const current_task = rtos.get_current_task();

        if (mutex.owning_task == current_task) {
            assert(mutex.recursive);
            mutex.value += 1;
            return;
        }

        while (mutex.owning_task) |owning_task| {
            // Owning task inherits the priority of the current task if it the
            // current task has a bigger priority.
            if (@backingInt(current_task.priority) > @backingInt(owning_task.priority)) {
                mutex.prev_priority = owning_task.priority;
                owning_task.priority = current_task.priority;
                var _hptw = false;
                rtos.make_ready(owning_task, &_hptw);
            }

            mutex.wait_queue.wait(null);
        }

        assert(mutex.value == 0);
        mutex.value += 1;
        mutex.owning_task = current_task;
    }

    pub fn unlock(mutex: *RecursiveMutex) bool {
        const cs = enter_critical_section();
        defer cs.leave();

        assert(mutex.owning_task == rtos.get_current_task());

        assert(mutex.value > 0);
        mutex.value -= 1;
        if (mutex.value <= 0) {
            const owning_task = mutex.owning_task.?;

            // Restore the priority of the task
            if (mutex.prev_priority) |prev_priority| {
                owning_task.priority = prev_priority;
                mutex.prev_priority = null;
            }

            mutex.owning_task = null;

            var hptw = false;
            mutex.wait_queue.wake_one(&hptw);
            if (hptw) rtos.yield_from_cs(.reschedule);

            return true;
        } else {
            return false;
        }
    }
};

pub fn mutex_create() callconv(.c) ?*anyopaque {
    log.debug("mutex_create", .{});

    const mutex = gpa.create(RecursiveMutex) catch {
        log.warn("failed to allocate recursive mutex", .{});
        return null;
    };
    mutex.* = .{ .recursive = false };

    log.debug(">>>> mutex create: {*}", .{mutex});

    return mutex;
}

pub fn recursive_mutex_create() callconv(.c) ?*anyopaque {
    log.debug("recursive_mutex_create", .{});

    const mutex = gpa.create(RecursiveMutex) catch {
        log.warn("failed to allocate recursive mutex", .{});
        return null;
    };
    mutex.* = .{ .recursive = true };

    log.debug(">>>> mutex create: {*}", .{mutex});

    return mutex;
}

pub fn mutex_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("mutex_delete {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    gpa.destroy(mutex);
}

pub fn mutex_lock(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("mutex lock {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    mutex.lock();

    return 1;
}

pub fn mutex_unlock(ptr: ?*anyopaque) callconv(.c) i32 {
    log.debug("mutex unlock {?}", .{ptr});

    const mutex: *RecursiveMutex = @ptrCast(@alignCast(ptr));
    return @intFromBool(mutex.unlock());
}

pub const QueueWrapper = struct {
    item_len: u32,
    inner: rtos.TypeErasedQueue,
};

pub fn queue_create(capacity: u32, item_len: u32) callconv(.c) ?*anyopaque {
    log.debug("queue_create {} {}", .{ capacity, item_len });

    const new_cap, const new_item_len = if (capacity != 3 and item_len != 4)
        .{ capacity, item_len }
    else blk: {
        log.warn("fixing queue item len", .{});
        break :blk .{ 3, 8 };
    };

    // The buffer must hold whole items: the queue works on bytes, and a size that isn't a
    // multiple of the item length would let it accept part of an item.
    const buf: []u8 = gpa.alloc(u8, new_cap * new_item_len) catch {
        log.warn("failed to allocate queue buffer", .{});
        return null;
    };

    const queue = gpa.create(QueueWrapper) catch {
        log.warn("failed to allocate queue", .{});
        gpa.free(buf);
        return null;
    };

    queue.* = .{
        .item_len = new_item_len,
        .inner = .init(buf),
    };

    log.debug(">>>> queue create: {*}", .{queue});

    return queue;
}

pub fn queue_delete(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("queue_delete {?}", .{ptr});

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    gpa.free(queue.inner.buffer);
    gpa.destroy(queue);
}

pub fn queue_send(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_send {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    const size = queue.inner.put(item[0..queue.item_len], 1, timeout);
    if (size == 0) return -1;
    return 1;
}

pub fn queue_send_from_isr(ptr: ?*anyopaque, item_ptr: ?*anyopaque, _hptw: ?*anyopaque) callconv(.c) i32 {
    log.debug("queue_send_from_isr {?} {?} {?}", .{ ptr, item_ptr, _hptw });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    var hptw = false;
    const n = @divExact(queue.inner.put_from_isr(item[0..queue.item_len], &hptw), queue.item_len);

    @as(*u32, @ptrCast(@alignCast(_hptw))).* |= @intFromBool(hptw);

    return @intCast(n);
}

pub fn queue_send_to_back(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    // The queue is a FIFO, a plain send already goes to the back.
    return queue_send(ptr, item_ptr, block_time_tick);
}

pub fn queue_send_to_front(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_send_to_front {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]const u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    return if (queue.inner.put_front(item[0..queue.item_len], timeout)) 1 else -1;
}

pub fn queue_recv(ptr: ?*anyopaque, item_ptr: ?*anyopaque, block_time_tick: u32) callconv(.c) i32 {
    log.debug("queue_recv {?} {?} {}", .{ ptr, item_ptr, block_time_tick });

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    const item: [*]u8 = @ptrCast(@alignCast(item_ptr));

    const timeout: rtos.Timeout = switch (block_time_tick) {
        0 => .non_blocking,
        c.OSI_FUNCS_TIME_BLOCKING => .never,
        else => |ticks| .{ .after = .from_ticks(ticks) },
    };
    const size = queue.inner.get(item[0..queue.item_len], 1, timeout);
    if (size == 0) return -1;
    return 1;
}

pub fn queue_msg_waiting(ptr: ?*anyopaque) callconv(.c) u32 {
    log.debug("queue_msg_waiting {?}", .{ptr});

    const queue: *QueueWrapper = @ptrCast(@alignCast(ptr));
    return @divExact(queue.inner.len, queue.item_len);
}

pub fn event_group_create() callconv(.c) void {
    @panic("event_group_create: not implemented");
}

pub fn event_group_delete() callconv(.c) void {
    @panic("event_group_delete: not implemented");
}

pub fn event_group_set_bits() callconv(.c) void {
    @panic("event_group_set_bits: not implemented");
}

pub fn event_group_clear_bits() callconv(.c) void {
    @panic("event_group_clear_bits: not implemented");
}

pub fn event_group_wait_bits() callconv(.c) void {
    @panic("event_group_wait_bits: not implemented");
}

fn task_wrapper(
    task_entry: *const fn (param: ?*anyopaque) callconv(.c) noreturn,
    param: ?*anyopaque,
) noreturn {
    task_entry(param);
}

fn task_create_common(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
    core_id: u32,
) i32 {
    _ = core_id; // autofix

    const task_entry: *const fn (param: ?*anyopaque) callconv(.c) noreturn = @ptrCast(@alignCast(task_func));

    // increase stack size if we are in debug mode
    const stack_size: usize = stack_depth + if (builtin.mode == .debug) 6000 else 0;
    const task: *rtos.Task = rtos.spawn(gpa, task_wrapper, .{ task_entry, param }, .{
        .name = std.mem.span(name),
        .priority = @fromBackingInt(@truncate(prio)),
        .stack_size = stack_size,
    }) catch {
        log.warn("failed to create task", .{});
        return 0;
    };

    @as(*usize, @ptrCast(@alignCast(task_handle))).* = @intFromPtr(task);

    return 1;
}

pub fn task_create_pinned_to_core(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
    core_id: u32,
) callconv(.c) i32 {
    log.debug("task_create_pinned_to_core {?} {s} {} {?} {} {?} {}", .{
        task_func,
        name,
        stack_depth,
        param,
        prio,
        task_handle,
        core_id,
    });

    return task_create_common(task_func, name, stack_depth, param, prio, task_handle, core_id);
}

pub fn task_create(
    task_func: ?*anyopaque,
    name: [*c]const u8,
    stack_depth: u32,
    param: ?*anyopaque,
    prio: u32,
    task_handle: ?*anyopaque,
) callconv(.c) i32 {
    log.debug("task_create {?} {s} {} {?} {} {?}", .{
        task_func,
        name,
        stack_depth,
        param,
        prio,
        task_handle,
    });

    return task_create_common(task_func, name, stack_depth, param, prio, task_handle, 0);
}

pub fn task_delete(handle: ?*anyopaque) callconv(.c) void {
    log.debug("task_delete {?}", .{handle});
    if (handle != null) {
        @panic("task_delete(non-null): not implemented");
    }
    rtos.yield(.exit);
}

pub fn task_delay(tick: u32) callconv(.c) void {
    log.debug("task_delay {}", .{tick});

    rtos.sleep(.from_ticks(tick));
}

pub fn task_ms_to_tick(ms: u32) callconv(.c) i32 {
    return @intCast(rtos.Duration.from_ms(ms).to_ticks());
}

pub fn task_get_current_task() callconv(.c) ?*anyopaque {
    return rtos.get_current_task();
}

pub fn task_get_max_priority() callconv(.c) i32 {
    return @backingInt(rtos.Priority.highest);
}

pub fn esp_event_post(
    base: [*c]const u8,
    id: i32,
    data: ?*anyopaque,
    data_size: usize,
    ticks_to_wait: u32,
) callconv(.c) i32 {
    log.debug("esp_event_post {*} {} {?} {} {}", .{ base, id, data, data_size, ticks_to_wait });
    wifi.on_event_post(id, data, data_size);
    return 0;
}

pub fn get_free_heap_size() callconv(.c) void {
    @panic("get_free_heap_size: not implemented");
}

pub fn rand() callconv(.c) u32 {
    return rng.random_u32();
}

pub fn dport_access_stall_other_cpu_start_wrap() callconv(.c) void {
    log.debug("dport_access_stall_other_cpu_start_wrap", .{});
}

pub fn dport_access_stall_other_cpu_end_wrap() callconv(.c) void {
    log.debug("dport_access_stall_other_cpu_end_wrap", .{});
}

pub fn wifi_apb80m_request() callconv(.c) void {
    log.debug("wifi_apb80m_request", .{});
}

pub fn wifi_apb80m_release() callconv(.c) void {
    log.debug("wifi_apb80m_release", .{});
}

const CONFIG_ESP32_PHY_MAX_TX_POWER: u8 = 20;

fn limit(val: u8, low: u8, high: u8) u8 {
    return if (val < low) low else if (val > high) high else val;
}

const phy_init_data_default: c.esp_phy_init_data_t = .{
    .params = .{
        0x00,
        0x00,
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x50),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4c),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x48),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x44),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x4a),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x46),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x46),
        limit(CONFIG_ESP32_PHY_MAX_TX_POWER * 4, 0, 0x42),
        0x00,
        0x00,
        0x00,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x74,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    },
};

fn clocks_phy_set_enabled(enable: bool) void {
    switch (compatibility.chip) {
        .esp32_c3 => clocks_phy_set_enabled_c3(enable),
        .esp32_c6 => clocks_c6.phy_clocks_set_enabled(enable),
    }
}

fn clocks_phy_set_enabled_c3(enable: bool) void {
    const APB_CTRL = peripherals.APB_CTRL;
    const system_wifi_clk_wifi_bt_common_m: u32 = 0x78078F;

    var wifi_clk_en = APB_CTRL.WIFI_CLK_EN.read().WIFI_CLK_EN;
    if (enable) {
        wifi_clk_en |= system_wifi_clk_wifi_bt_common_m;
    } else {
        wifi_clk_en &= ~system_wifi_clk_wifi_bt_common_m;
    }
    APB_CTRL.WIFI_CLK_EN.write(.{ .WIFI_CLK_EN = wifi_clk_en });
}

// PHY bring-up, after esp-phy and ESP-IDF's esp_phy_init.c. The first enable after power-up
// calibrates the RF; later ones only wake the PHY up. With an NVS store (`wifi.InitConfig.nvs`)
// the calibration data is kept in the "phy" namespace with ESP-IDF's keys, so later boots do a
// partial calibration from it instead of a full one.

const phy = struct {
    extern fn phy_init_param_set(param: u8) void;
    extern fn phy_wifi_enable_set(enable: u8) void;
    extern fn phy_bbpll_en_usb(en: bool) void;
    extern fn phy_wakeup_init() void;
    extern fn phy_close_rf() void;
    extern fn phy_xpd_tsens() void;
    extern fn phy_get_rf_cal_version() u32;
    extern fn phy_dig_reg_backup(backup_en: bool, mem_addr: *[21]u32) void;
};

/// How the RF was calibrated at the first PHY enable since power-up.
pub const PhyCalibration = struct {
    /// Partial: from calibration data saved by an earlier boot. Full: from scratch.
    mode: enum { partial, full },
    /// The PHY rejected the saved data (bad checksum or older format) and calibrated fully.
    data_check_failed: bool,
    /// The resulting data was written to NVS.
    saved: bool,
};

pub var phy_calibration: ?PhyCalibration = null;

var phy_ref_count: u32 = 0;
var phy_calibrated = false;
var phy_cal_data: c.esp_phy_calibration_data_t = std.mem.zeroes(c.esp_phy_calibration_data_t);
// The C3 loses these PHY registers while the PHY is off (`phy_backed_up_digital_register_count`).
var phy_dig_regs: [21]u32 = undefined;

const phy_namespace = "phy";

fn phy_load_calibration() bool {
    const store = nvs_store orelse return false;
    nvs_mutex.lock();
    defer nvs_mutex.unlock();

    const h = store.open(phy_namespace, .read_only) catch return false;
    const version = h.get(u32, "cal_version") catch return false;
    if (version != phy.phy_get_rf_cal_version()) return false;
    var mac: [6]u8 = undefined;
    const stored_mac = h.get_blob("cal_mac", &mac) catch return false;
    if (!std.mem.eql(u8, stored_mac, &radio.read_mac(.sta))) return false;
    const data = std.mem.asBytes(&phy_cal_data);
    const stored = h.get_blob("cal_data", data) catch return false;
    return stored.len == data.len;
}

fn phy_save_calibration() bool {
    const store = nvs_store orelse return false;
    nvs_mutex.lock();
    defer nvs_mutex.unlock();

    const h = store.open(phy_namespace, .read_write) catch |err| return phy_save_failed(err);
    h.set(u32, "cal_version", phy.phy_get_rf_cal_version()) catch |err| return phy_save_failed(err);
    h.set_blob("cal_mac", &radio.read_mac(.sta)) catch |err| return phy_save_failed(err);
    h.set_blob("cal_data", std.mem.asBytes(&phy_cal_data)) catch |err| return phy_save_failed(err);
    return true;
}

fn phy_save_failed(err: anyerror) bool {
    log.warn("phy: saving the calibration data failed: {t}", .{err});
    return false;
}

pub fn phy_disable() callconv(.c) void {
    log.debug("phy_disable", .{});

    const cs = enter_critical_section();
    defer cs.leave();

    // On combo modules (C3, C6) Wi-Fi RX is switched with the PHY: off here, on in
    // `phy_enable`, as in ESP-IDF's esp_phy_{enable,disable}_wrapper.
    phy.phy_wifi_enable_set(0);

    assert(phy_ref_count > 0);
    phy_ref_count -= 1;
    if (phy_ref_count > 0) return;

    if (compatibility.chip == .esp32_c3) phy.phy_dig_reg_backup(true, &phy_dig_regs);
    phy.phy_close_rf();
    phy.phy_xpd_tsens();
    clocks_phy_set_enabled(false);
}

pub fn phy_enable() callconv(.c) void {
    log.debug("phy_enable", .{});

    // Flash access can block, so it stays outside the critical section.
    const first = !phy_calibrated;
    const loaded = first and phy_load_calibration();
    var result: c_int = 0;

    {
        const cs = enter_critical_section();
        defer cs.leave();

        if (phy_ref_count == 0) {
            clocks_phy_set_enabled(true);
            if (phy_calibrated) {
                phy.phy_wakeup_init();
                if (compatibility.chip == .esp32_c3) phy.phy_dig_reg_backup(false, &phy_dig_regs);
            } else {
                log.debug("phy_version {s}", .{c.get_phy_version_str()});
                phy.phy_init_param_set(1);
                // Keeps the USB-Serial-JTAG alive while the radio runs (esp-phy's default).
                phy.phy_bbpll_en_usb(true);
                result = c.register_chipv7_phy(
                    &phy_init_data_default,
                    &phy_cal_data,
                    if (loaded) c.PHY_RF_CAL_PARTIAL else c.PHY_RF_CAL_FULL,
                );
                phy_calibrated = true;
            }
        }
        phy_ref_count += 1;
        phy.phy_wifi_enable_set(1);
    }

    if (first) {
        // Without saved data the buffer is zeroed, which the PHY also reports as a failed check.
        const check_failed = loaded and result == c.ESP_CAL_DATA_CHECK_FAIL;
        if (check_failed) log.warn("phy: saved calibration data rejected, calibrated fully", .{});
        // Like ESP-IDF: save after a full calibration, or when the saved data was rejected.
        const saved = (!loaded or check_failed) and phy_save_calibration();
        phy_calibration = .{
            .mode = if (loaded) .partial else .full,
            .data_check_failed = check_failed,
            .saved = saved,
        };
    }
}

pub fn phy_update_country_info(country: [*c]const u8) callconv(.c) c_int {
    log.debug("phy_update_country_info {s}", .{country});
    return -1;
}

pub fn read_mac(mac: [*c]u8, typ: c_uint) callconv(.c) c_int {
    log.debug("read_mac {*} {}", .{ mac, typ });

    const mac_tmp: [6]u8 = radio.read_mac(switch (typ) {
        0 => .sta,
        1 => .ap,
        2 => .bt,
        else => @panic("unknown mac typ"),
    });
    @memcpy(mac[0..6], &mac_tmp);

    return 0;
}

pub fn timer_arm(ets_timer_ptr: ?*anyopaque, ms: u32, repeat: bool) callconv(.c) void {
    timer_arm_us(ets_timer_ptr, ms * 1_000, repeat);
}

pub fn timer_disarm(ets_timer_ptr: ?*anyopaque) callconv(.c) void {
    log.debug("timer_disarm {?}", .{ets_timer_ptr});

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.disarm(ets_timer);
}

pub fn timer_done(ets_timer_ptr: ?*anyopaque) callconv(.c) void {
    log.debug("timer_done {?}", .{ets_timer_ptr});

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.done(gpa, ets_timer);
}

pub fn timer_setfn(ets_timer_ptr: ?*anyopaque, callback_ptr: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    log.debug("timer_setfn {?} {?} {?}", .{ ets_timer_ptr, callback_ptr, arg });

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    const callback: timer.CallbackFn = @ptrCast(@alignCast(callback_ptr));
    timer.setfn(gpa, ets_timer, callback, arg) catch {
        log.warn("failed to allocate timer", .{});
    };
}

pub fn timer_arm_us(ets_timer_ptr: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    log.debug("timer_arm_us {?} {} {}", .{ ets_timer_ptr, us, repeat });

    const ets_timer: *c.ets_timer = @ptrCast(@alignCast(ets_timer_ptr));
    timer.arm(ets_timer, .from_us(us), repeat);
}

pub fn wifi_reset_mac() callconv(.c) void {
    log.debug("wifi_reset_mac", .{});

    switch (compatibility.chip) {
        .esp32_c3 => {
            const APB_CTRL = peripherals.APB_CTRL;
            APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST | (1 << 2) });
            APB_CTRL.WIFI_RST_EN.write(.{ .WIFI_RST = APB_CTRL.WIFI_RST_EN.read().WIFI_RST & ~@as(u32, 1 << 2) });
        },
        // Same as ESP-IDF / esp-radio: no MAC reset on the C6.
        .esp32_c6 => {},
    }
}

pub fn wifi_clock_enable() callconv(.c) void {
    log.debug("wifi_clock_enable", .{});

    // no op on esp32c3
    if (compatibility.chip == .esp32_c6) clocks_c6.wifi_clocks_set_enabled(true);
}

pub fn wifi_clock_disable() callconv(.c) void {
    log.debug("wifi_clock_disable", .{});

    // no op on esp32c3
    if (compatibility.chip == .esp32_c6) clocks_c6.wifi_clocks_set_enabled(false);
}

pub fn regdma_link_set_write_wait_content(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {
    log.err("regdma_link_set_write_wait_content: modem sleep retention is not supported", .{});
}

pub fn sleep_retention_find_link_by_id(_: c_int) callconv(.c) ?*anyopaque {
    log.err("sleep_retention_find_link_by_id: modem sleep retention is not supported", .{});
    return null;
}

pub fn wifi_rtc_enable_iso() callconv(.c) void {
    @panic("wifi_rtc_enable_iso: not implemented");
}

pub fn wifi_rtc_disable_iso() callconv(.c) void {
    @panic("wifi_rtc_disable_iso: not implemented");
}

pub fn esp_timer_get_time() callconv(.c) i64 {
    log.debug("esp_timer_get_time", .{});

    return @intCast(get_time_since_boot().to_us());
}

// NVS callbacks, used when `wifi.InitConfig.nvs` is set (`nvs_enable = 1`). The blob stores
// its configuration in the "nvs.net80211" namespace. Return values are ESP-IDF's codes.

const Nvs = @import("../flash.zig").Nvs;

/// The store given to `wifi.init`, or null when Wi-Fi doesn't persist its configuration.
pub var nvs_store: ?*Nvs = null;
/// Serialises store access between the Wi-Fi task and the application (`wifi.lock_nvs`).
pub var nvs_mutex: rtos.Mutex = .{};

const esp_ok = 0;
const esp_fail = -1;
const esp_err_nvs_not_initialized = 0x1101;
const esp_err_nvs_not_found = 0x1102;
const esp_err_nvs_type_mismatch = 0x1103;
const esp_err_nvs_read_only = 0x1104;
const esp_err_nvs_not_enough_space = 0x1105;
const esp_err_nvs_invalid_name = 0x1106;
const esp_err_nvs_invalid_handle = 0x1107;
const esp_err_nvs_key_too_long = 0x1109;
const esp_err_nvs_invalid_length = 0x110c;
const esp_err_nvs_value_too_long = 0x110e;

// A handle packs the namespace index and the open mode; the tag catches stray values.
const handle_tag: u32 = 0x4e56_0000;

fn nvs_handle(handle: u32) ?Nvs.Handle {
    const store = nvs_store orelse return null;
    if (handle & 0xffff_0000 != handle_tag or handle & 0xff == 0) return null;
    return .{
        .storage = store,
        .ns = @truncate(handle),
        .mode = if (handle & 0x100 != 0) .read_write else .read_only,
    };
}

fn nvs_err(err: anyerror) c_int {
    return switch (err) {
        error.NotFound => esp_err_nvs_not_found,
        error.TypeMismatch => esp_err_nvs_type_mismatch,
        error.ReadOnly => esp_err_nvs_read_only,
        error.NotEnoughSpace, error.TooManyNamespaces => esp_err_nvs_not_enough_space,
        error.InvalidName => esp_err_nvs_invalid_name,
        error.BufferTooSmall => esp_err_nvs_invalid_length,
        error.ValueTooLong => esp_err_nvs_value_too_long,
        else => blk: {
            log.err("nvs: {t}", .{err});
            break :blk esp_fail;
        },
    };
}

fn nvs_key(key: [*c]const u8) error{ KeyTooLong, InvalidName }![]const u8 {
    if (key == null) return error.InvalidName;
    const k = std.mem.span(key);
    if (k.len > @import("../nvs.zig").max_key_len) return error.KeyTooLong;
    return k;
}

fn nvs_call(handle: u32, key: [*c]const u8, comptime f: anytype, args: anytype) c_int {
    const h = nvs_handle(handle) orelse return esp_err_nvs_invalid_handle;
    const k = nvs_key(key) catch |err| return switch (err) {
        error.KeyTooLong => esp_err_nvs_key_too_long,
        error.InvalidName => esp_err_nvs_invalid_name,
    };
    nvs_mutex.lock();
    defer nvs_mutex.unlock();
    @call(.auto, f, .{ h, k } ++ args) catch |err| return nvs_err(err);
    return esp_ok;
}

fn nvs_set_int(comptime T: type) fn (u32, [*c]const u8, T) callconv(.c) c_int {
    return struct {
        fn set(handle: u32, key: [*c]const u8, value: T) callconv(.c) c_int {
            log.debug("nvs_set_{s} {s}", .{ @typeName(T), key });
            return nvs_call(handle, key, store_int, .{value});
        }
        fn store_int(h: Nvs.Handle, k: []const u8, value: T) !void {
            try h.set(T, k, value);
        }
    }.set;
}

fn nvs_get_int(comptime T: type) fn (u32, [*c]const u8, [*c]T) callconv(.c) c_int {
    return struct {
        fn get(handle: u32, key: [*c]const u8, out: [*c]T) callconv(.c) c_int {
            log.debug("nvs_get_{s} {s}", .{ @typeName(T), key });
            if (out == null) return esp_fail;
            return nvs_call(handle, key, load_int, .{out});
        }
        fn load_int(h: Nvs.Handle, k: []const u8, out: [*c]T) !void {
            out.* = try h.get(T, k);
        }
    }.get;
}

pub const nvs_set_i8 = nvs_set_int(i8);
pub const nvs_get_i8 = nvs_get_int(i8);
pub const nvs_set_u8 = nvs_set_int(u8);
pub const nvs_get_u8 = nvs_get_int(u8);
pub const nvs_set_u16 = nvs_set_int(u16);
pub const nvs_get_u16 = nvs_get_int(u16);

pub fn nvs_open(name: [*c]const u8, open_mode: c_uint, out_handle: [*c]u32) callconv(.c) c_int {
    log.debug("nvs_open {s} {}", .{ name, open_mode });
    const store = nvs_store orelse return esp_err_nvs_not_initialized;
    if (name == null or out_handle == null) return esp_err_nvs_invalid_name;

    // ESP-IDF: NVS_READONLY = 0, NVS_READWRITE = 1.
    const read_write = open_mode != 0;
    nvs_mutex.lock();
    defer nvs_mutex.unlock();
    const h = store.open(std.mem.span(name), if (read_write) .read_write else .read_only) catch |err|
        return nvs_err(err);
    out_handle.* = handle_tag | @as(u32, @intFromBool(read_write)) << 8 | h.ns;
    return esp_ok;
}

pub fn nvs_close(handle: u32) callconv(.c) void {
    log.debug("nvs_close {x}", .{handle});
}

pub fn nvs_commit(handle: u32) callconv(.c) c_int {
    log.debug("nvs_commit {x}", .{handle});
    // Every write already reaches the flash.
    return if (nvs_handle(handle) != null) esp_ok else esp_err_nvs_invalid_handle;
}

pub fn nvs_set_blob(handle: u32, key: [*c]const u8, value: ?*const anyopaque, length: usize) callconv(.c) c_int {
    log.debug("nvs_set_blob {s} {}", .{ key, length });
    if (value == null and length != 0) return esp_fail;
    const data: []const u8 = if (length == 0) &.{} else @as([*]const u8, @ptrCast(value.?))[0..length];
    return nvs_call(handle, key, struct {
        fn f(h: Nvs.Handle, k: []const u8, d: []const u8) !void {
            try h.set_blob(k, d);
        }
    }.f, .{data});
}

/// With a null `out_value`, only reports the size in `length`, like ESP-IDF.
pub fn nvs_get_blob(handle: u32, key: [*c]const u8, out_value: ?*anyopaque, length: [*c]usize) callconv(.c) c_int {
    log.debug("nvs_get_blob {s}", .{key});
    if (length == null) return esp_fail;
    return nvs_call(handle, key, struct {
        fn f(h: Nvs.Handle, k: []const u8, out: ?*anyopaque, len: [*c]usize) !void {
            const size = try h.blob_len(k);
            const dest = out orelse {
                len.* = size;
                return;
            };
            if (len.* < size) {
                len.* = size;
                return error.BufferTooSmall;
            }
            len.* = (try h.get_blob(k, @as([*]u8, @ptrCast(dest))[0..size])).len;
        }
    }.f, .{ out_value, length });
}

pub fn nvs_erase_key(handle: u32, key: [*c]const u8) callconv(.c) c_int {
    log.debug("nvs_erase_key {s}", .{key});
    return nvs_call(handle, key, struct {
        fn f(h: Nvs.Handle, k: []const u8) !void {
            try h.erase_key(k);
        }
    }.f, .{});
}

pub fn get_random(buf: [*c]u8, len: usize) callconv(.c) c_int {
    rng.read(buf[0..len]);
    return 0;
}

/// `struct os_time` of the blobs' wpa_supplicant: seconds and microseconds, as longs.
const OsTime = extern struct {
    sec: c_long,
    usec: c_long,
};

/// Time since boot. There is no wall clock; the supplicant only uses it for intervals.
pub fn get_time(t: ?*anyopaque) callconv(.c) c_int {
    const os_time: *OsTime = @ptrCast(@alignCast(t orelse return -1));
    const usec = get_time_since_boot().to_us();
    os_time.* = .{
        .sec = @intCast(usec / 1_000_000),
        .usec = @intCast(usec % 1_000_000),
    };
    return 0;
}

pub fn random() callconv(.c) c_ulong {
    return rng.random_u32();
}

pub fn slowclk_cal_get() callconv(.c) u32 {
    return switch (compatibility.chip) {
        .esp32_c3 => 28639,
        .esp32_c6 => clocks_c6.slowclk_cal(),
    };
}

pub fn log_write(_: c_uint, _: [*c]const u8, fmt: [*c]const u8, ...) callconv(.c) void {
    syslog(fmt, @cVaStart());
}

pub fn log_writev(_: c_uint, _: [*c]const u8, fmt: [*c]const u8, va_list: c.va_list) callconv(.c) void {
    syslog(fmt, @ptrCast(va_list));
}

pub fn log_timestamp() callconv(.c) u32 {
    return @truncate(get_time_since_boot().to_us() * 1_000);
}

pub const malloc_internal = malloc;

/// C `realloc` on top of `malloc` and `free`: the allocation's length is stored in front of it.
pub fn realloc_internal(ptr: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
    log.debug("realloc {?} {}", .{ ptr, len });

    const old = ptr orelse return malloc(len);
    if (len == 0) {
        free(old);
        return null;
    }

    const old_len: *const usize = @ptrFromInt(@intFromPtr(old) - 8);
    const new = malloc(len) orelse return null; // the old block stays valid, as in C
    const copy_len = @min(old_len.*, len);
    @memcpy(@as([*]u8, @ptrCast(new))[0..copy_len], @as([*]const u8, @ptrCast(old))[0..copy_len]);
    free(old);
    return new;
}

pub const calloc_internal = calloc;

pub fn zalloc_internal(len: usize) callconv(.c) ?*anyopaque {
    if (malloc(len)) |ptr| {
        @memset(@as([*]u8, @ptrCast(ptr))[0..len], 0);
        return ptr;
    }

    return null;
}

pub const wifi_malloc = malloc;

pub const wifi_realloc = realloc_internal;

pub const wifi_calloc = calloc;
pub const wifi_zalloc = zalloc_internal;

var wifi_queue_handle: ?*QueueWrapper = null;
var wifi_queue: QueueWrapper = undefined;

pub fn wifi_create_queue(capacity: c_int, item_len: c_int) callconv(.c) ?*anyopaque {
    log.debug("wifi_create_queue {} {}", .{ capacity, item_len });

    std.debug.assert(wifi_queue_handle == null);

    const buf: []u8 = gpa.alloc(u8, @intCast(capacity * item_len)) catch {
        log.warn("failed to allocate queue buffer", .{});
        return null;
    };

    wifi_queue = .{
        .inner = .init(buf),
        .item_len = @intCast(item_len),
    };
    wifi_queue_handle = &wifi_queue;

    log.debug(">>>> wifi queue create: {*}", .{&wifi_queue_handle});

    return @ptrCast(&wifi_queue_handle);
}

pub fn wifi_delete_queue(ptr: ?*anyopaque) callconv(.c) void {
    log.debug("wifi_delete_queue {?}", .{ptr});

    std.debug.assert(ptr == @as(?*anyopaque, @ptrCast(&wifi_queue_handle)));

    const queue: *?*QueueWrapper = @ptrCast(@alignCast(ptr));
    gpa.free(queue.*.?.inner.buffer);

    wifi_queue_handle = null;
    wifi_queue = undefined;
}

pub fn coex_init() callconv(.c) c_int {
    log.debug("coex_init", .{});

    return if (coex_enabled) c.coex_init() else 0;
}

pub fn coex_deinit() callconv(.c) void {
    log.debug("coex_deinit", .{});

    if (coex_enabled) c.coex_deinit();
}

pub fn coex_enable() callconv(.c) c_int {
    log.debug("coex_enable", .{});

    return if (coex_enabled) c.coex_enable() else 0;
}

pub fn coex_disable() callconv(.c) void {
    log.debug("coex_disable", .{});

    if (coex_enabled) c.coex_disable();
}

pub fn coex_status_get() callconv(.c) u32 {
    log.debug("coex_status_get", .{});

    return if (coex_enabled) c.coex_status_get() else 0;
}

pub fn coex_condition_set() callconv(.c) void {
    @panic("coex_condition_set");
}

pub fn coex_wifi_request(
    event: u32,
    latency: u32,
    duration: u32,
) callconv(.c) c_int {
    log.debug("coex_wifi_request", .{});

    return if (coex_enabled) c.coex_wifi_request(event, latency, duration) else 0;
}

pub fn coex_wifi_release(event: u32) callconv(.c) c_int {
    log.debug("coex_wifi_release", .{});

    return if (coex_enabled) c.coex_wifi_release(event) else 0;
}

pub fn coex_wifi_channel_set(
    primary: u8,
    secondary: u8,
) callconv(.c) c_int {
    log.debug("coex_wifi_channel_set", .{});

    return if (coex_enabled) c.coex_wifi_channel_set(primary, secondary) else 0;
}

pub fn coex_event_duration_get(event: u32, duration: [*c]u32) callconv(.c) c_int {
    log.debug("coex_event_duration_get", .{});

    return if (coex_enabled) c.coex_event_duration_get(event, duration) else 0;
}

pub fn coex_pti_get(event: u32, pti: [*c]u8) callconv(.c) c_int {
    log.debug("coex_pti_get", .{});

    return if (coex_enabled) c.coex_pti_get(event, pti) else 0;
}

pub fn coex_schm_status_bit_clear(@"type": u32, status: u32) callconv(.c) void {
    log.debug("coex_schm_status_bit_clear", .{});

    if (coex_enabled) c.coex_schm_status_bit_clear(@"type", status);
}

pub fn coex_schm_status_bit_set(@"type": u32, status: u32) callconv(.c) void {
    log.debug("coex_schm_status_bit_set", .{});

    if (coex_enabled) c.coex_schm_status_bit_set(@"type", status);
}

pub fn coex_schm_interval_set(interval: u32) callconv(.c) c_int {
    log.debug("coex_schm_interval_set", .{});

    return if (coex_enabled) c.coex_schm_interval_set(interval) else 0;
}

pub fn coex_schm_interval_get() callconv(.c) u32 {
    log.debug("coex_schm_interval_get", .{});

    return if (coex_enabled) c.coex_schm_interval_get() else 0;
}

pub fn coex_schm_curr_period_get() callconv(.c) u8 {
    log.debug("coex_schm_curr_period_get", .{});

    return if (coex_enabled) c.coex_schm_curr_period_get() else 0;
}

pub fn coex_schm_curr_phase_get() callconv(.c) ?*anyopaque {
    log.debug("coex_schm_curr_phase_get", .{});

    return if (coex_enabled) c.coex_schm_curr_phase_get() else null;
}

pub fn coex_schm_process_restart() callconv(.c) c_int {
    log.debug("coex_schm_process_restart", .{});

    return if (coex_enabled) c.coex_schm_process_restart() else 0;
}

pub fn coex_schm_register_cb(
    @"type": c_int,
    callback: ?*const fn (c_int) callconv(.c) c_int,
) callconv(.c) c_int {
    log.debug("coex_schm_register_cb", .{});

    return if (coex_enabled) c.coex_schm_register_callback(@"type", callback) else 0;
}

pub fn coex_register_start_cb(cb: ?*const fn () callconv(.c) c_int) callconv(.c) c_int {
    log.debug("coex_register_start_cb", .{});

    return if (coex_enabled) c.coex_register_start_cb(cb) else 0;
}

extern fn ext_coex_schm_flexible_period_set(period: u8) i32;
pub fn coex_schm_flexible_period_set(period: u8) callconv(.c) c_int {
    log.debug("coex_schm_flexible_period_set {}", .{period});

    return if (coex_enabled) ext_coex_schm_flexible_period_set(period) else 0;
}

extern fn ext_coex_schm_flexible_period_get() u8;
pub fn coex_schm_flexible_period_get() callconv(.c) u8 {
    log.debug("coex_schm_flexible_period_get", .{});

    return if (coex_enabled) ext_coex_schm_flexible_period_get() else 0;
}
