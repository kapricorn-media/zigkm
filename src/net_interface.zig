const std = @import("std");
const A = std.mem.Allocator;

const Exports = @import("root").Exports;

pub const PlayerId = Exports._PlayerId;
pub const PlayerInput = Exports._PlayerInput;
pub const State = Exports._State;
pub const tick = Exports._tick;
pub const OPTIONS: Options = Exports._OPTIONS;

pub const Mode = enum {
    client,
    server,
};

pub const Options = struct {
    nsPerTick: u64,
    maxPlayers: PlayerId,
    serverNsPerNet: u64,
    serverInputBacklog: i32,
    serverMaxInputLag: i32,
};

pub const TickInput = struct {
    hasInput: [OPTIONS.maxPlayers]bool,
    inputs: [OPTIONS.maxPlayers]PlayerInput,
};

pub const InputState = struct {
    input: TickInput,
    state: State,
};

pub fn StateHistory(comptime N: u64) type
{
    const T = struct {
        snapshots: [N]InputState,

        const Self = @This();

        pub fn getSnapshot(self: *Self, ticks: u64) *InputState
        {
            return &self.snapshots[ticks % N];
        }

        pub fn tickFromTo(self: *Self, ticksFrom: u64, ticksTo: u64) void
        {
            std.debug.assert(ticksFrom > 0);
            std.debug.assert(ticksFrom <= ticksTo);
            var snapshotPrev = self.getSnapshot(ticksFrom - 1);
            for (ticksFrom..ticksTo) |i| {
                const snapshot = self.getSnapshot(i);
                snapshot.state = snapshotPrev.state;
                tick(&snapshot.state, &snapshot.input);
                snapshotPrev = snapshot;
            }
        }
    };
    return T;
}
