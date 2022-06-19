//! A comptime trie which aims minimize runtime memory use.
//! Each node's `keys` array starts with length 0 and
//! grows by 1 from until `maxInt(Key)`.  This approach
//! trades greater comptime memory usage for reduced runtime
//! memory usage.
//! A CompTrie is constructed from comptime known data.
//!   - Options: orderFn - alternate orderFn. default is wrapper around std.math.order
//!            : use_binary_search: use std.sort.binarySearch(). otherwise linear search
//! Api is similar to a HashMap:
//!   - put(Key, Value)
//!   - get(Key) : runtime
//!   - iterator(), iteratorCallback(), nodeIterator(): runtime next()

const std = @import("std");
const assert = std.debug.assert;

pub fn Options(comptime K: type) type {
    return struct {
        /// type: fn(void, K, K) std.math.Order
        /// (same type as std.sort.binarySearch() compareFn parameter).
        orderFn: OrderFn = defaultOrderFn,
        /// if true, get() uses std.sort.binarySearch() otherwise linear search
        use_binary_search: bool = false,

        pub const OrderFn = @TypeOf(defaultOrderFn);
        pub const defaultOrderFn = struct {
            fn f(_: void, a: K, b: K) std.math.Order {
                return std.math.order(a, b);
            }
        }.f;
    };
}

