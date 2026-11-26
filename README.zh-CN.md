# MiGu

MiGu 是一个小型 Zig ECS。

> [!WARNING]
> 功能开发中，不保证 API 稳定性。

需要 Zig 0.17.1。使用 `zig build test` 或 `zig build test -Doptimize=safe` 运行测试。

它面向小型单线程游戏和工具。实体编号是 `u16`，所以最大实体数量有限。

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

pub fn main(init: std.process.Init) void {
    var world = ecs.World.init(init.gpa);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position{ .x = 10, .y = 20 });
    world.add(entity, Velocity{ .x = 5, .y = -2 });

    move(&world, 2);

    const position = world.get(entity, Position).?;
    std.debug.print("position: ({d}, {d})\n", .{ position.x, position.y });
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
world.addMany(entity, .{ Position{ .x = 1, .y = 2 }, Player{} });
```

读取组件：

```zig
const position = world.get(entity, Position).?;
const position_ptr = world.getPtr(entity, Position).?;
```

与 `HashMap.getPtr` 类似，MiGu 采用浅层 const：`*const World` 仍可返回
指向组件、资源和事件的可变指针或切片，`Query` 也遵循这一规则。

删除组件：

```zig
world.remove(entity, Player);
world.removeMany(entity, .{ Position, Player });
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

`query` 查询同时拥有所有必需组件的实体。

```zig
var query = world.query(.{ Position, Velocity });
while (query.next()) |row| {
    const position = row.getPtr(Position);
    const velocity = row.get(Velocity);
    _ = .{ position, velocity };
}
```

使用 `?T` 读取可选组件，查询至少需要一个必需组件。

```zig
var query = world.query(.{ Position, ?Velocity });
while (query.next()) |row| {
    if (row.get(?Velocity)) |velocity| {
        row.getPtr(Position).x += velocity.x;
    }
}
```

`queryNot` 用来排除组件。

```zig
var query = world.queryNot(.{ Position, Sprite }, .{Hidden});
```

需要固定遍历顺序时，使用 `queryBy`。

```zig
world.sort(Render, {}, lessThanRender);

var query = world.queryBy(Render, .{ Position, Sprite }, .{Hidden});
```

反向遍历适合删除实体。

```zig
var query = world.query(.{ Dead }).reverse();
while (query.next()) |row| {
    world.destroyEntity(row.entity);
}
```

遍历时，只用 `query.add` 添加查询条件之外的组件。

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

要新增查询涉及的组件，可先记录事件，遍历结束后再添加。

```zig
fn markIdleAfterQuery(world: *ecs.World) void {
    const AddIdle = struct { entity: ecs.Entity };

    var query = world.queryNot(.{ Position, Velocity }, .{Idle});
    while (query.next()) |row| {
        if (row.get(Velocity).x != 0) continue;
        world.addEvent(AddIdle{ .entity = row.entity });
    }
    for (world.getEvent(AddIdle)) |event| world.add(event.entity, Idle{});
    world.clearEvent(AddIdle);
}
```

## Identity

`Identity` 用来记录某种类型对应的唯一实体，比如玩家。

```zig
const Player = struct {};
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Camera = struct { x: f32 = 0, y: f32 = 0 };

fn followPlayer(world: *ecs.World, camera: *Camera) void {
    const position = world.get(Player, Position) orelse return;

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
const handle = world.entities.to(enemy);

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

重置世界时，`resetKeepResources` 保留全部资源，清除组件、事件和实体。

```zig
world.resetKeepResources();
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

## 世界快照

`ecs.save` 保存世界快照，包含待处理事件。`ecs.load` 将快照恢复到新的 `World`。

```zig
var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();
try ecs.save(&world, &output.writer);

var reader = std.Io.Reader.fixed(output.writer.buffered());
var restored = try ecs.load(allocator, &reader);
defer restored.deinit();
```

快照仅供本机使用，不跨平台。指针和切片只保存引用信息，需要单独恢复。

## ID 冲突

Debug 构建会在编译时检查存储 ID 冲突。

要定位冲突的存储 ID，在根文件配置 `migu_options`，
然后使用 Debug 模式重新编译：

```zig
pub const migu_options: ecs.Options = .{ .debug_id = 7 };
```

匹配的 ID 会通过 `@compileLog` 输出类型名和存储类别。
这会中止编译，查看输出后移除配置。

## 指针稳定性

使用组件、事件或资源的指针或切片时，可锁住对应存储。

```zig
{
    const locked = world.lockPointers(Position, .component);
    // 允许存储缺失时检查 locked，否则可直接解锁。
    defer if (locked) world.unlockPointers(Position, .component);

    const position = world.getPtr(entity, Position).?;
    position.x += 1;
}
```

## 注意事项

- `Entity` 是 `u16`，最多支持 65535 个实体。
- `Handle` 的版本在同一实体编号复用 32768 次后回绕。
- 重置世界后，弃用旧 Handle，版本数据被清空。
- 每种事件最多保存 65535 条。
- 组件、事件和资源的类型不能是可选类型（`?T`）。
- `createEntity`、`add`、`addEvent`、`addResource` 遇到分配失败会 panic。
- 需要处理错误时，使用 `tryCreateEntity`、`tryAdd`、
  `tryAddEvent`、`tryAddResource`。
- 组件指针可能因扩容、删除或排序失效。
- 排序使用插入排序，适合每帧处理大体有序的数据。
- 类型别名不会产生新的组件类型。

```zig
const Name = struct {};
const PlayerName = Name;

// Name 和 PlayerName 是同一个组件类型。
```

## 名字来源

名字取自[《山海经·南山经》](https://zh.wikisource.org/zh-hans/山海經/南山經)：

> 有木焉，其状如榖而黑理，其华四照，其名曰迷榖，佩之不迷。

## 致谢

MiGu 的设计灵感深受 [EnTT](https://github.com/skypjack/entt) 和
[zig-ecs](https://github.com/prime31/zig-ecs) 影响。感谢这两个项目。

## 许可证

MIT
