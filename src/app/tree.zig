const std = @import("std");
const A = std.mem.Allocator;

const OOM = std.mem.Allocator.Error;

/// Iterator for an n-ary tree.
/// T element must have pointers firstChild, lastChild, nextSibling, prevSibling.
pub fn TreeIterator(comptime T: type) type
{
    const StackItem = struct {
        node: *T,
        flag: bool = false, // used for PostOrder
    };
    const Mode = enum {
        PreOrder,
        PostOrder,
    };

    const Iterator = struct {
        mode: Mode,
        stack: std.ArrayList(StackItem),
        a: A,

        const Self = @This();

        pub fn init(a: A) Self
        {
            const self = Self {
                .mode = undefined,
                .stack = std.ArrayList(StackItem){},
                .a = a,
            };
            return self;
        }

        pub fn deinit(self: *Self) void
        {
            self.stack.deinit(self.a);
        }

        pub fn prepare(self: *Self, root: *T, mode: Mode) OOM!void
        {
            try self.stack.append(self.a, .{.node = root});
            self.mode = mode;
        }

        pub fn next(self: *Self) OOM!?*T
        {
            if (self.stack.items.len == 0) {
                return null;
            }

            switch (self.mode) {
                .PreOrder => {
                    const item = self.stack.pop().?;
                    if (item.node.firstChild != item.node) {
                        var child = item.node.lastChild;
                        while (true) : (child = child.prevSibling) {
                            try self.stack.append(self.a, .{.node = child});
                            if (child.prevSibling == child) {
                                break;
                            }
                        }
                    }
                    return item.node;
                },
                .PostOrder => {
                    while (true) {
                        var item = &self.stack.items[self.stack.items.len - 1];
                        if (!item.flag and item.node.firstChild != item.node) {
                            var child = item.node.lastChild;
                            while (true) : (child = child.prevSibling) {
                                try self.stack.append(self.a, .{.node = child});
                                if (child.prevSibling == child) {
                                    break;
                                }
                            }
                            item.flag = true;
                        } else {
                            _ = self.stack.pop();
                            return item.node;
                        }
                    }
                },
            }
        }
    };
    return Iterator;
}

test "traversal" {
    const allocator = std.testing.allocator;

    const Node = struct {
        firstChild: *Self,
        lastChild: *Self,
        nextSibling: *Self,
        prevSibling: *Self,
        value: u64 = 0,

        const Self = @This();
    };

    var nodes: [12]Node = undefined;
    nodes[0] = .{
        .firstChild = &nodes[1],
        .lastChild = &nodes[3],
        .nextSibling = &nodes[0],
        .prevSibling = &nodes[0],
    };
    nodes[1] = .{
        .firstChild = &nodes[4],
        .lastChild = &nodes[6],
        .nextSibling = &nodes[2],
        .prevSibling = &nodes[1],
    };
    nodes[2] = .{
        .firstChild = &nodes[2],
        .lastChild = &nodes[2],
        .nextSibling = &nodes[3],
        .prevSibling = &nodes[1],
    };
    nodes[3] = .{
        .firstChild = &nodes[7],
        .lastChild = &nodes[8],
        .nextSibling = &nodes[3],
        .prevSibling = &nodes[2],
    };
    nodes[4] = .{
        .firstChild = &nodes[4],
        .lastChild = &nodes[4],
        .nextSibling = &nodes[5],
        .prevSibling = &nodes[4],
    };
    nodes[5] = .{
        .firstChild = &nodes[9],
        .lastChild = &nodes[9],
        .nextSibling = &nodes[6],
        .prevSibling = &nodes[4],
    };
    nodes[6] = .{
        .firstChild = &nodes[10],
        .lastChild = &nodes[11],
        .nextSibling = &nodes[6],
        .prevSibling = &nodes[5],
    };
    nodes[7] = .{
        .firstChild = &nodes[7],
        .lastChild = &nodes[7],
        .nextSibling = &nodes[8],
        .prevSibling = &nodes[7],
    };
    nodes[8] = .{
        .firstChild = &nodes[8],
        .lastChild = &nodes[8],
        .nextSibling = &nodes[8],
        .prevSibling = &nodes[7],
    };
    nodes[9] = .{
        .firstChild = &nodes[9],
        .lastChild = &nodes[9],
        .nextSibling = &nodes[9],
        .prevSibling = &nodes[9],
    };
    nodes[10] = .{
        .firstChild = &nodes[10],
        .lastChild = &nodes[10],
        .nextSibling = &nodes[11],
        .prevSibling = &nodes[10],
    };
    nodes[11] = .{
        .firstChild = &nodes[11],
        .lastChild = &nodes[11],
        .nextSibling = &nodes[11],
        .prevSibling = &nodes[10],
    };
    for (&nodes, 0..) |*node, i| {
        node.value = i;
    }

    var it = TreeIterator(Node).init(allocator);
    defer it.deinit();
    var i: usize = undefined;

    const preOrderValues = [_]u64 {0, 1, 4, 5, 9, 6, 10, 11, 2, 3, 7, 8};
    try it.prepare(&nodes[0], .PreOrder);
    i = 0;
    while (try it.next()) |node| {
        try std.testing.expectEqual(preOrderValues[i], node.value);
        i += 1;
    }
    try std.testing.expectEqual(nodes.len, i);

    const postOrderValues = [_]u64 {4, 9, 5, 10, 11, 6, 1, 2, 7, 8, 3, 0};
    try it.prepare(&nodes[0], .PostOrder);
    i = 0;
    while (try it.next()) |node| {
        try std.testing.expectEqual(postOrderValues[i], node.value);
        i += 1;
    }
    try std.testing.expectEqual(nodes.len, i);
}
