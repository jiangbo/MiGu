const std = @import("std");
const ecs = @import("ecs");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0 };
const Player = struct {};
const Enemy = struct {};
const Hidden = struct {};
const Dead = struct {};
const Idle = struct {};
const Clock = struct { hour: u8 = 6 };
const Inventory = struct { gold: u32 = 0 };
const Text = []const u8;

const Render = struct { layer: u8 = 0, depth: f32 = 0 };
const SoundPlay = struct { id: u8 };

test "explicit component id and separate resource and event stores" {
    const Value = struct {
        pub const cid: ecs.TypeId = 1001;
        value: u32,
    };

    try std.testing.expectEqual(@as(ecs.TypeId, 1001), ecs.typeId(Value));
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Value{ .value = 10 });
    world.addResource(Value{ .value = 20 });
    world.addEvent(Value{ .value = 30 });

    try std.testing.expectEqual(10, world.get(entity, Value).?.value);
    try std.testing.expectEqual(20, world.getResourcePtr(Value).?.value);
    const events = world.getEvent(Value);
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(30, events[0].value);

    world.removeEvent(Value);
    world.removeResource(Value);
    try std.testing.expectEqual(10, world.get(entity, Value).?.value);
}

test "create entity and add get remove component" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position{ .x = 10, .y = 20 });

    try std.testing.expect(world.has(entity, Position));
    try std.testing.expectEqual(10, world.get(entity, Position).?.x);

    world.getPtr(entity, Position).?.x = 30;
    try std.testing.expectEqual(30, world.get(entity, Position).?.x);

    world.remove(entity, Position);
    try std.testing.expect(!world.has(entity, Position));
}

test "storage keeps values after growth" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    for (0..128) |i| {
        const entity = world.createEntity();
        const value: f32 = @floatFromInt(i);
        world.add(entity, Position{ .x = value, .y = -value });
        world.addEvent(SoundPlay{ .id = @intCast(i) });
    }

    for (0..128) |i| {
        const position = world.get(@intCast(i), Position).?;
        const value: f32 = @floatFromInt(i);
        try std.testing.expectEqual(value, position.x);
        try std.testing.expectEqual(-value, position.y);
    }

    var query = world.query(.{Position});
    var count: usize = 0;
    while (query.next() != null) count += 1;
    try std.testing.expectEqual(128, count);

    const events = world.getEvent(SoundPlay);
    try std.testing.expectEqual(128, events.len);
    for (events, 0..) |event, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), event.id);
    }
}

test "query entry points accept const world" {
    var worldMut = ecs.World.init(std.testing.allocator);
    defer worldMut.deinit();

    const entity = worldMut.createEntity();
    worldMut.add(entity, Position{ .x = 10 });
    const world: *const ecs.World = &worldMut;

    var query = world.query(.{Position});
    query.next().?.getPtr(Position).x = 20;
    var filtered = world.queryNot(.{Position}, .{Hidden});
    try std.testing.expectEqual(entity, filtered.next().?.entity);
    var ordered = world.queryBy(Position, .{}, .{});
    const position = ordered.next().?.getPtr(Position);
    try std.testing.expect(@TypeOf(position) == *Position);
    try std.testing.expectEqual(20, position.x);
}

test "add many and query components" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.addMany(entity, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });

    var query = world.query(.{ Position, Velocity });
    const found = query.next().?;

    try std.testing.expectEqual(entity, found.entity);
    try std.testing.expectEqual(1, found.get(Position).x);
    try std.testing.expectEqual(3, found.get(Velocity).x);
    try std.testing.expectEqual(null, query.next());
}

test "remove many keeps other components and entities" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    const second = world.createEntity();
    world.addMany(first, .{ Position{ .x = 1 }, Velocity{}, Player{} });
    world.addMany(second, .{ Position{ .x = 2 }, Velocity{} });
    world.setIdentity(first, Player);

    world.removeMany(first, .{ Position, Hidden, Velocity });

    try std.testing.expect(!world.has(first, Position));
    try std.testing.expect(!world.has(first, Velocity));
    try std.testing.expect(world.has(first, Player));
    try std.testing.expectEqual(first, world.getIdentity(Player).?);
    try std.testing.expectEqual(2, world.get(second, Position).?.x);
    try std.testing.expect(world.has(second, Velocity));
}

test "query not excludes components after removal" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    const second = world.createEntity();
    const third = world.createEntity();
    world.add(first, Position{ .x = 10 });
    world.add(second, Position{ .x = 20 });
    world.add(third, Position{ .x = 30 });
    world.add(second, Velocity{ .x = 2 });
    world.add(third, Velocity{ .x = 3 });
    world.add(third, Hidden{});
    world.remove(first, Position);

    var query = world.queryNot(.{ Position, Velocity }, .{Hidden});
    const row = query.next().?;
    try std.testing.expectEqual(second, row.entity);
    try std.testing.expectEqual(20, row.get(Position).x);
    try std.testing.expectEqual(2, row.get(Velocity).x);
    try std.testing.expectEqual(null, query.next());
}

