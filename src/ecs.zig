const std = @import("std");
const root = @import("root");

const Allocator = std.mem.Allocator;

pub const Oom = Allocator.Error;
pub const EntityError = Oom || error{MaxEntity};
pub const EventError = Oom || error{MaxEvent};
pub const Entity = u16;
const invalid = std.math.maxInt(u16);
fn hasEntity(slice: []const u16, entity: u16) bool {
    return entity < slice.len and slice[entity] != invalid;
}
pub const Version = u16;
pub const Handle = struct { entity: u16, version: Version };

const Kind = enum { component, event, resource };

const Entities = struct {
    versions: std.ArrayList(Version) = .empty,
    deleted: std.ArrayList(u16) = .empty,

    fn deinit(self: *Entities, gpa: Allocator) void {
        self.versions.deinit(gpa);
        self.deleted.deinit(gpa);
    }

    pub fn create(self: *Entities, gpa: Allocator) EntityError!u16 {
        if (self.deleted.pop()) |entity| {
            self.versions.items[entity] +%= 1;
            return entity;
        }

        if (self.versions.items.len == invalid) return error.MaxEntity;
        const count = self.versions.items.len + 1;
        var cap = self.versions.capacity;
        if (count > cap) {
            cap = @min(std.ArrayList(Version).growCapacity(count), invalid);
            try self.versions.ensureTotalCapacityPrecise(gpa, cap);
        }
        try self.deleted.ensureTotalCapacityPrecise(gpa, cap);

        self.versions.appendAssumeCapacity(0);
        return @intCast(self.versions.items.len - 1);
    }

    fn destroy(self: *Entities, entity: u16) void {
        std.debug.assert(self.versions.items[entity] % 2 == 0);
        self.versions.items[entity] +%= 1;
        self.deleted.appendAssumeCapacity(entity);
    }

    pub fn isAlive(self: *const Entities, id: Handle) bool {
        return id.entity < self.versions.items.len and
            id.version % 2 == 0 and
            self.versions.items[id.entity] == id.version;
    }

    pub fn to(self: *const Entities, entity: u16) ?Handle {
        if (entity >= self.versions.items.len) return null;
        const version = self.versions.items[entity];
        std.debug.assert(version % 2 == 0);
        return .{ .entity = entity, .version = version };
    }

    pub fn get(self: *const Entities, handle: ?Handle) ?u16 {
        const id = handle orelse return null;
        return if (self.isAlive(id)) id.entity else null;
    }
};

fn Store(V: type, comptime kind: Kind) type {
    return struct {
        sparse: []u16 = &.{},
        dense: [*]u16 = @ptrFromInt(@alignOf(u16)),
        values: [*]V = @ptrFromInt(@alignOf(V)),
        len: u16 = 0,
        denseCap: u32 = 0,
        valueCap: u32 = if (@sizeOf(V) == 0) invalid else 0,
        identity: u16 = invalid,
        alignment: std.mem.Alignment = .of(V),
        valueSize: u16 = @sizeOf(V),

        fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.sparse);

            if (self.denseCap != 0) gpa.free(self.dense[0..self.denseCap]);
            if (self.valueCap == 0 or self.valueSize == 0) return;

            const size = @as(usize, self.valueCap) * self.valueSize;
            const bytes = @as([*]u8, @ptrCast(self.values))[0..size];
            gpa.rawFree(bytes, self.alignment, @returnAddress());
        }

        fn add(self: *@This(), gpa: Allocator, entity: u16, v: V) Oom!void {
            if (hasEntity(self.sparse, entity)) {
                self.values[self.sparse[entity]] = v;
                return;
            }

            if (entity >= self.sparse.len) try self.growSparse(gpa, entity + 1);
            if (self.len >= self.valueCap) try self.growValue(gpa);
            if (self.len >= self.denseCap) try self.growDense(gpa);

            self.dense[self.len] = entity;
            self.values[self.len] = v;
            self.sparse[entity] = self.len;
            self.len += 1;
        }

        fn appendValue(self: *@This(), gpa: Allocator, v: V) Oom!void {
            if (self.len >= self.valueCap) try self.growValue(gpa);
            self.values[self.len] = v;
            self.len += 1;
        }

        fn growSparse(self: *@This(), gpa: Allocator, count: usize) Oom!void {
            const cap = @min(std.ArrayList(u16).growCapacity(count), invalid);
            const sparse = try gpa.realloc(self.sparse, cap);
            @memset(sparse[self.sparse.len..], invalid);
            self.sparse = sparse;
        }

        fn growValue(self: *@This(), gpa: Allocator) Oom!void {
            if (@sizeOf(V) == 0) return;
            var cap = std.ArrayList(V).growCapacity(@as(usize, self.len) + 1);
            if (kind == .resource) cap = 1;
            const values = try gpa.realloc(self.values[0..self.valueCap], cap);
            self.values = values.ptr;
            self.valueCap = @intCast(values.len);
        }

        fn growDense(self: *@This(), gpa: Allocator) Oom!void {
            const cap = std.ArrayList(u16).growCapacity(self.denseCap + 1);
            const dense = try gpa.realloc(self.dense[0..self.denseCap], cap);
            self.dense = dense.ptr;
            self.denseCap = @intCast(dense.len);
        }

        fn remove(self: *@This(), entity: u16) void {
            if (!hasEntity(self.sparse, entity)) return;

            const index = self.sparse[entity];
            self.sparse[entity] = invalid;

            self.len -= 1;
            const moved = self.dense[self.len];
            if (self.len == index) return;
            self.sparse[moved] = index;
            self.dense[index] = moved;
            if (self.valueSize == 0) return;

            const sz: usize = if (V == u8) self.valueSize else 1;
            const src = self.values[sz * self.len ..];
            @memcpy(self.values[sz * index ..][0..sz], src[0..sz]);
        }

        fn sort(self: *@This(), lessFn: fn (V, V) bool) void {
            if (self.len <= 1 or self.valueSize == 0) return;

            const sparse = self.sparse;
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
            @memset(self.sparse, invalid);
            self.len = 0;
        }
    };
}

