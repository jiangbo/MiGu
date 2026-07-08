const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Oom = Allocator.Error;
pub const Error = Oom || error{MaxEntity};
pub const Entity = u16;
const invalid = std.math.maxInt(u16);
fn hasEntity(slice: []const u16, entity: u16) bool {
    return entity < slice.len and slice[entity] != invalid;
}
pub const Version = u16;
pub const Handle = struct { entity: u16, version: Version };

fn Event(T: type) type {
    return struct { event: T };
}

const Entities = struct {
    versions: std.ArrayList(Version) = .empty,
    deleted: std.DynamicBitSetUnmanaged = .{},
    deletedCount: u16 = 0,

    fn deinit(self: *Entities, gpa: Allocator) void {
        self.versions.deinit(gpa);
        self.deleted.deinit(gpa);
    }

    pub fn create(self: *Entities, gpa: Allocator) Error!u16 {
        if (self.deletedCount > 0) {
            self.deletedCount -= 1;
            return @intCast(self.deleted.toggleFirstSet().?);
        }

        if (self.versions.items.len == invalid) return error.MaxEntity;
        try self.versions.ensureUnusedCapacity(gpa, 1);
        if (self.versions.capacity > self.deleted.capacity())
            try self.deleted.resize(gpa, self.versions.capacity, false);

        self.versions.appendAssumeCapacity(0);
        return @intCast(self.versions.items.len - 1);
    }

    fn destroy(self: *Entities, entity: u16) void {
        std.debug.assert(!self.deleted.isSet(entity));
        self.versions.items[entity] +%= 1;
        self.deleted.set(entity);
        self.deletedCount += 1;
    }

    pub fn isAlive(self: *const Entities, id: Handle) bool {
        return id.entity < self.versions.items.len and
            self.versions.items[id.entity] == id.version;
    }

    pub fn to(self: *const Entities, entity: u16) ?Handle {
        if (entity < self.versions.items.len) {
            std.debug.assert(!self.deleted.isSet(entity));
            const version = self.versions.items[entity];
            return .{ .entity = entity, .version = version };
        } else return null;
    }

    pub fn get(self: *const Entities, handle: ?Handle) ?u16 {
        const id = handle orelse return null;
        return if (self.isAlive(id)) id.entity else null;
    }
};

