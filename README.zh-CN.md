# MiGu

MiGu 是一个小型 Zig ECS。

需要 Zig 0.17.1 或更新版本。使用 `zig build test` 或
`zig build test -Doptimize=safe` 运行测试。

它面向小型单线程游戏和工具。实体编号是 `u16`，所以最大实体数量有限。

名字来自《山海经》中的迷毂。

## 安装

在你的项目里拉取 MiGu：

```sh
zig fetch --save=migu git+https://github.com/jiangbo/MiGu.git
```

然后在 `build.zig` 里导入模块：

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

## 组件 ID

默认自动生成 ID，如果想固定 ID，可以在类型内声明 `cid`：

```zig
const Position = struct {
    pub const cid: ecs.TypeId = 1001;

    x: f32,
    y: f32,
};
```

不同类型使用不同的 `cid`，改名或移动类型时保留原值。

## 查询

`query` 查询同时拥有所有指定组件的实体。

```zig
var query = world.query(.{ Position, Velocity });
while (query.next()) |row| {
    const position = row.getPtr(Position);
    const velocity = row.get(Velocity);
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
while (query.next()) |row| {
    world.destroyEntity(row.entity);
}
```

遍历时用 `query.add` 安全添加组件。如果新组件属于当前查询，会触发断言并暴露错误。

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

`Identity` 用来记录某种类型对应的唯一实体，比如玩家。

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

资源是属于 `World` 的单个值，不需要实体。同一个类型的资源和组件
分别存储，重复添加资源会替换原值。

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

重置世界时，`resetKeepResources` 只保留指定类型的资源，普通组件会清除。

```zig
world.resetKeepResources(.{ Clock, Inventory });
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

## ID 冲突

Debug 构建会在编译时检查存储 ID 冲突，测试构建跳过检查。

要定位冲突的存储 ID，在根文件配置 `migu_options`，
然后使用 Debug 模式重新编译：

```zig
pub const migu_options: ecs.Options = .{ .debug_id = 7 };
```

匹配的 ID 会通过 `@compileLog` 输出类型名和存储类别。
这会中止编译，查看输出后移除配置。

## 注意事项

- `Entity` 是 `u16`，最多支持 65535 个实体。
- 每种事件最多保存 65535 条。
- `createEntity`、`add`、`addEvent`、`addResource` 遇到分配失败会 panic。
- 需要处理错误时，使用 `tryCreateEntity`、`tryAdd`、
  `tryAddEvent`、`tryAddResource`。
- 类型别名不会产生新的组件类型。

```zig
const Name = struct {};
const PlayerName = Name;

// Name 和 PlayerName 是同一个组件类型。
```

## 致谢

MiGu 的设计灵感深受 [EnTT](https://github.com/skypjack/entt) 和
[zig-ecs](https://github.com/prime31/zig-ecs) 影响。感谢这两个项目。

## 许可证

MIT
