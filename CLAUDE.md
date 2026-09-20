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
├── project.godot            # 主场景 / 窗口 1000x760 / 版本号 / 自动加载
├── CLAUDE.md                # 本文件
├── icon.svg
├── README.md
├── scenes/
│   └── Main.tscn            # 主场景：BoardUI + 羊皮纸背景 + RightPanel
├── scripts/
│   ├── board.gd             # 棋盘：参数化几何 + 绘制 + 状态 + 输入 + 动画
│   ├── ui.gd                # 界面：木色主题 / 滑动面板 / 弹窗 / 音效 + AI 调度
│   └── gomoku_ai.gd         # AI 算法（Alpha-Beta），纯算法、规则自适应
├── assets/ui/wood_bg.png    # 木色羊皮纸回纹背景（1600x1538）
├── docs/
│   ├── screenshot.png       # README 主图（对局中）
│   ├── start_screen.png     # 开始界面
│   ├── ui_9x9.png           # 9 路配图
│   ├── ui_19x19.png         # 19 路配图
│   ├── ui_win.png           # 胜利界面配图
│   ├── UI_OPTIMIZATION.md   # v1.1 UI 优化说明
│   ├── V12_UPDATE.md        # v1.2 / v1.2.1 参数化与修正说明
│   └── competition/         # 比赛提交材料
│       ├── README.md                        # 材料索引 + 项目速览
│       ├── 01-gameplay-and-algorithm.md     # 核心玩法与算法说明
│       └── 02-innovation-and-technology.md  # 创意与技术说明
└── addons/godot_ai/         # Godot AI MCP 插件（勿手改）
```

## 3. 场景节点树（`scenes/Main.tscn`）

```
BoardUI                  (Control)        ← scripts/ui.gd
├── WoodBackground       (TextureRect)    ← wood_bg.png，KEEP_ASPECT_COVERED
├── ChessBoard           (Node2D)         ← scripts/board.gd，位于 (30, 60)
└── UILayer              (Control)        ← mouse_filter = IGNORE（不挡棋盘点击）
    ├── StartScreen      (Control)        ← 开始界面，覆盖棋盘区域，mouse_filter = STOP
    │   └── Center → Panel → VBox → [TitleLabel / SubLabel / TipLabel / StartButton]
    ├── TurnLabel        (Label)          ← 未开始时显示标题，开始后显示轮次
    └── RightPanel       (VBoxContainer)  ← x 686~976，alignment=CENTER 垂直居中
        ├── TitlePanel   (PanelContainer) → 「玩法设置」
        ├── SizePanel    (PanelContainer) → 「棋盘大小：15 x 15」 + SizeSlider (9~19 步长 2)
        ├── WinPanel     (PanelContainer) → 「连珠数：5」        + WinSlider  (5~6)
        ├── SidePanel    (PanelContainer) → 「执子：…」          + SideOption
        ├── AiPanel      (PanelContainer) → 「AI 难度：普通」    + AiSlider   (1~3)
        ├── BtnPanel     (PanelContainer) → [重新开始] [悔棋]
        └── InfoPanel    (PanelContainer) → AiStatusLabel / MoveCountLabel
```

> `StartScreen` 只覆盖棋盘区域（30,60 ~ 670,700），
> 因此**右侧面板在开始界面仍可操作** —— 玩家可先配置玩法再开局。
> 它带 `mouse_filter = STOP` 挡住棋盘点击，同时 `board.input_locked = true` 双保险。

> `SideOption` 是 `OptionButton`：「执黑 · 先行」/「执白 · 后行」。
> 选「执白」后角色互换 —— AI 执黑先手，`_maybe_start_ai_turn()` 会自动启动 AI 回合。

> 每个分组都由 `PanelContainer` 包裹，统一套 `StyleBoxFlat`：
> 圆角 8px、`#FFFFFFAA` 底、`#8B6642` 描边、4px 投影。

> **关键**：根节点 `BoardUI`、`UILayer`、`WoodBackground` 以及所有非交互控件
> 都必须保持 `mouse_filter = IGNORE`（tscn 中为 `mouse_filter = 2`），
> 否则会拦截棋盘的鼠标点击（详见 §7 第 2 条）。
> 按钮与 HSlider 保持默认 `STOP` 即可正常接收点击/拖动。

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
| `1` | 黑棋（**永远先行**） |
| `2` | 白棋 |

> 执黑/执白由 UI 的「执子」选项决定（`ui.gd` 的 `human_color` / `ai_color`）。
> 无论玩家执哪边，**黑棋始终先行** —— 玩家执白时由 AI 先手。

`board` 是 **`board_size` × `board_size` 的二维数组**（默认 15×15），
索引方式恒为 `board[row][col]`。`board_size` 可变，但数组**结构从不改变**。

### 棋盘几何（`board.gd`，**全部随 `board_size` 动态计算**）

