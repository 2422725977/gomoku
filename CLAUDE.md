# CLAUDE.md — 五子棋项目（game3）

> 本文件是本项目的引擎与代码约定参考，供后续 AI/人类协作者使用。
> 说明：原计划的 `/setup-engine godot 4.5` 技能在当前会话的技能目录中不可用，
> 因此该技能的产物（CLAUDE.md + 引擎参考）由本文件手工等价实现。

## 1. 引擎与运行环境

| 项 | 值 |
| --- | --- |
| 引擎版本 | Godot **4.7.2-stable**（项目 `config/features` 标记为 `"4.7"`，兼容需求中的 4.5+） |
| 渲染方式 | `gl_compatibility`（OpenGL 3.3 兼容模式） |
| 主场景 | `res://scenes/Main.tscn` |
| 设计分辨率 | 1000 × 760，拉伸模式 `canvas_items` / `expand` |
| 编辑器插件 | `res://addons/godot_ai/plugin.cfg`（Godot AI MCP） |

### 命令行运行 / 验证

```powershell
$godot = "D:\Godot4.7.2\Godot_v4.7.2-stable_win64.exe"

# 只检查脚本语法
& $godot --headless --path . --check-only --script "res://scripts/board.gd"

# 无头跑一遍主场景（抓运行期错误）
& $godot --headless --path . --quit-after 40

# 带渲染运行（截图验证用）
& $godot --path . --rendering-driver opengl3 "res://scenes/Main.tscn"
```

## 2. 目录结构

```
game3/
├── project.godot            # 主场景 / 窗口尺寸 / 自动加载
├── CLAUDE.md                # 本文件
├── icon.svg
├── scenes/
│   └── Main.tscn            # 主场景：BoardUI 根节点
├── scripts/
│   ├── board.gd             # 棋盘：绘制 + 状态 + 输入
│   ├── ui.gd                # 界面：轮次/按钮/难度 + AI 调度
│   └── gomoku_ai.gd         # AI 算法（Alpha-Beta），纯算法、无场景依赖
└── addons/godot_ai/         # Godot AI MCP 插件（勿手改）
```

## 3. 场景节点树（`scenes/Main.tscn`）

```
BoardUI                (Control)      ← scripts/ui.gd
├── Background         (ColorRect)    ← 深色背景，mouse_filter = IGNORE
├── ChessBoard         (Node2D)       ← scripts/board.gd，位于 (40, 60)
└── UILayer            (Control)      ← mouse_filter = IGNORE（不挡棋盘点击）
    ├── TurnLabel      (Label)        ← 「黑棋回合」/「白棋回合」/「黑棋胜利！」
    ├── BottomBar      (HBoxContainer)
    │   ├── RestartButton    (Button)     「重新开始」
    │   ├── UndoButton       (Button)     「悔棋」
    │   ├── DifficultyLabel  (Label)      「AI 难度」
    │   └── DifficultyOption (OptionButton) 简单 / 普通 / 困难
    └── SidePanel      (VBoxContainer)
        ├── SideTitleLabel  (Label)   「对局信息」
        ├── AiStatusLabel   (Label)   AI 思考状态
        ├── MoveCountLabel  (Label)   步数统计
        └── HintLabel       (Label)   操作提示
```

> **关键**：根节点 `BoardUI`、`UILayer`、`Background` 以及所有非交互控件
> 都必须保持 `mouse_filter = IGNORE`（tscn 中为 `mouse_filter = 2`），
> 否则会拦截棋盘的鼠标点击（详见 §7 第 2 条）。
> 按钮保持默认 `STOP` 即可正常接收点击。

## 4. 代码约定

- **缩进一律使用 Tab**（GDScript 官方风格）。
- 所有面向玩家的 UI 文本使用**中文**。
- 变量/函数名用英文 snake_case，类型标注尽量补全（`var x: int = 0`）。
- 跨脚本引用 `board` / `_ai` 时**不要加静态类型**（如 `var board: Node2D`）：
  它们的脚本在解析期对 `ui.gd` 不可见，加类型会导致
  `Cannot find member "xxx" in base "Node2D"` 编译错误。
- 中文字形：Godot 内置字体不含 CJK，`ui.gd` 在 `_ready()` 里用
  `SystemFont` 构造 `Theme` 并赋给根节点，子控件自动继承。**不要删除**。

## 5. 架构与数据流

```
玩家点击棋盘
   └─ board.gd::_input()           把像素坐标换算成最近交叉点
        └─ board.gd::place_stone(row, col)
             ├─ 更新 board / move_history / current_player
             ├─ emit stone_placed(row, col)     ← 状态已更新完毕再广播
             └─ emit game_over(winner)          ← 仅在终局时

ui.gd::_on_stone_placed()
   ├─ _refresh_ui()                 刷新轮次标签 / 步数 / 按钮可用性
   └─ 若轮到 AI 且已加载 AI → _run_ai_turn()
        ├─ board.input_locked = true，标签显示「AI 思考中…」
        ├─ await 0.12s            让界面先绘制
        ├─ gomoku_ai.gd::get_best_move(board.get_board_state(), AI_COLOR)
        └─ board.set_ai_move(row, col, AI_COLOR)
```

### 棋盘取值