pub const TypeId = u64;

pub const Options = struct { debug_id: ?TypeId = null };
const hasDecl = @hasDecl(root, "migu_options");
pub const options: Options = if (hasDecl) root.migu_options else .{};

pub fn save(world: *const World, writer: *std.Io.Writer) !void {
    const entities = &world.entities;
    try writer.writeInt(usize, entities.versions.items.len, .little);
    try writer.writeAll(std.mem.sliceAsBytes(entities.versions.items));
    try writer.writeInt(u16, @intCast(entities.deleted.items.len), .little);
    try writer.writeAll(std.mem.sliceAsBytes(entities.deleted.items));

    try writer.writeInt(u32, world.map.count(), .little);
    var iterator = world.map.iterator();
    while (iterator.next()) |entry| {
        const store = entry.value_ptr;
        try writer.writeInt(TypeId, entry.key_ptr.*, .little);
        try writer.writeInt(u16, store.len, .little);
        try writer.writeInt(u16, store.identity, .little);
        try writer.writeInt(u16, store.valueSize, .little);
        try writer.writeInt(u8, @backingInt(store.alignment), .little);
        const count: u16 = if (store.denseCap == 0) 0 else store.len;
        try writer.writeInt(usize, count, .little);
        try writer.writeAll(std.mem.sliceAsBytes(store.dense[0..count]));
        const size = @as(usize, store.len) * store.valueSize;
        try writer.writeInt(usize, size, .little);
        try writer.writeAll(store.values[0..size]);
    }
}