| 变量 | 15 路时的值 | 说明 |
| --- | --- | --- |
| `board_size` | 15 | 交叉点数（9~19，可调） |
| `BOARD_PX` | 640.0 | 棋盘绘制区固定边长（const） |
| `BOARD_MARGIN` | 40.0 | 网格四周留白（const） |
| `cell_size` | 40.0 | `560 / (board_size - 1)` |
| `grid_px` | 560.0 | `BOARD_PX - BOARD_MARGIN * 2` |
| `origin_x/y` | 40.0 | `= BOARD_MARGIN` |
| `stone_radius` | 16.0 | `clampf(cell_size * 0.40, 6, 30)` |
| `star_radius` | 3.5 | `clampf(cell_size * 0.088, 1.5, 5)` |
| `mark_radius` | 4.0 | `clampf(stone_radius * 0.25, 2, 6)` |
| `LINE_WIDTH` | 1.5 | 网格线宽（const） |

尺寸 → 格宽 / 棋子半径实测：9 路 70.0 / 28.0，13 路 46.7 / 18.7，
**15 路 40.0 / 16.0（与原版一致）**，19 路 31.1 / 12.4。

> 星位由 `_star_points()` 生成：`board_size >= 13` 时为天元 + 4 星位，
> 否则只有天元。

## 6. 对外接口契约

### `board.gd`（`extends Node2D`）

