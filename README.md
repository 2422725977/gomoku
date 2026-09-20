# 五子棋 Gomoku · Godot 4

基于 **Godot 4** 的五子棋（15×15）图形化对战程序：鼠标点击落子，内置 Alpha-Beta 剪枝 AI，支持三档难度、悔棋与重新开始。界面文案全中文。

![游戏截图](docs/screenshot.png)

## 功能

- **棋盘渲染**：640×640 棋盘、15×15 交叉点、每格 40px；径向渐变木纹底 + 细木纹，深棕色网格线
- **棋子立体感**：外阴影 + 边缘压暗 + 双层高光，做出球面质感；最后一手有红点标记
- **落子动画**：棋子以 `0.5× → 1.2× → 1.0×` 弹跳落下（Q 弹回弹），耗时 260ms
- **悬停预览**：鼠标停在空交叉点时显示半透明的当前回合色棋子
- **交互**：鼠标点击自动吸附到最近交叉点（半格容差），点按钮不会误落子
- **AI 对战**：玩家执黑先行，AI 执白应手
- **三档难度**：简单（深度 1 + 10% 随机）/ 普通（深度 3）/ 困难（深度 5 + 2 秒时限）
- **对局控制**：重新开始、悔棋（一次退回一整轮）、实时步数统计与 AI 思考状态
- **胜负反馈**：获胜五连呼吸式闪烁 + 棋盘中央淡入缩放的结算弹窗
- **音效**：程序合成的落子「砰」声，无需任何外部音频素材

## 视觉与交互优化（v1.1）

v1.1 在**不改动任何棋局逻辑**的前提下完成了界面质感升级 —— `board.gd` 的棋盘状态代码与 `gomoku_ai.gd` 的调用契约均保持原样，所有动画都由视觉专用变量 + `Tween` 驱动。

![胜利界面](docs/ui_win.png)

完整技术细节（配色表、缓动曲线、实测缩放轨迹、验证数据）见 **[docs/UI_OPTIMIZATION.md](docs/UI_OPTIMIZATION.md)**。

## 快速开始

需要 **Godot 4.5+**（本项目在 4.7.2-stable 上开发验证）。

```bash
git clone <this-repo>
cd game3
# 用 Godot 打开本目录，或直接命令行运行：
godot --path . --rendering-driver opengl3
```

主场景为 `res://scenes/Main.tscn`，已在 `project.godot` 中配置，启动即进入对局。

## 项目结构

```
game3/
├── project.godot          # 主场景 / 窗口 1000x760 / 自动加载
├── CLAUDE.md              # 引擎与代码约定参考（含接口契约、已修复的坑）
├── scenes/
│   └── Main.tscn          # 主场景：BoardUI(Control) 根节点
├── scripts/
│   ├── board.gd           # 棋盘：绘制 + 状态 + 鼠标输入
│   ├── ui.gd              # 界面：轮次/按钮/难度 + AI 调度
│   └── gomoku_ai.gd       # AI 算法（纯 RefCounted，无场景依赖）
└── addons/godot_ai/       # Godot AI MCP 编辑器插件（开发工具，随项目一并提交）
```

### 架构

```
玩家点击棋盘
   └─ board.gd::_input()                 像素坐标 → 最近交叉点
        └─ place_stone(row, col)         更新棋局状态
             ├─ emit stone_placed        状态更新完毕后再广播
             └─ emit game_over           仅终局

ui.gd::_on_stone_placed()
   ├─ 刷新轮次 / 步数 / 按钮可用性
   └─ 轮到 AI → gomoku_ai.get_best_move() → board.set_ai_move()
```

棋盘用 `Array[Array]` 表示，`board[row][col]`，`0=空 / 1=黑 / 2=白`。

## AI 算法

Negamax + Alpha-Beta 剪枝，迭代加深，2 秒硬超时。

- **评估函数**：五连 1000000 / 活四 100000 / 冲四 10000 / 活三 1000 / 眠三 100 / 活二 10，支持跳型（`XX_XX` 计冲四、`X_XX` 计活三）
- **增量式线型评分**：棋盘预切为「线」，落子只重算经过该点的 4 条线，叶子评估 O(1) —— 这是深度 5 能压进 2 秒的关键
- **置换表**：Zobrist 增量哈希 + 单 int64 打包（分数/depth/flag/move），含 mate-ply 修正，20 万条封顶
- **候选点**：距任一棋子切比雪夫距离 ≤ 2 的空点，按 `攻×2 + 守` 排序，根 18 / 内部 12 个
- **战术预检**：搜索前先判「我方成五 → 对方成五必挡 → 我方成活四」，命中直接短路

实测（困难档，深度 5）：自对弈 25 手，单步最大 1537 ms，平均 661 ms；普通档单步约 27 ms。

## AI 接口契约

`scripts/gomoku_ai.gd` 是纯算法文件（`extends RefCounted`，不触碰场景树），可独立替换：

```gdscript
func get_best_move(board: Array, ai_color: int) -> Vector2i  # 返回 (row, col)，无棋可下返回 (-1, -1)
func set_difficulty(level: int) -> void                      # 0=简单 1=普通 2=困难
func reset() -> void
func get_last_stats() -> Dictionary                          # {"nodes", "depth", "score", "elapsed_ms"}
```

## 开发与验证

```bash
# 语法检查
godot --headless --path . --check-only --script "res://scripts/board.gd"

# 无头跑主场景，捕获运行期错误
godot --headless --path . --quit-after 90

# 带渲染运行
godot --path . --rendering-driver opengl3
```

> 注意：`--headless` 下视口尺寸与带渲染时不同，**鼠标点击相关测试必须在带渲染模式下运行**，否则会因 stretch 变换产生假失败。详见 `CLAUDE.md` §7。

## 已知事项

- `困难` 档搜索是同步的，最坏会阻塞主线程约 2 秒（界面已先绘制「AI 思考中…」）
- 项目未附许可证文件；如需开源请自行添加 LICENSE