pub fn load(gpa: Allocator, reader: *std.Io.Reader) !World {
    var world = World.init(gpa);
    errdefer world.deinit();

    const entities = &world.entities;
    const entityCount = try reader.takeInt(usize, .little);
    try entities.versions.ensureTotalCapacityPrecise(gpa, entityCount);
    try entities.versions.resize(gpa, entityCount);
    try reader.readSliceAll(std.mem.sliceAsBytes(entities.versions.items));
    try entities.deleted.ensureTotalCapacityPrecise(gpa, entityCount);
    try entities.deleted.resize(gpa, try reader.takeInt(u16, .little));
    try reader.readSliceAll(std.mem.sliceAsBytes(entities.deleted.items));

    for (0..try reader.takeInt(u32, .little)) |_| {
        const id = try reader.takeInt(TypeId, .little);
        const store = (try world.map.getOrPut(gpa, id)).value_ptr;
        store.* = .{};
        store.len = try reader.takeInt(u16, .little);
        store.identity = try reader.takeInt(u16, .little);
        store.valueSize = try reader.takeInt(u16, .little);
        const alignment = try reader.takeInt(u8, .little);
        store.alignment = @fromBackingInt(@intCast(alignment));
        store.values = @ptrFromInt(store.alignment.toByteUnits());

        const dense = try gpa.alloc(u16, try reader.takeInt(usize, .little));
        store.dense, store.denseCap = .{ dense.ptr, @intCast(dense.len) };
        try reader.readSliceAll(std.mem.sliceAsBytes(dense));
        if (dense.len != 0) {
            const count = @as(usize, std.mem.max(u16, dense)) + 1;
            try store.growSparse(gpa, count);
            for (dense, 0..) |e, i| store.sparse[e] = @intCast(i);
        }

        const size = try reader.takeInt(usize, .little);
        if (store.valueSize == 0) store.valueCap = invalid;
        if (size == 0) continue;
        store.values = gpa.rawAlloc(size, store.alignment, //
            @returnAddress()) orelse return error.OutOfMemory;
        store.valueCap = store.len;
        try reader.readSliceAll(store.values[0..size]);
    }
    return world;
}