pub fn CompTrie(comptime K: type, comptime V: type, options: Options(K)) type {
    return struct {
        root: Node = .{},
        maxdepth: u16 = 0,

        pub const Key = []K;
        pub const ConstKey = []const K;
        pub const Value = V;
        pub const KV = struct { key: ConstKey, value: Value };
        const Trie = @This();

        pub fn init(comptime keys: []const ConstKey, values: []const V) Trie {
            comptime {
                var trie: Trie = .{};
                for (keys) |key, i|
                    trie.put(key, values[i]);
                return trie;
            }
        }

        pub fn put(comptime trie: *Trie, key: ConstKey, value: V) void {
            trie.root.put(key, value);
            trie.maxdepth = std.math.max(trie.maxdepth, @intCast(u16, key.len));
        }
        pub fn get(trie: Trie, key: ConstKey) ?V {
            return trie.root.get(key);
        }

        /// write all trie keys to writer separated by delimiter
        pub fn writeAllDelim(comptime trie: Trie, writer: anytype, delimiter: []const u8) !void {
            var it = trie.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                if (i != 0) _ = try writer.write(delimiter);
                _ = try writer.write(kv.key);
            }
        }

        /// returns total number of bytes used by trie keys
        pub fn keyByteCount(comptime trie: Trie) usize {
            var count: usize = 0;
            var iter = trie.nodeIterator();
            while (iter.next()) |node|
                count += node.keys.len;
            return count;
        }

        /// returns total number of bytes used by the trie (keys + values)
        pub fn byteCount(comptime trie: Trie) usize {
            var count: usize = 0;
            var iter = trie.nodeIterator();
            while (iter.next()) |node|
                count += node.keys.len + @sizeOf(?Value);
            return count;
        }

        pub fn Iterator(comptime maxdepth: u16) type {
            return struct {
                itercb: IteratorCallback(maxdepth, ?KV),
                const Self = @This();
                pub fn next(self: *Self) ?KV {
                    _ = self.itercb.next();
                    return self.itercb.ctx.user_data;
                }
            };
        }

        /// next() yields KV for each node where node.value != null.
        /// implemented via iteratorCallback()
        pub fn iterator(comptime trie: Trie) Iterator(trie.maxdepth) {
            const cb = struct {
                inline fn f(ctx: *Trie.Ctx(?KV), kv: ?KV) void {
                    ctx.user_data = kv;
                }
            }.f;
            return .{ .itercb = trie.iteratorCallback(?KV, cb) };
        }

        pub fn Ctx(comptime UserData: type) type {
            return struct { node: *const Node, user_data: UserData };
        }

        pub fn IteratorCallback(comptime maxdepth: u16, comptime UserData: type) type {
            return struct {
                buf: [maxdepth]K = undefined,
                stack: [maxdepth + 1]Item = [1]Item{.{ .node = undefined, .idx = 0 }} ** (maxdepth + 1),
                depth: I = 0,
                ctx: CtxUserData,
                cb: Cb,

                const Self = @This();
                pub const CtxUserData = Ctx(UserData);
                pub const Cb = fn (*CtxUserData, ?Trie.KV) callconv(.Inline) void;
                pub const I = std.meta.Int(.unsigned, maxdepth + 1);
                const Item = struct {
                    node: Node,
                    idx: I,
                    visited: bool = false,
                    pub fn format(n: Item, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                        try writer.print("idx {} node.keys '{s}'", .{ n.idx, n.node.keys });
                    }
                };

                pub fn next(self: *Self) ?void {
                    const showdebug = false;
                    while (true) {
                        var item = &self.stack[self.depth];
                        if (showdebug) {
                            const k = self.buf[0..self.depth];
                            std.debug.print(
                                "1. it.depth {} it.buf '{s}' item.idx {} item.node.keys '{s}' item.node.value {}\n",
                                .{ self.depth, k, item.idx, item.node.keys, item.node.value },
                            );
                        }

                        // if this node has value and not alredy visited,
                        // set result, advance depth and return
                        if (item.node.value != null and !item.visited) {
                            self.ctx.node = &item.node;
                            self.cb(
                                &self.ctx,
                                KV{ .key = self.buf[0..self.depth], .value = item.node.value.? },
                            );
                            if (showdebug) std.debug.print("2. item.node.keys '{s}'\n  stack {any}\n", .{ item.node.keys, self.stack[0..self.depth] });
                            self.depth -= @boolToInt(item.idx >= item.node.keys.len);
                            item.visited = true;
                            return;
                        }

                        // go up stack til next good idx
                        while (item.idx >= item.node.keys.len and self.depth > 0) {
                            self.depth -= 1;
                            item = &self.stack[self.depth];
                            if (showdebug) std.debug.print(
                                "  3. depth {} item.idx {} item.node.keys.len {}\n",
                                .{ self.depth, item.idx, item.node.keys.len },
                            );
                        }

                        // if next child
                        // - put key in buf
                        // - descend and push to stack
                        // - advance idx
                        // else done
                        if (item.idx < item.node.keys.len) {
                            self.buf[self.depth] = item.node.keys[item.idx];
                            self.depth += 1;
                            self.stack[self.depth] = .{ .node = item.node.children[item.idx], .idx = 0 };
                            item.idx += 1;
                        } else break;
                    }
                    self.cb(&self.ctx, null);
                    return null;
                }
            };
        }

        /// calls callback for each node where node.value != null
        /// cb : fn(*CtxUserData, ?KV)
        pub fn iteratorCallback(
            comptime trie: Trie,
            comptime UserData: type,
            comptime cb: IteratorCallback(trie.maxdepth, UserData).Cb,
        ) IteratorCallback(trie.maxdepth, UserData) {
            const It = IteratorCallback(trie.maxdepth, UserData);
            var it: It = .{ .ctx = undefined, .cb = cb };
            it.stack[0] = .{ .node = trie.root, .idx = 0 };
            return it;
        }

        pub fn NodeIterator(comptime maxdepth: u16) type {
            return struct {
                stack: [maxdepth + 1]Item = [1]Item{.{ .node = undefined, .idx = 0 }} ** (maxdepth + 1),
                depth: I = 0,

                const Self = @This();
                pub const I = std.meta.Int(.unsigned, maxdepth + 1);
                const Item = struct {
                    node: Node,
                    idx: I,
                    visited: bool = false,
                    pub fn format(n: Item, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                        try writer.print("idx {} node.keys '{s}'", .{ n.idx, n.node.keys });
                    }
                };

                pub fn next(self: *Self) ?*const Node {
                    while (true) {
                        var item = &self.stack[self.depth];
                        const showdebug = false;
                        if (showdebug) {
                            std.debug.print(
                                "1. it.depth {} item.idx {} item.node.keys '{s}' item.node.value {}\n",
                                .{ self.depth, item.idx, item.node.keys, item.node.value },
                            );
                        }
                        if (!item.visited) {
                            item.visited = true;
                            return &item.node;
                        }

                        // go up stack til next good idx
                        while (item.idx >= item.node.keys.len and self.depth > 0) {
                            self.depth -= 1;
                            item = &self.stack[self.depth];
                            if (showdebug) std.debug.print(
                                "  3. depth {} item.idx {} item.node.keys.len {}\n",
                                .{ self.depth, item.idx, item.node.keys.len },
                            );
                        }

                        // either push next non-empty child or done
                        if (item.idx < item.node.keys.len) {
                            self.depth += 1;
                            self.stack[self.depth] = .{ .node = item.node.children[item.idx], .idx = 0 };
                            item.idx += 1;
                        } else break;
                    }
                    return null;
                }
            };
        }

        /// yields every node wether or not node.value == null
        pub fn nodeIterator(comptime trie: Trie) NodeIterator(trie.maxdepth) {
            const It = NodeIterator(trie.maxdepth);
            var it: It = .{};
            it.stack[0] = .{ .node = trie.root, .idx = 0 };
            return it;
        }

        pub const Node = struct {
            keys: Key = &.{},
            children: []Node = &.{},
            value: ?V = null,
            // pub fn format(n: Node, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            //     for (n.keys) |c, i| {
            //         try writer.print("{c}:{}", .{ c, n.children[i] });
            //     }
            // }

            const showdebug = false;
            pub fn put(comptime node: *Node, key: ConstKey, value: V) void {
                if (showdebug) @compileLog("insert", key);
                var n = node;
                var k = key;

                while (k.len > 0) : (k = k[1..]) {
                    const c = k[0];
                    const idx = indexOfScalarPosFnOrder(K, n.keys, 0, c, options.orderFn, .gt) orelse n.keys.len;
                    if (n.keys.len > 0 and n.keys[idx -| 1] == c) {
                        if (showdebug) @compileLog("found", c);
                        n = &n.children[idx -| 1];
                    } else {
                        if (showdebug) @compileLog("not found", c, "idx", idx, "keys.len", n.keys.len, "children.len", n.children.len);

                        var newkeys = insertAt(K, idx, c, n.keys);
                        n.keys = &newkeys;

                        var newchildren = insertAt(Node, idx, .{}, n.children);
                        n.children = &newchildren;

                        n = &n.children[idx];
                    }
                }
                n.value = value;
            }

            inline fn insertAt(comptime T: type, idx: usize, value: T, comptime ts: []const T) [ts.len + 1]T {
                var result: [ts.len + 1]T = undefined;
                for (result) |*k, i| {
                    const order = std.math.order(i, idx);
                    k.* = switch (order) {
                        .lt => ts[i],
                        .eq => value,
                        .gt => ts[i - 1],
                    };
                }
                return result;
            }

            pub fn get(node: Node, key: ConstKey) ?V {
                var n = node;
                var k = key;
                while (k.len > 0) : (k = k[1..]) {
                    if (options.use_binary_search) {
                        if (std.sort.binarySearch(K, k[0], n.keys, {}, options.orderFn)) |idx| {
                            n = n.children[idx];
                        } else return null;
                    } else {
                        if (indexOfScalarPosFn(K, n.keys, 0, k[0], options.orderFn)) |idx| {
                            n = n.children[idx];
                        } else return null;
                    }
                }
                return n.value;
            }

            pub inline fn indexOfScalarPosFn(comptime T: type, slice: []const T, start_index: usize, value: T, orderFn: Options(K).OrderFn) ?usize {
                return indexOfScalarPosFnOrder(T, slice, start_index, value, orderFn, .eq);
            }
            pub inline fn indexOfScalarPosFnOrder(comptime T: type, slice: []const T, start_index: usize, value: T, orderFn: Options(K).OrderFn, order: std.math.Order) ?usize {
                var i: usize = start_index;
                while (i < slice.len) : (i += 1) {
                    if (orderFn({}, slice[i], value) == order) return i;
                }
                return null;
            }
        };
    };
}

