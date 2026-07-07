# MiGu

[中文说明](README.zh-CN.md)

MiGu is a tiny ECS for Zig.

It keeps the model simple: entities are `u16` ids, components are plain Zig
types, systems are normal functions, and queries iterate sparse-set component
storage directly.

The name comes from MiGu(迷毂), a beast in ShanHaiJing, also known as
Classic of Mountains and Rivers.

## Install

Fetch MiGu in your project:

```sh
zig fetch --save=migu git+https://github.com/jiangbo/MiGu.git
```

Then import the module in `build.zig`:

```zig
const migu = b.dependency("migu", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("ecs", migu.module("ecs"));
```

Then import it in code:

```zig
const ecs = @import("ecs");
```

## Basic Example

```zig
const std = @import("std");
const ecs = @import("ecs");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0 };

fn move(world: *ecs.World, delta: f32) void {
    var query = world.query(.{ Position, Velocity });
    while (query.next()) |entity| {
        const velocity = query.get(entity, Velocity);
        const position = query.getPtr(entity, Position);

        position.x += velocity.x * delta;
        position.y += velocity.y * delta;
    }
}

test "move entity" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position{ .x = 10, .y = 20 });
    world.add(entity, Velocity{ .x = 5, .y = -2 });

    move(&world, 2);

    const position = world.get(entity, Position).?;
    try std.testing.expectEqual(20, position.x);
    try std.testing.expectEqual(16, position.y);
}
```

## Components

```zig
const Position = struct { x: f32, y: f32 };
const Player = struct {};
```

Add components:

```zig
world.add(entity, Position{ .x = 1, .y = 2 });
world.add(entity, Player{});
```

Read components:

```zig
const position = world.get(entity, Position).?;
const position_ptr = world.getPtr(entity, Position).?;
```

Remove components:

```zig
world.remove(entity, Player);
```

## Queries

Use `query` for entities that have all requested components.

```zig
var query = world.query(.{ Position, Velocity });
while (query.next()) |entity| {
    const position = query.getPtr(entity, Position);
    const velocity = query.get(entity, Velocity);
    _ = .{ position, velocity };
}
```

Use `queryNot` to exclude components.

```zig
var query = world.queryNot(.{ Position, Sprite }, .{Hidden});
```

Use `queryBy` when iteration order must follow a specific component store.

```zig
world.sort(Render, lessThanRender);

var query = world.queryBy(Render, .{ Position, Sprite }, .{Hidden});
```

Use `reverse` for destructive passes.

```zig
var query = world.query(.{ Dead }).reverse();
while (query.next()) |entity| {
    world.destroyEntity(entity);
}
```

Use `query.add` to safely add components while iterating. It asserts if the
new component is part of the current query.

```zig
fn markIdle(world: *ecs.World) void {
    var query = world.query(.{ Position, Velocity });
    while (query.next()) |entity| {
        if (query.get(entity, Velocity).x == 0) {
            query.add(world, entity, Idle{});
        }
    }
}
```

## Identity

An identity stores one entity for a type, such as the player.

```zig
const Player = struct {};
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Camera = struct { x: f32 = 0, y: f32 = 0 };

fn followPlayer(world: *ecs.World, camera: *Camera) void {
    const player = world.getIdentity(Player) orelse return;
    const position = world.get(player, Position) orelse return;

    camera.x = position.x;
    camera.y = position.y;
}

const player = world.createIdentity(Player);
world.add(player, Position{ .x = 10, .y = 20 });
```

It does not create a component automatically. It only records the entity id.

## Handle

Use `Entity` directly by default. Use `Handle` only when an entity may be
destroyed and its id may be reused later.

```zig
const enemy = world.createEntity();
const handle = world.entities.to(enemy).?;

world.destroyEntity(enemy);

if (world.entities.get(handle)) |alive| {
    world.add(alive, Target{});
}
```

## Resource

`world.entity` is an optional entity slot. One simple resource pattern is to
create one entity for global components.
If you use this pattern, create it right after `World.init`.

```zig
const Clock = struct { hour: u8 = 6 };
const Inventory = struct { gold: u32 = 0 };

var world = ecs.World.init(allocator);
defer world.deinit();

world.entity = world.createEntity();
world.add(world.entity, Clock{});
world.add(world.entity, Inventory{});

const clock = world.getPtr(world.entity, Clock).?;
clock.hour += 1;
```

When resetting a world, `resetKeep` can keep selected component stores.

```zig
world.resetKeep(.{ Clock, Inventory });
world.entity = world.createEntity();
```

## Events

Events are typed queues. They are not cleared automatically.

```zig
const SoundPlay = struct { id: u8 };

world.addEvent(SoundPlay{ .id = 1 });

for (world.getEvent(SoundPlay)) |event| {
    playSound(event.id);
}

world.clearEvent(SoundPlay);
```

## Notes

- `Entity` is `u16`.
- `createEntity`, `add`, and `addEvent` panic on allocation failure.
- Use `tryCreateEntity`, `tryAdd`, and `tryAddEvent` when you need errors.

## Acknowledgements

MiGu is heavily inspired by [EnTT](https://github.com/skypjack/entt) and
[zig-ecs](https://github.com/prime31/zig-ecs). Thanks to both projects.

## License

MIT