pub const World = struct {
    allocator: Allocator,
    entities: Entities = .{},
    map: std.AutoHashMapUnmanaged(TypeId, Store(u8, .component)) = .empty,

    fn id(T: type, comptime kind: Kind) TypeId {
        const hash = std.hash.Fnv1a_64.hash;
        const value = comptime switch (kind) {
            .component => typeId(T),
            .event => hash(std.fmt.comptimePrint("e{d}", .{typeId(T)})),
            .resource => hash(std.fmt.comptimePrint("r{d}", .{typeId(T)})),
        };
        const builtin = @import("builtin");
        if (builtin.mode != .debug) return value;
        _ = struct {
            const Type = T;
            const category = kind;
            const marker: u8 = 0;
            comptime {
                const print = std.fmt.comptimePrint;
                if (options.debug_id == value) {
                    @compileLog(print("MiGu {s} ID {d}: {s}", .{
                        @tagName(kind), value, @typeName(T),
                    }));
                }
                @export(&marker, .{
                    .name = print("migu_id_{d}", .{value}),
                    .visibility = .hidden,
                });
            }
        };
        return value;
    }

    pub fn init(allocator: std.mem.Allocator) World {
        comptime std.debug.assert(@sizeOf(Store(u8, .component)) <= 64);
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

    pub fn resetKeepResources(self: *World, Types: anytype) void {
        self.tryResetKeepResources(Types) catch @panic("oom");
    }

    pub fn tryResetKeepResources(self: *World, Types: anytype) Oom!void {
        var new = World.init(self.allocator);
        try new.map.ensureTotalCapacity(new.allocator, Types.len);
        inline for (Types) |T| {
            if (self.map.fetchRemove(id(T, .resource))) |r| {
                new.map.putAssumeCapacityNoClobber(r.key, r.value);
            }
        }
        self.deinit();
        self.* = new;
    }

    pub fn tryCreateEntity(self: *World) EntityError!u16 {
        return self.entities.create(self.allocator);
    }

    pub fn trySetIdentity(self: *World, entity: u16, T: type) Oom!void {
        (try self.tryAssure(T, .component)).identity = entity;
    }

    pub fn tryAddEvent(self: *World, value: anytype) EventError!void {
        if (@TypeOf(value) == type) @compileError("use T{} instead of T");
        var map = try self.tryAssure(@TypeOf(value), .event);
        if (map.len == invalid) return error.MaxEvent;
        try map.appendValue(self.allocator, value);
    }

    pub fn tryAddResource(self: *World, value: anytype) Oom!void {
        if (@TypeOf(value) == type) @compileError("use T{} instead of T");
        const T = @TypeOf(value);
        var map = try self.tryAssure(T, .resource);
        if (map.len == 0) {
            try map.appendValue(self.allocator, value);
        } else {
            map.values[0] = value;
        }
    }

    pub fn tryAdd(self: *World, entity: u16, value: anytype) Oom!void {
        if (@TypeOf(value) == type) @compileError("use T{} instead of T");
        var map = try self.tryAssure(@TypeOf(value), .component);
        try map.add(self.allocator, entity, value);
    }

    fn tryAssure(self: *World, T: type, comptime k: Kind) Oom!*Store(T, k) {
        const result = try self.map.getOrPut(self.allocator, id(T, k));
        const map: *Store(T, k) = @ptrCast(@alignCast(result.value_ptr));
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
        while (toDestroy.next()) |row| self.destroyEntity(row.entity);
    }

    pub fn setIdentity(self: *World, entity: u16, T: type) void {
        self.trySetIdentity(entity, T) catch @panic("oom");
    }

    pub fn createIdentity(self: *World, T: type) u16 {
        const entity = self.createEntity();
        self.setIdentity(entity, T);
        return entity;
    }

    pub fn getIdentityEntity(self: *World, T: type) ?u16 {
        const map = self.getStore(T, .component) orelse return null;
        return if (map.identity == invalid) null else map.identity;
    }

    pub fn getIdentity(self: *World, I: type, T: ?type) ?(T orelse I) {
        return if (self.getIdentityPtr(I, T)) |v| v.* else null;
    }

    pub fn getIdentityPtr(self: *World, I: type, T: ?type) ?*(T orelse I) {
        const entity = self.getIdentityEntity(I) orelse return null;
        return self.getPtr(entity, T orelse I);
    }

    pub fn takeIdentity(self: *World, T: type) ?u16 {
        const entity = self.getIdentityEntity(T);
        self.removeIdentity(T);
        return entity;
    }

    pub fn isIdentity(self: *World, entity: u16, T: type) bool {
        return if (self.getIdentityEntity(T)) |e| e == entity else false;
    }

    pub fn hasIdentity(self: *World, T: type) bool {
        return self.getIdentityEntity(T) != null;
    }

    pub fn removeIdentity(self: *World, T: type) void {
        if (self.getStore(T, .component)) |map| map.identity = invalid;
    }

    pub fn addEvent(self: *World, value: anytype) void {
        self.tryAddEvent(value) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
            error.MaxEvent => @panic("ecs max event"),
        };
    }

    pub fn getEvent(self: *World, T: type) []T {
        const map = self.getStore(T, .event) orelse return &.{};
        return map.values[0..map.len];
    }

    pub fn clearEvent(self: *World, T: type) void {
        if (self.getStore(T, .event)) |map| map.clear();
    }

    pub fn removeEvent(self: *World, T: type) void {
        var removed = self.map.fetchRemove(id(T, .event));
        if (removed) |*r| r.value.deinit(self.allocator);
    }

    pub fn addResource(self: *World, value: anytype) void {
        self.tryAddResource(value) catch @panic("oom");
    }

    pub fn getResourcePtr(self: *World, T: type) ?*T {
        const map = self.getStore(T, .resource) orelse return null;
        return if (map.len == 0) null else &map.values[0];
    }

    pub fn removeResource(self: *World, T: type) void {
        var removed = self.map.fetchRemove(id(T, .resource));
        if (removed) |*r| r.value.deinit(self.allocator);
    }

    fn getStore(self: *World, T: type, comptime kind: Kind) ?*Store(T, kind) {
        const map = self.map.getPtr(id(T, kind)) orelse return null;
        return @ptrCast(@alignCast(map));
    }

    pub fn has(self: *World, entity: u16, T: type) bool {
        const map = self.getStore(T, .component) orelse return false;
        return hasEntity(map.sparse, entity);
    }

    pub fn get(self: *World, entity: u16, T: type) ?T {
        return if (self.getPtr(entity, T)) |ptr| ptr.* else null;
    }

    pub fn getPtr(self: *World, entity: u16, T: type) ?*T {
        const map = self.getStore(T, .component) orelse return null;
        if (!hasEntity(map.sparse, entity)) return null;
        return &map.values[map.sparse[entity]];
    }

    pub fn add(self: *World, entity: u16, value: anytype) void {
        self.tryAdd(entity, value) catch @panic("oom");
    }

    pub fn addAll(self: *World, entity: u16, bundle: anytype) void {
        inline for (bundle) |value| self.add(entity, value);
    }

    pub fn values(self: *World, T: type) []T {
        const map = self.getStore(T, .component) orelse return &.{};
        return map.values[0..map.len];
    }

    pub fn sort(self: *World, T: type, lessFn: fn (T, T) bool) void {
        if (self.getStore(T, .component)) |map| map.sort(lessFn);
    }

    pub fn remove(self: *World, entity: u16, T: type) void {
        if (self.getStore(T, .component)) |map| map.remove(entity);
    }

    pub fn removeAll(self: *World, entity: u16) void {
        var iterator = self.map.valueIterator();
        while (iterator.next()) |map| {
            map.remove(entity);
            if (map.identity == entity) map.identity = invalid;
        }
    }

    pub fn clear(self: *World, T: type) void {
        if (self.getStore(T, .component)) |map| map.clear();
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
        var minCount: usize = std.math.maxInt(usize);
        inline for (All, &result.sparse, &result.values) |T, *s, *v| {
            const map = self.getStore(T, .component) orelse return .{};
            s.*, v.* = .{ map.sparse, @ptrCast(map.values) };
            if (map.len < minCount) {
                minCount = map.len;
                result.dense = map.dense[0..map.len];
            }
        }
        inline for (None, &result.none) |T, *none| {
            if (self.getStore(T, .component)) |s| none.* = s.sparse;
        }
        return result;
    }

    // zig fmt: off
    pub fn queryBy(self: *World, By: type, All: anytype,
        None: anytype) Query(.{By} ++ All, None) {
    // zig fmt: on
        var rs: Query(.{By} ++ All, None) = .{};
        const by = self.getStore(By, .component) orelse return rs;
        rs.dense = by.dense[0..by.len];

        inline for (.{By} ++ All, &rs.sparse, &rs.values) |T, *s, *v| {
            const map = self.getStore(T, .component) orelse return .{};
            s.*, v.* = .{ map.sparse, @ptrCast(map.values) };
        }
        inline for (None, &rs.none) |T, *none| {
            if (self.getStore(T, .component)) |s| none.* = s.sparse;
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

        pub fn next(self: *@This()) ?Row {
            blk: while (self.index < self.dense.len) {
                const index = self.index;
                const entity = self.dense[index];
                if (self.reversed) self.index -%= 1 else self.index += 1;
                for (self.none) |sparse| {
                    if (hasEntity(sparse, entity)) continue :blk;
                }
                var row: Row = .{ .entity = entity };
                if (comptime All.len == 1 and None.len == 0) {
                    const value = self.values[0];
                    const items: [*]All[0] = @ptrCast(@alignCast(value));
                    row.values[0] = @ptrCast(&items[index]);
                    return row;
                }
                inline for (All, 0..) |T, i| {
                    const sparse = self.sparse[i];
                    if (entity >= sparse.len) continue :blk;
                    if (sparse[entity] == invalid) continue :blk;
                    const items: [*]T = @ptrCast(@alignCast(self.values[i]));
                    row.values[i] = @ptrCast(&items[sparse[entity]]);
                }
                return row;
            } else return null;
        }

        pub fn add(_: *@This(), world: *World, e: u16, v: anytype) void {
            const inQuery = inline for (All ++ None) |C| {
                if (C == @TypeOf(v)) break true;
            } else false;
            if (inQuery) std.debug.assert(world.has(e, @TypeOf(v)));
            world.add(e, v);
        }

        pub fn get(self: *const @This(), entity: Entity, T: type) T {
            return self.getPtr(entity, T).*;
        }

        pub fn getPtr(self: *const @This(), entity: Entity, T: type) *T {
            const i = blk: inline for (All, 0..) |Comp, i| {
                if (Comp == T) break :blk i;
            } else @compileError(@typeName(T) ++ " is not in query type");
            const values: [*]T = @ptrCast(@alignCast(self.values[i]));
            return &values[self.sparse[i][entity]];
        }

        pub const Row = struct {
            entity: Entity,
            values: [All.len]*anyopaque = undefined,

            pub fn get(self: @This(), T: type) T {
                return self.getPtr(T).*;
            }

            pub fn getPtr(self: @This(), T: type) *T {
                const i = blk: inline for (All, 0..) |Comp, i| {
                    if (Comp == T) break :blk i;
                } else @compileError(@typeName(T) ++ " is not in query type");
                return @ptrCast(@alignCast(self.values[i]));
            }
        };
    };
}

pub fn typeId(T: type) TypeId {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "cid")) return T.cid;
        },
        else => {},
    }
    return comptime std.hash.Fnv1a_64.hash(@typeName(T));
}