test "query supports slice component" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, @as(Text, "hello"));

    var query = world.query(.{Text});
    const found = query.next().?;
    try std.testing.expectEqualStrings("hello", found.get(Text));

    var queryBy = world.queryBy(Text, .{}, .{});
    const ordered = queryBy.next().?;
    try std.testing.expectEqualStrings("hello", ordered.get(Text));
}

test "query not excludes component" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const visible = world.createEntity();
    world.add(visible, Position{});

    const hidden = world.createEntity();
    world.add(hidden, Position{});
    world.add(hidden, Hidden{});

    var query = world.queryNot(.{Position}, .{Hidden});
    try std.testing.expectEqual(visible, query.next().?.entity);
    try std.testing.expectEqual(null, query.next());
}

test "query add permits unrelated component" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position{});
    world.add(entity, Velocity{});

    var query = world.query(.{ Position, Velocity });
    const found = query.next().?;
    query.add(&world, found.entity, Idle{});

    try std.testing.expect(world.has(found.entity, Idle));
}

test "reverse query can destroy matching entities" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    world.add(first, Dead{});

    const second = world.createEntity();
    world.add(second, Dead{});

    var query = world.query(.{Dead}).reverse();
    while (query.next()) |row| {
        world.destroyEntity(row.entity);
    }

    try std.testing.expect(!world.has(first, Dead));
    try std.testing.expect(!world.has(second, Dead));
}

test "identity stores one entity for type" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    try std.testing.expectEqual(null, world.getIdentity(Player));
    try std.testing.expectEqual(null, world.getByIdentity(Player, Position));
    try std.testing.expectEqual(null, world.takeIdentity(Player));

    const player = world.createIdentity(Player);
    try std.testing.expectEqual(player, world.getIdentity(Player).?);
    try std.testing.expectEqual(null, world.getByIdentity(Player, Position));
    world.addMany(player, .{
        Player{},
        Position{ .x = 5 },
    });

    try std.testing.expectEqual(player, world.getIdentity(Player).?);
    try std.testing.expectEqual(5, world.getByIdentity(Player, Position).?.x);

    const taken = world.takeIdentity(Player).?;
    try std.testing.expectEqual(player, taken);
    try std.testing.expectEqual(null, world.takeIdentity(Player));
    try std.testing.expectEqual(null, world.getByIdentity(Player, Position));

    world.setIdentity(player, Player);
    world.removeIdentity(Player);
    try std.testing.expectEqual(null, world.getIdentity(Player));
}

test "remove all keeps identities and destroy clears them" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createIdentity(Player);
    world.setIdentity(first, Hidden);
    world.addMany(first, .{ Player{}, Position{} });
    const second = world.createIdentity(Enemy);

    world.removeAll(first);
    try std.testing.expect(!world.has(first, Player));
    try std.testing.expect(!world.has(first, Position));
    try std.testing.expectEqual(first, world.getIdentity(Player).?);
    try std.testing.expectEqual(first, world.getIdentity(Hidden).?);

    world.add(first, Position{});
    world.destroyEntity(first);
    try std.testing.expect(!world.has(first, Position));
    try std.testing.expectEqual(null, world.getIdentity(Player));
    try std.testing.expectEqual(null, world.getIdentity(Hidden));
    try std.testing.expectEqual(second, world.getIdentity(Enemy).?);
    try std.testing.expectEqual(first, world.createEntity());
    try std.testing.expectEqual(null, world.getIdentity(Player));
    try std.testing.expectEqual(null, world.getIdentity(Hidden));
}

test "events are stored and cleared by type" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    world.addEvent(SoundPlay{ .id = 1 });
    world.addEvent(SoundPlay{ .id = 2 });

    const sounds = world.getEvent(SoundPlay);
    try std.testing.expectEqual(2, sounds.len);
    try std.testing.expectEqual(1, sounds[0].id);
    try std.testing.expectEqual(2, sounds[1].id);

    world.clearEvent(SoundPlay);
    try std.testing.expectEqual(0, world.getEvent(SoundPlay).len);

    world.addEvent(SoundPlay{ .id = 3 });
    world.removeEvent(SoundPlay);
    try std.testing.expectEqual(0, world.getEvent(SoundPlay).len);
}