| 值 | 含义 |
| --- | --- |
| `0` | 空 |
| `1` | 黑棋（玩家，先行） |
| `2` | 白棋（AI） |

`board` 是 **15×15 的二维数组**，索引方式 `board[row][col]`。

### 棋盘几何（`board.gd`）

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `BOARD_SIZE` | 15 | 交叉点数 |
| `CELL_SIZE` | 40.0 | 每格像素 |
| `BOARD_PX` | 640.0 | 棋盘区域边长 |
| `GRID_PX` | 560.0 | 网格跨度 = 14 × 40 |
| `ORIGIN_X/Y` | 40.0 | 网格起点 = (640 − 560) / 2 |
| `STONE_RADIUS` | 16.0 | 棋子半径 |
| `LINE_WIDTH` | 1.5 | 网格线宽，深棕色 |

> 规格给出「边距 20px」，但 15 条线按 40px 间距只占 560px；
> 代码按**居中对齐**处理，实际留白为 40px，视觉更对称。

## 6. 对外接口契约

### `board.gd`（`extends Node2D`）

```gdscript
signal stone_placed(row: int, col: int)
signal game_over(winner: int)              # 1=黑, 2=白, 0=和棋

func place_stone(row: int, col: int) -> bool            # 玩家落子
func set_ai_move(row: int, col: int, color: int = 0) -> bool   # AI 落子（预留接口）
func get_board_state() -> Array                         # 深拷贝，供 AI 使用
func undo_moves(count: int = 1) -> int
func undo_to_player(color: int) -> int                  # 悔棋（最多一整轮）
func restart() -> void
func grid_to_local(cell: Vector2i) -> Vector2
func local_to_grid(pos: Vector2) -> Vector2i
var current_player: int      # 1 / 2
var game_finished: bool
var winner: int              # 1 / 2 / 0
var input_locked: bool       # AI 思考期间由 ui.gd 置位
```

### `gomoku_ai.gd`（`extends RefCounted`，纯算法）

```gdscript
func get_best_move(board: Array, ai_color: int) -> Vector2i   # 返回 (row, col)，无棋可下返回 (-1, -1)
func set_difficulty(level: int) -> void                       # 0=简单 1=普通 2=困难
func reset() -> void
func get_last_stats() -> Dictionary                           # 可选
```

**约束**：`gomoku_ai.gd` 必须是纯算法文件 —— 不得 `extends Node`、
不得引用场景树或其它脚本、不得修改传入的 `board`。

### 难度档位

| 索引 | 名称 | 深度 | 其它 |
| --- | --- | --- | --- |
| 0 | 简单 | 1 | 10% 概率随机落子 |
| 1 | 普通 | 3 | — |
| 2 | 困难 | 5 | 2 秒时限 |

## 7. 已修复的坑（勿回退）

1. **信号广播顺序**：`_apply_move()` 必须**先**更新 `current_player` /
   `game_finished`，**再** `emit stone_placed`。否则 UI 读到旧状态，
   轮次标签会慢一拍，且 AI 永远不会被触发。
2. **`mouse_filter`**：根节点 `BoardUI` 与 `UILayer`、`Background` 都必须是
   `IGNORE`（tscn 中 `mouse_filter = 2`）。否则根 Control 会盖住整个视口，
   `gui_get_hovered_control()` 永远非空 → **棋盘一点就点不动**。
   （已用对照实验确认：改回默认 STOP 后，点击全部被拒。）
3. **`_input` 中的 UI 守卫**：落子前检查
   `get_viewport().gui_get_hovered_control() != null`，避免点按钮时误落子。
4. **`place_stone()` 要检查 `input_locked`**：它是「玩家落子」入口，
   AI 思考窗口期内必须拒绝，否则可能抢手。`set_ai_move()` 则**不能**检查
   （AI 落子时 `input_locked` 正是 true）。
5. **静态类型**：见 §4 最后一条。
6. **`PackedInt32Array` 没有 `pop_back()`**：`Array` 才有。撤消栈要用
   「读栈顶索引 + 最后 `resize()` 截断」的写法。
7. **`gomoku_ai.gd` 的哨兵边界**：`_grid` 只有**外圈 PAD 层**是 `WALL`，
   棋盘内部必须是 `EMPTY`。若整体 `fill(WALL)`，所有空点都会被判为「非空」，
   候选列表恒为空 → AI 永远返回 `(-1, -1)`。
8. **无头模式不能测鼠标点击**：`--headless` 下视口是 1000×1000（非 760），
   stretch 变换导致 `push_input` 的坐标偏移，点击测试会假失败。
   输入相关验证必须**带渲染**运行。

## 8. 验证方式（已跑通，0 失败）

| 项目 | 命令要点 |
| --- | --- |
| 语法 | `--headless --check-only --script res://scripts/xxx.gd` |
| 运行期 | `--headless --quit-after 90`（跑主场景，抓 ERROR） |
| 鼠标输入 | **窗口模式** `--rendering-driver opengl3` 跑输入测试场景 |
| 逻辑 / AI | 无头跑测试场景，断言轮次、悔棋、五连、AI 战术 |
| 自对弈 | AI 自我对弈至终局，检查非法着法与单步耗时 |

实测性能（困难档，深度 5 + 2s 上限）：自对弈 25 手，单步最大 1537 ms，
平均 661 ms；普通档单步约 27 ms。

