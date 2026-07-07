# MiGu

MiGu 是一个小型 Zig ECS。

它保持简单模型：实体是 `u16` 编号，组件是普通 Zig 类型，系统是普通
函数，查询直接遍历 sparse set 组件存储。

名字来自《山海经》中的迷毂。

## 安装

把 MiGu 加到项目的 `build.zig.zon`，然后在 `build.zig` 里导入模块。

```zig
const migu = b.dependency("migu", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("ecs", migu.module("ecs"));
```

代码中这样引入：

```zig
const ecs = @import("ecs");
```

## 基础例子

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
    world.add(entity, Velocity{ .x = 5 });

    move(&world, 2);

    const position = world.get(entity, Position).?;
    try std.testing.expectEqual(20, position.x);
    try std.testing.expectEqual(20, position.y);
}
```

## 组件

```zig
const Position = struct { x: f32, y: f32 };
const Player = struct {};
```

添加组件：

```zig
world.add(entity, Position{ .x = 1, .y = 2 });
world.add(entity, Player{});
```

读取组件：

```zig
const position = world.get(entity, Position).?;
const position_ptr = world.getPtr(entity, Position).?;
```

删除组件：

```zig
world.remove(entity, Player);
```

## 查询

`query` 查询同时拥有所有指定组件的实体。

```zig
var query = world.query(.{ Position, Velocity });
while (query.next()) |entity| {
    const position = query.getPtr(entity, Position);
    const velocity = query.get(entity, Velocity);
    _ = .{ position, velocity };
}
```

`queryNot` 用来排除组件。

```zig
var query = world.queryNot(.{ Position, Sprite }, .{Hidden});
```

需要固定遍历顺序时，使用 `queryBy`。

```zig
world.sort(Render, lessThanRender);

var query = world.queryBy(Render, .{ Position, Sprite }, .{Hidden});
```

反向遍历适合删除实体。

```zig
var query = world.query(.{ Dead }).reverse();
while (query.next()) |entity| {
    world.destroyEntity(entity);
}
```

遍历时用 `query.add` 安全添加组件。如果新组件属于当前查询，会触发断言并暴露错误。

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

`Identity` 用来记录某种类型对应的唯一实体，比如玩家。

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

它不会自动创建组件，只记录实体编号。

## Handle

默认直接使用 `Entity`。只有实体可能被销毁，并且编号可能被复用时，才使用 `Handle`。

```zig
const enemy = world.createEntity();
const handle = world.entities.to(enemy).?;

world.destroyEntity(enemy);

if (world.entities.get(handle)) |alive| {
    world.add(alive, Target{});
}
```

## Resource

`world.entity` 是一个可选的实体槽位。一种简单的资源写法是创建一个
实体，用它挂全局组件。
如果使用这种写法，最好在 `World.init` 后立刻创建它。

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

## 事件

事件是按类型存储的队列，不会自动清空。

```zig
const SoundPlay = struct { id: u8 };

world.addEvent(SoundPlay{ .id = 1 });

for (world.getEvent(SoundPlay)) |event| {
    playSound(event.id);
}

world.clearEvent(SoundPlay);
```

## 注意事项

- `Entity` 是 `u16`。
- `createEntity`、`add`、`addEvent` 遇到分配失败会 panic。
- 需要处理错误时，使用 `tryCreateEntity`、`tryAdd`、
  `tryAddEvent`。

## 许可证

MIT
