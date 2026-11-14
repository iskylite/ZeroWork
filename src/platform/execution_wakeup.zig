//! In-process wake hints for execution drivers. Snapshots remain authoritative.
const std = @import("std");
const Wakeup = @import("wakeup.zig").Wakeup;

var mutex: std.atomic.Mutex = .unlocked;
var listeners: ?*Listener = null;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub const Listener = struct {
    wake: *const Wakeup,
    next: ?*Listener = null,

    pub fn register(self: *Listener) void {
        lock();
        defer mutex.unlock();
        self.next = listeners;
        listeners = self;
    }

    pub fn unregister(self: *Listener) void {
        lock();
        defer mutex.unlock();
        var link = &listeners;
        while (link.*) |entry| : (link = &entry.next) {
            if (entry == self) {
                link.* = self.next;
                self.next = null;
                return;
            }
        }
    }
};

pub fn notify() void {
    lock();
    defer mutex.unlock();
    var next = listeners;
    while (next) |listener| : (next = listener.next) listener.wake.notify();
}