fn Store(V: type) type {
    return struct {
        sparse: std.ArrayList(u16) = .empty,
        dense: [*]u16 = std.ArrayList(u16).empty.items.ptr,
        values: [*]V = std.ArrayList(V).empty.items.ptr,
        len: u16 = 0,
        denseCap: u32 = 0,
        valueCap: u32 = if (@sizeOf(V) == 0) invalid else 0,
        identity: u16 = invalid,
        alignment: std.mem.Alignment = .of(V),
        valueSize: u16 = @sizeOf(V),

        fn deinit(self: *@This(), gpa: Allocator) void {
            self.sparse.deinit(gpa);

            if (self.denseCap != 0) gpa.free(self.dense[0..self.denseCap]);
            if (self.valueCap == 0 or self.valueSize == 0) return;

            const size = @as(usize, self.valueCap) * self.valueSize;
            const bytes = @as([*]u8, @ptrCast(self.values))[0..size];
            gpa.rawFree(bytes, self.alignment, @returnAddress());
        }

        fn add(self: *@This(), gpa: Allocator, entity: u16, v: V) Oom!void {
            if (hasEntity(self.sparse.items, entity)) {
                self.values[self.sparse.items[entity]] = v;
                return;
            }

            if (entity >= self.sparse.items.len) {
                const count = entity + 1 - self.sparse.items.len;
                try self.sparse.appendNTimes(gpa, invalid, count);
            }

            if (self.len >= self.valueCap) try self.growValue(gpa);
            if (self.len >= self.denseCap) try self.growDense(gpa);
            self.dense[self.len] = entity;
            self.values[self.len] = v;
            self.sparse.items[entity] = self.len;
            self.len += 1;
        }

        fn appendValue(self: *@This(), gpa: Allocator, v: V) Oom!void {
            if (self.len >= self.valueCap) try self.growValue(gpa);
            self.values[self.len] = v;
            self.len += 1;
        }

        fn growValue(self: *@This(), gpa: Allocator) Oom!void {
            if (@sizeOf(V) == 0) return;
            var values: std.ArrayList(V) = .{
                .items = self.values[0..self.len],
                .capacity = self.valueCap,
            };
            if (self.valueCap == 0) {
                try values.ensureTotalCapacityPrecise(gpa, 1);
            } else try values.ensureUnusedCapacity(gpa, 1);
            self.values = values.items.ptr;
            self.valueCap = @intCast(values.capacity);
        }

        fn growDense(self: *@This(), gpa: Allocator) Oom!void {
            var dense: std.ArrayList(u16) = .{
                .items = self.dense[0..self.len],
                .capacity = self.denseCap,
            };
            if (self.denseCap == 0) {
                try dense.ensureTotalCapacityPrecise(gpa, 1);
            } else try dense.ensureUnusedCapacity(gpa, 1);
            self.dense = dense.items.ptr;
            self.denseCap = @intCast(dense.capacity);
        }

        fn remove(self: *@This(), entity: u16) void {
            if (!hasEntity(self.sparse.items, entity)) return;

            const index = self.sparse.items[entity];
            self.sparse.items[entity] = invalid;

            self.len -= 1;
            const moved = self.dense[self.len];
            if (self.len == index) return;
            self.sparse.items[moved] = index;
            self.dense[index] = moved;
            if (self.valueSize == 0) return;

            const sz = if (V == u8) self.valueSize else 1;
            const src = self.values[sz * self.len ..];
            @memcpy(self.values[sz * index ..][0..sz], src[0..sz]);
        }

        fn sort(self: *@This(), lessFn: fn (V, V) bool) void {
            if (self.len <= 1 or self.valueSize == 0) return;

            const sparse = self.sparse.items;
            const dense = self.dense[0..self.len];
            const v = self.values[0..self.len];
            for (1..v.len) |i| {
                var j = i;
                while (j > 0 and lessFn(v[j], v[j - 1])) : (j -= 1) {
                    std.mem.swap(V, &v[j], &v[j - 1]);
                    const lhs = &dense[j];
                    const rhs = &dense[j - 1];
                    std.mem.swap(u16, lhs, rhs);
                    std.mem.swap(u16, &sparse[lhs.*], &sparse[rhs.*]);
                }
            }
        }

        fn clear(self: *@This()) void {
            @memset(self.sparse.items, invalid);
            self.len = 0;
        }
    };
}