test "values clear and remove all components" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    world.add(first, Position{ .x = 1 });
    world.add(first, Velocity{ .x = 2 });

    const second = world.createEntity();
    world.add(second, Position{ .x = 3 });

    try std.testing.expectEqual(2, world.values(Position).len);

    world.removeAll(first);
    try std.testing.expect(!world.has(first, Position));
    try std.testing.expect(!world.has(first, Velocity));
    try std.testing.expectEqual(1, world.values(Position).len);

    world.clear(Position);
    try std.testing.expectEqual(0, world.values(Position).len);
}

test "remove except keeps listed components and other world data" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createIdentity(Player);
    world.setIdentity(first, Hidden);
    world.addMany(first, .{ Position{ .x = 1 }, Velocity{}, Player{} });
    const second = world.createEntity();
    world.addMany(second, .{ Position{ .x = 2 }, Velocity{}, Player{} });
    world.addResource(Velocity{ .x = 3 });
    world.addEvent(Player{});

    world.removeExcept(first, .{ Position, Idle });
    try std.testing.expectEqual(1, world.get(first, Position).?.x);
    try std.testing.expect(!world.has(first, Velocity));
    try std.testing.expect(!world.has(first, Player));
    try std.testing.expect(!world.has(first, Idle));
    try std.testing.expectEqual(first, world.getIdentity(Player).?);
    try std.testing.expectEqual(first, world.getIdentity(Hidden).?);
    try std.testing.expectEqual(2, world.get(second, Position).?.x);
    try std.testing.expect(world.has(second, Velocity));
    try std.testing.expect(world.has(second, Player));
    try std.testing.expectEqual(3, world.getResourcePtr(Velocity).?.x);
    try std.testing.expectEqual(1, world.getEvent(Player).len);

    world.removeExcept(first, .{});
    try std.testing.expect(!world.has(first, Position));
    try std.testing.expectEqual(first, world.getIdentity(Player).?);
    try std.testing.expectEqual(first, world.getIdentity(Hidden).?);
}

test "destroy entities removes every entity with component" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    world.add(first, Enemy{});

    const second = world.createEntity();
    world.add(second, Enemy{});

    const other = world.createEntity();
    world.add(other, Position{});

    world.destroyEntities(Enemy);

    try std.testing.expect(!world.has(first, Enemy));
    try std.testing.expect(!world.has(second, Enemy));
    try std.testing.expect(world.has(other, Position));
}

test "reset clears world" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position{});
    world.addEvent(SoundPlay{ .id = 1 });
    world.addResource(Clock{ .hour = 9 });

    world.reset();

    try std.testing.expectEqual(0, world.values(Position).len);
    try std.testing.expectEqual(0, world.getEvent(SoundPlay).len);
    try std.testing.expect(world.getResourcePtr(Clock) == null);
}

test "resource is separate from component and holds one value" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Clock{ .hour = 7 });

    try std.testing.expect(world.getResourcePtr(Clock) == null);
    world.addResource(Clock{ .hour = 9 });
    world.addResource(Clock{ .hour = 10 });
    try std.testing.expectEqual(10, world.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(7, world.get(entity, Clock).?.hour);

    world.removeResource(Clock);
    try std.testing.expect(world.getResourcePtr(Clock) == null);
    try std.testing.expectEqual(7, world.get(entity, Clock).?.hour);
}

test "reset keeps all resources and drops others" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const clockEntity = world.createEntity();
    world.add(clockEntity, Clock{ .hour = 7 });
    world.addResource(Clock{ .hour = 9 });
    world.addResource(Inventory{ .gold = 12 });

    const enemy = world.createEntity();
    world.add(enemy, Enemy{});

    world.addResource(Player{});
    world.addEvent(Clock{ .hour = 11 });
    const handle = world.entities.to(enemy);
    const clock = world.getResourcePtr(Clock).?;
    world.resetKeepResources();

    try std.testing.expectEqual(clock, world.getResourcePtr(Clock).?);
    try std.testing.expect(world.getResourcePtr(Player) != null);
    try std.testing.expectEqual(0, world.getEvent(Clock).len);
    try std.testing.expectEqual(null, world.entities.get(handle));
    try std.testing.expectEqual(0, world.createEntity());
    world.resetKeepResources();
    try std.testing.expectEqual(9, world.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(12, world.getResourcePtr(Inventory).?.gold);
    try std.testing.expectEqual(0, world.values(Clock).len);
    try std.testing.expectEqual(0, world.values(Enemy).len);
}