```gdscript
signal stone_placed(row: int, col: int)
signal game_over(winner: int)              # 1=黑, 2=白, 0=和棋

# —— 玩法参数（v1.2 起可在运行时调整）——
var board_size: int = 15     # 只取奇数：9/11/13/15/17/19（偶数会被向上取奇）
var win_count:  int = 5      # 5~6（不存在五珠以下玩法）
var ai_level:   int = 2      # 1~3（仅记录，实际由 ui.gd 下发给 AI）

func set_rules(new_size: int, new_win: int, new_level: int = -1) -> void   # 应用并重开一局

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

> **棋盘数据结构不变**：始终是 `board[row][col]` 的二维 `Array`，
> `0=空 / 1=黑 / 2=白`。参数化只影响尺寸、连珠数与几何。

### `gomoku_ai.gd`（`extends RefCounted`，纯算法）

```gdscript
func get_best_move(board: Array, ai_color: int) -> Vector2i   # 返回 (row, col)，无棋可下返回 (-1, -1)
func set_difficulty(level: int) -> void                       # 0=简单 1=普通 2=困难
func set_rules(win_count: int) -> void                        # 连珠数 3~6；棋盘尺寸由 board.size() 推断
func reset() -> void
func get_last_stats() -> Dictionary                           # {"nodes","depth","score","elapsed_ms"}
```

**约束**：`gomoku_ai.gd` 必须是纯算法文件 —— 不得 `extends Node`、
不得引用场景树或其它脚本、不得修改传入的 `board`。

### 难度与深度（v1.2 起深度由「尺寸 × 难度」共同决定）

```
base  = 5 (n<=9) / 4 (n<=12) / 3 (n<=15) / 2 (n>15)
depth = clampi(base + difficulty - 1, 1, 6)      # EASY=-1 / NORMAL=0 / HARD=+1
```

实测：9 路普通档 深度 5 / 465ms，19 路普通档 深度 2 / 9ms。

### 评估权重随连珠数变化（v1.2）

| 连子数 | 分值 |
| --- | --- |
| `>= win_count` | `SCORE_FIVE` = 1,000,000 |
| `== win_count-1` 两端空 / 一端空 | 活四 100,000 / 冲四 10,000 |
| `== win_count-2` 两端空（活三） | 3 连时 50,000；**4 连时 10,000**；5 连及以上 1,000 |
| `== win_count-2` 一端空 | 眠三 100 |
| `== win_count-3` 两端空 | 活二 10 |

## 7. 已修复的坑（勿回退）

1. **信号广播顺序**：`_apply_move()` 必须**先**更新 `current_player` /
   `game_finished`，**再** `emit stone_placed`。否则 UI 读到旧状态，
   轮次标签会慢一拍，且 AI 永远不会被触发。
2. **`mouse_filter`**：根节点 `BoardUI`、`UILayer`、`WoodBackground` 以及
   所有非交互控件都必须是 `IGNORE`（tscn 中 `mouse_filter = 2`）。
   否则根 Control 会盖住整个视口，`gui_get_hovered_control()` 永远非空
   → **棋盘一点就点不动**。
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
9. **`Input.warp_mouse()` 不会触发 Control 悬停**：它只改光标位置，
   不产生 GUI 的 motion 事件，所以 `mouse_entered` 与 hover 样式都不生效。
   要验证悬停必须用 `get_viewport().push_input(InputEventMouseMotion)`。
10. **悬停预览不要写进 `_input()`**：v1.1 的幽灵棋子走 `_process()` 轮询
    `get_local_mouse_position()`，这样完全不碰原有的点击落子路径。
    （`_input()` 只负责真正的落子。）
11. **`OptionButton` 继承自 `Button`**：Theme 里只配 `Button` 的 StyleBox
    即可，OptionButton 会自动套用，不必重复设置。
12. **中文字重**：`SystemFont.font_weight` 给标题加粗（正文 400 / 标题 700）。
    内置字体不含 CJK，必须用 SystemFont + 回退链，否则中文显示成方框。
13. **落子动画的 Tween 会吃掉首帧大 delta**：场景刚加载完的第一帧
    delta 可能高达 60ms+（`GradientTexture2D` 构建等），会把 260ms 的
    弹跳动画压缩掉大半。做动画计时验证时要先预热 1 秒再采样。
14. **新增图片资源后必须 `--import`**：Godot 4 不会在非编辑器模式下自动导入。
    直接跑主场景会报 `No loader found for resource: ... (expected type: Texture2D)`
    与 `[ext_resource] referenced non-existent resource`。解决办法：
    `godot --headless --path . --import`。
15. **`HSlider` 只监听 `drag_ended` 会漏掉非拖动改值**：点击滑轨、方向键
    改值都不发 `drag_ended`，只挂它会「改了不生效」。正确做法是
    `value_changed` 里起一个一次性 `Timer` 做防抖 + `drag_ended` 立即应用。
16. **胜负弹窗别居棋盘正中**：棋盘中央那条横线（15 路时是第 7 行，y≈380）
    是最常见的获胜位置，弹窗居正中会正好压住闪烁的连线。
    因此 `CenterContainer` 的 `offset_bottom` 收到 440，把弹窗中心抬到 y≈250。
17. **改棋盘尺寸必须清 `_hover_cell`（v1.2.1 修的真实显示 bug）**：
    鼠标停在 19 路右下角时 `_hover_cell=(17,17)`，切到 9 路后 `_draw` 里
    `board[17]` **越界报错**；而报错会中断整个 `_draw()`，导致后面的
    `_draw_stones()` / `_draw_last_marker()` 被跳过 —— **棋子整帧画不出来**，
    看起来就像「调大小后棋盘显示坏了」。
    现在三重防护：`set_rules()` 里清 `_hover_cell`、
    `_draw_ghost_stone()` 加 `is_inside()` + 数组实际尺寸双重判断、
    `_draw_stones()` 按 `mini(board_size, board.size())` 遍历。
    **教训：`_draw()` 里任何一次越界都会让整帧绘制中断，比普通逻辑报错严重得多。**
18. **连珠数下限是 5**：不存在「五珠以下」的玩法。
    `board.gd` / `ui.gd` 的 `MIN_WIN_COUNT` 均为 5，滑块下限也是 5，
    `set_rules()` 里再夹一次（防绕过 UI 直接调 API）。
    `gomoku_ai.gd` 的 `set_rules()` 仍按 3~6 夹取 —— 那是算法自身的兼容范围，
    规则层的 5~6 限制由前两者负责。
19. **棋盘边长只取奇数（v1.3.0）**：9/11/13/15/17/19。
    偶数盘没有唯一的中心交叉点，天元与星位对称性会错位。
    滑动条 `step = 2`；`set_rules()` 内对偶数**向上取奇**（14→15、18→19），
    因此绕过 UI 直接调 API 也产生不了偶数盘。
20. **开始界面会复位 `input_locked`**：`board.restart()` / `set_rules()` 内部
    都会把 `input_locked` 置回 false，而开始界面正需要「锁住棋盘」。
    因此 `_restart_round()` 与 `_apply_slider_rules()` 结尾都要调
    `_sync_input_lock()` 重新锁上；`_maybe_start_ai_turn()` 也要用
    `_game_started` 守卫，否则在开始界面选「执白」会让 AI 抢跑。

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

## 9. 视觉层约定（v1.1 / v1.2）

- **视觉状态与棋局状态严格分离**：`board.gd` 中的 `_stone_scale` /
  `_hover_cell` / `_win_line` / `_win_phase` 只服务渲染，**从不写回**棋局数据。
- **动画统一走信号**：落子弹跳监听已有的 `stone_placed`，不改 `_apply_move()`。
- **参数变化走 `set_rules()`**：尺寸/连珠数变化必须通过它，它会重算几何、
  清空动画记录并重开一局；不要绕过它直接改 `board_size`。
- **外部资源只有一个**：`assets/ui/wood_bg.png`（背景图）。
  其余全部零素材 —— 木纹用 `GradientTexture2D`、
  音效用 `AudioStreamWAV` 合成、中文字体用 `SystemFont`，
  仓库里没有任何 ttf / wav / shader 文件。
- 详细说明见 `docs/UI_OPTIMIZATION.md`（v1.1）与 `docs/V12_UPDATE.md`（v1.2）。