pub const TypeId = u64;
pub const World = struct {
    allocator: Allocator,
    entities: Entities = .{},
    map: std.AutoHashMapUnmanaged(TypeId, Store(u8)) = .empty,
    entity: u16 = invalid,

    pub fn init(allocator: std.mem.Allocator) World {
        comptime std.debug.assert(@sizeOf(Store(u8)) <= 64);
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *World) void {
        self.entities.deinit(self.allocator);
        var iterator = self.map.valueIterator();
        while (iterator.next()) |map| map.deinit(self.allocator);
        self.map.deinit(self.allocator);
    }

    pub fn reset(self: *World) void {
        self.deinit();
        self.* = .init(self.allocator);
    }

    pub fn resetKeep(self: *World, Types: anytype) void {
        self.tryResetKeep(Types) catch @panic("oom");
    }

    pub fn tryResetKeep(self: *World, Types: anytype) Error!void {
        var new = World.init(self.allocator);
        try new.map.ensureTotalCapacity(new.allocator, Types.len);
        inline for (Types) |T| {
            if (self.map.fetchRemove(typeId(T))) |r| {
                new.map.putAssumeCapacityNoClobber(r.key, r.value);
            }
        }
        self.deinit();
        self.* = new;
    }

    pub fn tryCreateEntity(self: *World) Error!u16 {
        return self.entities.create(self.allocator);
    }

    pub fn tryAddIdentity(self: *World, entity: u16, T: type) Oom!void {
        (try self.tryAssure(T, T)).identity = entity;
    }

    pub fn tryAddEvent(self: *World, value: anytype) Oom!void {
        var map = try self.tryAssure(Event(@TypeOf(value)), @TypeOf(value));
        try map.appendValue(self.allocator, value);
    }

    pub fn tryAdd(self: *World, entity: u16, value: anytype) Oom!void {
        var map = try self.tryAssure(@TypeOf(value), @TypeOf(value));
        try map.add(self.allocator, entity, value);
    }

    fn tryAssure(self: *World, K: type, V: type) Oom!*Store(V) {
        const result = try self.map.getOrPut(self.allocator, typeId(K));
        const map: *Store(V) = @ptrCast(@alignCast(result.value_ptr));
        if (!result.found_existing) map.* = .{};
        return map;
    }

    pub fn createEntity(self: *World) u16 {
        return self.tryCreateEntity() catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
            error.MaxEntity => @panic("ecs max entity"),
        };
    }

    pub fn destroyEntity(self: *World, entity: u16) void {
        self.removeAll(entity);
        self.entities.destroy(entity);
    }

    pub fn destroyEntities(self: *World, T: type) void {
        var toDestroy = self.query(.{T}).reverse();
        while (toDestroy.next()) |entity| self.destroyEntity(entity);
    }

    pub fn addIdentity(self: *World, entity: u16, T: type) void {
        self.tryAddIdentity(entity, T) catch @panic("oom");
    }

    pub fn createIdentity(self: *World, T: type) u16 {
        const entity = self.createEntity();
        self.addIdentity(entity, T);
        return entity;
    }

    pub fn getIdentity(self: *World, T: type) ?u16 {
        const map = self.getStore(T, T) orelse return null;
        return if (map.identity == invalid) null else map.identity;
    }

    pub fn takeIdentity(self: *World, T: type) ?u16 {
        const entity = self.getIdentity(T);
        self.removeIdentity(T);
        return entity;
    }

    pub fn isIdentity(self: *World, entity: u16, T: type) bool {
        return if (self.getIdentity(T)) |e| e == entity else false;
    }

    pub fn hasIdentity(self: *World, I: type, T: type) bool {
        const entity = self.getIdentity(I) orelse return false;
        return self.has(entity, T);
    }

    pub fn removeIdentity(self: *World, T: type) void {
        if (self.getStore(T, T)) |map| map.identity = invalid;
    }

    pub fn addEvent(self: *World, value: anytype) void {
        self.tryAddEvent(value) catch @panic("oom");
    }

    pub fn getEvent(self: *World, T: type) []T {
        const map = self.getStore(Event(T), T) orelse return &.{};
        return map.values[0..map.len];
    }

    pub fn clearEvent(self: *World, T: type) void {
        if (self.getStore(Event(T), T)) |map| map.clear();
    }

    pub fn removeEvent(self: *World, T: type) void {
        var removed = self.map.fetchRemove(typeId(Event(T)));
        if (removed) |*r| r.value.deinit(self.allocator);
    }

    fn getStore(self: *World, K: type, V: type) ?*Store(V) {
        const map = self.map.getPtr(typeId(K)) orelse return null;
        return @ptrCast(@alignCast(map));
    }

    pub fn has(self: *World, entity: u16, T: type) bool {
        const map = self.getStore(T, T) orelse return false;
        return hasEntity(map.sparse.items, entity);
    }

    pub fn get(self: *World, entity: u16, T: type) ?T {
        return if (self.getPtr(entity, T)) |ptr| ptr.* else null;
    }

    pub fn getPtr(self: *World, entity: u16, T: type) ?*T {
        const map = self.getStore(T, T) orelse return null;
        if (!hasEntity(map.sparse.items, entity)) return null;
        return &map.values[map.sparse.items[entity]];
    }

    pub fn add(self: *World, entity: u16, value: anytype) void {
        self.tryAdd(entity, value) catch @panic("oom");
    }

    pub fn addAll(self: *World, entity: u16, bundle: anytype) void {
        inline for (bundle) |value| self.add(entity, value);
    }

    pub fn values(self: *World, T: type) []T {
        const map = self.getStore(T, T) orelse return &.{};
        return map.values[0..map.len];
    }

    pub fn sort(self: *World, T: type, lessFn: fn (T, T) bool) void {
        if (self.getStore(T, T)) |map| map.sort(lessFn);
    }

    pub fn remove(self: *World, entity: u16, T: type) void {
        if (self.getStore(T, T)) |map| map.remove(entity);
    }

    pub fn removeAll(self: *World, entity: u16) void {
        var iterator = self.map.valueIterator();
        while (iterator.next()) |map| {
            map.remove(entity);
            if (map.identity == entity) map.identity = invalid;
        }
    }

    pub fn clear(self: *World, T: type) void {
        if (self.getStore(T, T)) |map| map.clear();
    }

    pub fn query(self: *World, All: anytype) Query(All, .{}) {
        return self.queryNot(All, .{});
    }

    // zig fmt: off
    pub fn queryNot(self: *World, All: anytype, None: anytype)
        Query(All, None) {
    // zig fmt: on
        comptime std.debug.assert(All.len > 0);

        var result: Query(All, None) = .{};
        var minCount: usize = invalid;
        inline for (All, &result.sparse, &result.values) |T, *s, *v| {
            const map = self.getStore(T, T) orelse return .{};
            s.*, v.* = .{ map.sparse.items, map.values };
            if (map.len < minCount) {
                minCount = map.len;
                result.dense = map.dense[0..map.len];
            }
        }
        inline for (None, &result.none) |T, *none| {
            if (self.getStore(T, T)) |s| none.* = s.sparse.items;
        }
        return result;
    }

    // zig fmt: off
    pub fn queryBy(self: *World, By: type, All: anytype,
        None: anytype) Query(.{By} ++ All, None) {
    // zig fmt: on
        var rs: Query(.{By} ++ All, None) = .{};
        const by = self.getStore(By, By) orelse return rs;
        rs.dense = by.dense[0..by.len];

        inline for (.{By} ++ All, &rs.sparse, &rs.values) |T, *s, *v| {
            const map = self.getStore(T, T) orelse return .{};
            s.*, v.* = .{ map.sparse.items, map.values };
        }
        inline for (None, &rs.none) |T, *none| {
            if (self.getStore(T, T)) |s| none.* = s.sparse.items;
        }
        return rs;
    }
};