test "sort and query by component order" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const front = world.createEntity();
    world.add(front, Position{ .x = 20 });
    world.add(front, Render{ .layer = 1, .depth = 20 });

    const back = world.createEntity();
    world.add(back, Position{ .x = 10 });
    world.add(back, Render{ .layer = 1, .depth = 10 });

    world.sort(Render, lessThanRender);

    var query = world.queryBy(Render, .{Position}, .{});
    const backRow = query.next().?;
    try std.testing.expectEqual(back, backRow.entity);
    try std.testing.expectEqual(10, backRow.get(Position).x);
    try std.testing.expectEqual(10, backRow.get(Render).depth);
    const frontRow = query.next().?;
    try std.testing.expectEqual(front, frontRow.entity);
    try std.testing.expectEqual(20, frontRow.get(Position).x);
    try std.testing.expectEqual(20, frontRow.get(Render).depth);
    try std.testing.expectEqual(null, query.next());
}

test "handle rejects destroyed entity after id reuse" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    const handle = world.entities.to(entity);

    world.destroyEntity(entity);
    const reused = world.createEntity();

    try std.testing.expectEqual(entity, reused);
    try std.testing.expectEqual(null, world.entities.get(handle));
}

fn lessThanRender(lhs: Render, rhs: Render) bool {
    if (lhs.layer == rhs.layer) return lhs.depth < rhs.depth;
    return lhs.layer < rhs.layer;
}

test "const world can modify stored values" {
    var worldMut = ecs.World.init(std.testing.allocator);
    defer worldMut.deinit();

    const entity = worldMut.createEntity();
    worldMut.add(entity, Position{ .x = 12 });
    worldMut.setIdentity(entity, Player);
    worldMut.addResource(Position{ .x = 24 });
    worldMut.addEvent(Position{ .x = 36 });

    const world: *const ecs.World = &worldMut;
    try std.testing.expect(world.has(entity, Position));
    try std.testing.expectEqual(12, world.get(entity, Position).?.x);
    try std.testing.expectEqual(12, world.getPtr(entity, Position).?.x);
    world.getPtr(entity, Position).?.x = 18;
    try std.testing.expectEqual(18, world.get(entity, Position).?.x);
    try std.testing.expectEqual(entity, world.getIdentity(Player).?);
    try std.testing.expect(world.getPtr(entity, Velocity) == null);
    try std.testing.expectEqual(1, world.values(Position).len);
    world.values(Position)[0].x = 20;
    try std.testing.expectEqual(20, world.get(entity, Position).?.x);
    worldMut.remove(entity, Position);
    try std.testing.expectEqual(null, world.getPtr(entity, Position));
    try std.testing.expectEqual(null, world.get(entity, Position));
    try std.testing.expectEqual(0, world.values(Position).len);
    try std.testing.expectEqual(24, world.getResourcePtr(Position).?.x);
    try std.testing.expectEqual(36, world.getEvent(Position)[0].x);
    world.getEvent(Position)[0].x = 40;
    try std.testing.expectEqual(40, world.getEvent(Position)[0].x);
    world.getResourcePtr(Position).?.x = 48;
    try std.testing.expectEqual(48, world.getResourcePtr(Position).?.x);
    worldMut.removeResource(Position);
    try std.testing.expectEqual(null, world.getResourcePtr(Position));
}

test "save and load versioned world" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const removed = world.createEntity();
    const entity = world.createEntity();
    world.add(entity, Position{ .x = 12, .y = 34 });
    world.add(entity, Player{});
    world.setIdentity(entity, Player);
    world.addResource(Clock{ .hour = 9 });
    world.addEvent(SoundPlay{ .id = 7 });
    world.destroyEntity(removed);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try ecs.save(&world, &output.writer);
    var reader = std.Io.Reader.fixed(output.writer.buffered());
    var loaded = try ecs.load(std.testing.allocator, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(12, loaded.get(entity, Position).?.x);
    try std.testing.expectEqual(34, loaded.get(entity, Position).?.y);
    try std.testing.expect(loaded.has(entity, Player));
    try std.testing.expectEqual(entity, loaded.getIdentity(Player).?);
    try std.testing.expectEqual(9, loaded.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(7, loaded.getEvent(SoundPlay)[0].id);
    try std.testing.expectEqual(removed, loaded.createEntity());

    loaded.resetKeepResources();
    try std.testing.expectEqual(9, loaded.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(0, loaded.values(Position).len);
    try std.testing.expectEqual(0, loaded.getEvent(SoundPlay).len);
}

test "load rejects unsupported and incomplete versions" {
    for ([_][4]u8{ .{ 0, 0, 0, 0 }, .{ 2, 0, 0, 0 } }) |header| {
        var reader = std.Io.Reader.fixed(&header);
        const result = ecs.load(std.testing.allocator, &reader);
        try std.testing.expectError(error.UnsupportedVersion, result);
    }
    const header = [_]u8{ 1, 0, 0, 0 };
    for (0..header.len) |len| {
        var reader = std.Io.Reader.fixed(header[0..len]);
        const result = ecs.load(std.testing.allocator, &reader);
        try std.testing.expectError(error.EndOfStream, result);
    }
}