const t = std.testing;
const testwords: []const []const u8 = &.{ "bake", "band", "bank" };
const testotherwords: []const []const u8 = &.{ "bandsaw", "ban", "b", "" };
const testwords2: []const []const u8 = &.{ "mix", "mixed", "mixed-up" };

test "basic" {
    const Trie = CompTrie(u8, void, .{});
    const trie = Trie.init(testwords, &[1]void{{}} ** testwords.len);

    for (testwords) |word|
        try t.expect(trie.get(word) != null);

    for (testotherwords) |word|
        try t.expect(trie.get(word) == null);
}

const revOrderFn = struct {
    fn f(_: void, a: u8, b: u8) std.math.Order {
        return std.math.order(b, a);
    }
}.f;

test "options" {
    { // orderFn
        const Trie = CompTrie(u8, void, .{ .orderFn = revOrderFn });
        const trie = Trie.init(testwords, &[1]void{{}} ** testwords.len);
        for (testwords) |word|
            try t.expect(trie.get(word) != null);
        for (testotherwords) |word|
            try t.expect(trie.get(word) == null);
    }
    { // orderFn + use_binary_search
        const Trie = CompTrie(u8, void, .{ .orderFn = revOrderFn, .use_binary_search = true });
        const trie = Trie.init(testwords, &[1]void{{}} ** testwords.len);
        for (testwords) |word|
            try t.expect(trie.get(word) != null);
        for (testotherwords) |word|
            try t.expect(trie.get(word) == null);
    }
}

