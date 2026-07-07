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

const Render = struct { layer: u8 = 0, depth: f32 = 0 };
const SoundPlay = struct { id: u8 };

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

test "add all and query components" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.addAll(entity, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });

    var query = world.query(.{ Position, Velocity });
    const found = query.next().?;

    try std.testing.expectEqual(entity, found);
    try std.testing.expectEqual(1, query.get(found, Position).x);
    try std.testing.expectEqual(3, query.get(found, Velocity).x);
    try std.testing.expectEqual(null, query.next());
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
    try std.testing.expectEqual(visible, query.next().?);
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
    query.add(&world, found, Idle{});

    try std.testing.expect(world.has(found, Idle));
}

test "reverse query can destroy matching entities" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const first = world.createEntity();
    world.add(first, Dead{});

    const second = world.createEntity();
    world.add(second, Dead{});

    var query = world.query(.{Dead}).reverse();
    while (query.next()) |entity| {
        world.destroyEntity(entity);
    }

    try std.testing.expect(!world.has(first, Dead));
    try std.testing.expect(!world.has(second, Dead));
}

test "identity stores one entity for type" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const player = world.createIdentity(Player);
    world.add(player, Position{ .x = 5 });

    try std.testing.expectEqual(player, world.getIdentity(Player).?);
    try std.testing.expect(world.isIdentity(player, Player));
    try std.testing.expect(world.hasIdentity(Player, Position));

    const taken = world.takeIdentity(Player).?;
    try std.testing.expectEqual(player, taken);
    try std.testing.expectEqual(null, world.getIdentity(Player));

    world.addIdentity(player, Player);
    world.removeIdentity(Player);
    try std.testing.expectEqual(null, world.getIdentity(Player));
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

    world.reset();

    try std.testing.expectEqual(0, world.values(Position).len);
    try std.testing.expectEqual(0, world.getEvent(SoundPlay).len);
}

test "reset keep preserves selected component stores" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    world.entity = world.createEntity();
    world.add(world.entity, Clock{ .hour = 9 });
    world.add(world.entity, Inventory{ .gold = 12 });

    const enemy = world.createEntity();
    world.add(enemy, Enemy{});

    world.resetKeep(.{ Clock, Inventory });
    world.entity = world.createEntity();

    try std.testing.expectEqual(9, world.get(world.entity, Clock).?.hour);
    try std.testing.expectEqual(12, world.get(world.entity, Inventory).?.gold);
    try std.testing.expectEqual(0, world.values(Enemy).len);
}

test "sort and query by component order" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const front = world.createEntity();
    world.add(front, Position{});
    world.add(front, Render{ .layer = 1, .depth = 20 });

    const back = world.createEntity();
    world.add(back, Position{});
    world.add(back, Render{ .layer = 1, .depth = 10 });

    world.sort(Render, lessThanRender);

    var query = world.queryBy(Render, .{Position}, .{});
    try std.testing.expectEqual(back, query.next().?);
    try std.testing.expectEqual(front, query.next().?);
    try std.testing.expectEqual(null, query.next());
}

test "handle rejects destroyed entity after id reuse" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    const handle = world.entities.to(entity).?;

    world.destroyEntity(entity);
    const reused = world.createEntity();

    try std.testing.expectEqual(entity, reused);
    try std.testing.expectEqual(null, world.entities.get(handle));
}

fn lessThanRender(lhs: Render, rhs: Render) bool {
    if (lhs.layer == rhs.layer) return lhs.depth < rhs.depth;
    return lhs.layer < rhs.layer;
}
