const std = @import("std");
const A = std.mem.Allocator;

const game = @import("game.zig");

pub const PlayerId = game.PlayerId;
pub const PlayerInput = game.PlayerInput;
pub const State = game.State;
pub const RenderState = game.client.RenderState;

pub const tick = game.tick;
pub const onPlayerConnect = game.onPlayerConnect;
pub const getInput = game.client.getInput;
pub const draw = game.client.draw;

pub const OPTIONS: Options = game.OPTIONS;

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
    serverDefaultPort: u16,
};

pub const TickInput = struct {
    hasInput: [OPTIONS.maxPlayers]bool = [1]bool {false} ** OPTIONS.maxPlayers,
    inputs: [OPTIONS.maxPlayers]PlayerInput = [1]PlayerInput {.{}} ** OPTIONS.maxPlayers,
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

        pub fn tickFromTo(self: *Self, ticksFrom: u64, ticksTo: u64, a: A) void
        {
            std.debug.assert(ticksFrom > 0);
            std.debug.assert(ticksFrom <= ticksTo);
            var snapshotPrev = self.getSnapshot(ticksFrom - 1);
            for (ticksFrom..ticksTo) |i| {
                const snapshot = self.getSnapshot(i);
                snapshot.state = snapshotPrev.state;
                // TODO reset allocator before every call?
                game.tick(false, &snapshot.state, &snapshot.input, a);
                snapshotPrev = snapshot;
            }
        }
    };
    return T;
}