test "enum trie" {
    const E = enum {
        a,
        aa,
        aaaa,
        aaaaa,
        aaaaaaaaaaaaaaaaaaaaaaaaa,
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
    };
    const Trie = CompTrie(u8, E, .{});

    const names = comptime std.meta.fieldNames(E);
    const values = comptime std.enums.values(E);
    const trie = comptime Trie.init(names, values);
    for (names) |name, i| {
        const mval = trie.get(name);
        try t.expect(mval != null);
        try t.expectEqual(values[i], mval.?);
    }
}

test "iterator" {
    const Trie = CompTrie(u8, void, .{});

    const trie = comptime Trie.init(testwords2, &[1]void{{}} ** testwords2.len);
    var iter = trie.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| : (i += 1) {
        try t.expectEqualStrings(testwords2[i], entry.key);
    }
    try t.expectEqual(testwords2.len, i);
}

test "many words" {
    @setEvalBranchQuota(20000);
    const Trie = CompTrie(u8, void, .{});
    const words100 = @embedFile("../words-100-random.txt");
    const trie = comptime blk: {
        var set: Trie = .{};
        var it = std.mem.split(u8, words100, "\n");
        while (it.next()) |w| {
            set.put(w, {});
        }
        break :blk set;
    };
    var it = std.mem.split(u8, words100, "\n");
    var iter = trie.iterator();
    while (it.next()) |w| {
        try t.expect(trie.get(w) != null);
        const entry = iter.next();
        try t.expect(entry != null);
        try t.expectEqualStrings(w, entry.?.key);
    }
}

test "writeAllDelim" {
    const Trie = CompTrie(u8, void, .{});
    const trie = comptime Trie.init(testwords, &[1]void{{}} ** testwords.len);
    var list = std.ArrayList(u8).init(t.allocator);
    defer list.deinit();
    try trie.writeAllDelim(list.writer(), "");

    const joined_testwords = try std.mem.concat(t.allocator, u8, testwords);
    defer t.allocator.free(joined_testwords);
    try t.expectEqualStrings(joined_testwords, list.items);
}

test "byteCount" {
    const Trie = CompTrie(u8, void, .{});
    const trie = comptime Trie.init(testwords2, &[1]void{{}} ** testwords2.len);
    try t.expectEqual(@as(usize, 8), trie.keyByteCount());
    try t.expectEqual(@as(usize, 17), trie.byteCount());
}

/// uses simd to compare 16 bytes at a time.
/// note: not used but left for use in possible future optimizations
pub fn indexOfScalarPos(comptime T: type, slice: []const T, start_index: usize, value: T) ?usize {
    if (start_index > slice.len) return null;

    const stride = 16;
    const total = slice.len - start_index;
    const n = total / stride;
    const V = std.meta.Vector(stride, T);

    const vs = @splat(stride, value);
    var i: usize = start_index;
    while (i < (n * stride)) : (i += stride) {
        const v: V = slice[i..][0..stride].*;
        const cmp = (v == vs);
        if (std.simd.firstTrue(cmp)) |idx| return idx + i;
    }

    var buf = [1]T{0} ** stride;
    std.mem.copy(T, &buf, slice[i..]);
    const v: V = buf;
    const cmp = (v == vs);
    if (std.simd.firstTrue(cmp)) |idx| return idx + i;
    return null;
}

test "indexOfScalarPos" {
    try t.expectEqual(@as(?usize, 0), indexOfScalarPos(u8, "abcd", 0, 'a'));
    try t.expectEqual(@as(?usize, 3), indexOfScalarPos(u8, "abcd", 0, 'd'));
    try t.expectEqual(@as(?usize, 25), indexOfScalarPos(u8, "abcdefghijklmnopqrstuvwxyz", 0, 'z'));
}
