# MiGu

[中文说明](README.zh-CN.md)

MiGu is a tiny ECS for Zig.

> [!WARNING]
> Under development. API stability is not guaranteed.

Requires Zig 0.17.1 or newer. Run tests with `zig build test` or
`zig build test -Doptimize=safe`.

It is designed for small single-threaded games and tools. Entity ids are
`u16`, so the maximum entity count is limited.

The name comes from MiGu (迷毂), a plant from ShanHaiJing, also known as
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
    while (query.next()) |row| {
        const velocity = row.get(Velocity);
        const position = row.getPtr(Position);

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

## Component

```zig
const Position = struct { x: f32, y: f32 };
const Player = struct {};
```

Add components:

```zig
world.add(entity, Position{ .x = 1, .y = 2 });
world.add(entity, Player{});
world.addMany(entity, .{ Position{ .x = 1, .y = 2 }, Player{} });
```

Read components:

```zig
const position = world.get(entity, Position).?;
const position_ptr = world.getPtr(entity, Position).?;
```

Remove components:

```zig
world.remove(entity, Player);
world.removeMany(entity, .{ Position, Player });
```

## Component ID

IDs are assigned automatically. To use a fixed ID, declare `cid` in the type:

```zig
const Position = struct {
    pub const cid: ecs.TypeId = 1001;

    x: f32,
    y: f32,
};
```

Use a unique `cid` for each type and keep it when renaming or moving the type.

## Query

Use `query` for entities that have all requested components.

```zig
var query = world.query(.{ Position, Velocity });
while (query.next()) |row| {
    const position = row.getPtr(Position);
    const velocity = row.get(Velocity);
    _ = .{ position, velocity };
}
```

For a known entity, use `query.get(entity, T)` or `query.getPtr(entity, T)`.
All required component stores must exist, and the entity must have `T`.
These methods do not recheck query filters.

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
while (query.next()) |row| {
    world.destroyEntity(row.entity);
}
```

Use `query.add` to safely add components while iterating.

```zig
fn markIdle(world: *ecs.World) void {
    var query = world.query(.{ Position, Velocity });
    while (query.next()) |row| {
        if (row.get(Velocity).x == 0) {
            query.add(world, row.entity, Idle{});
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
    const position = world.getIdentity(Player, Position) orelse return;

    camera.x = position.x;
    camera.y = position.y;
}

fn createPlayer(world: *ecs.World) void {
    const player = world.createIdentity(Player);
    world.add(player, Position{ .x = 10, .y = 20 });
}
```

It does not create a component automatically. It only records the entity id.

## Handle

Use `Entity` directly by default. Use `Handle` only when an entity may be
destroyed and its id may be reused later.

```zig
const enemy = world.createEntity();
const handle = world.entities.to(enemy);

world.destroyEntity(enemy);

if (world.entities.get(handle)) |alive| {
    world.add(alive, Target{});
}
```

## Resource

A resource is one value owned by a `World`, with no entity. Resources and
components of the same type are stored separately. Adding a resource again
replaces its value.

```zig
const Clock = struct { hour: u8 = 6 };
const Inventory = struct { gold: u32 = 0 };

var world = ecs.World.init(allocator);
defer world.deinit();

world.addResource(Clock{});
world.addResource(Inventory{});

const clock = world.getResourcePtr(Clock).?;
clock.hour += 1;
world.removeResource(Inventory);
```

When resetting a world, `resetKeepResources` keeps resources of the selected
types. Components are cleared.

```zig
world.resetKeepResources(.{ Clock, Inventory });
```

## Event

Events are typed queues. They are not cleared automatically.

```zig
const SoundPlay = struct { id: u8 };

world.addEvent(SoundPlay{ .id = 1 });

for (world.getEvent(SoundPlay)) |event| {
    playSound(event.id);
}

world.clearEvent(SoundPlay);
```

## ID Conflict

Debug builds detect store ID conflicts at compile time.

To find the types behind a conflicting store ID, set `migu_options`
in your root file and compile again in Debug mode:

```zig
pub const migu_options: ecs.Options = .{ .debug_id = 7 };
```

Matching IDs print their type names and store kinds through `@compileLog`.
This stops compilation; remove the option after checking the output.

## Notes

- `Entity` is `u16`, supporting up to 65535 entities.
- A `Handle` version wraps after 32768 reuses of the same entity ID.
- Discard old handles after resetting the world, as version data is cleared.
- Each event type holds up to 65535 events.
- `createEntity`, `add`, `addEvent`, and `addResource` panic on allocation failure.
- Use `tryCreateEntity`, `tryAdd`, `tryAddEvent`, and `tryAddResource` when you
  need errors.
- Component pointers may be invalidated by storage growth, removal, or sorting.
- Sorting uses insertion sort, suited to mostly sorted data processed each frame.
- A type alias is not a new component type.

```zig
const Name = struct {};
const PlayerName = Name;

// Name and PlayerName are the same component type.
```

## Acknowledgements

MiGu is heavily inspired by [EnTT](https://github.com/skypjack/entt) and
[zig-ecs](https://github.com/prime31/zig-ecs). Thanks to both projects.

## License

MIT