pub fn Query(comptime All: anytype, comptime None: anytype) type {
    return struct {
        dense: []u16 = &.{},
        sparse: [All.len][]u16 = undefined,
        values: [All.len]*anyopaque = undefined,
        none: [None.len][]u16 = @splat(&.{}),
        index: u16 = 0,
        reversed: bool = false,

        pub fn reverse(self: @This()) @This() {
            var query = self;
            query.index = @intCast(query.dense.len -| 1);
            query.reversed = true;
            return query;
        }

        pub fn next(self: *@This()) ?u16 {
            blk: while (self.index < self.dense.len) {
                const entity = self.dense[self.index];
                if (self.reversed) self.index -%= 1 else self.index += 1;
                for (self.sparse) |sparse| {
                    if (!hasEntity(sparse, entity)) continue :blk;
                }
                for (self.none) |sparse| {
                    if (hasEntity(sparse, entity)) continue :blk;
                }
                return entity;
            } else return null;
        }

        pub fn add(_: *@This(), world: *World, e: u16, v: anytype) void {
            const inQuery = inline for (All ++ None) |C| {
                if (C == @TypeOf(v)) break true;
            } else false;
            if (inQuery) std.debug.assert(world.has(e, @TypeOf(v)));
            world.add(e, v);
        }

        pub fn get(self: *@This(), entity: u16, T: type) T {
            return self.getPtr(entity, T).*;
        }

        pub fn getPtr(self: *@This(), entity: u16, T: type) *T {
            const i = blk: inline for (All, 0..) |Comp, i| {
                if (Comp == T) break :blk i;
            } else @compileError(T ++ " is not in query type");
            const values: [*]T = @ptrCast(@alignCast(self.values[i]));
            return &values[self.sparse[i][entity]];
        }
    };
}

pub fn typeId(T: type) TypeId {
    return comptime std.hash.Fnv1a_64.hash(@typeName(T));
}
