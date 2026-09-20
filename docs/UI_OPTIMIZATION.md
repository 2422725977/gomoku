# UI 优化说明 · v1.1

> 本文档记录五子棋 v1.1「UI 视觉与交互优化」阶段的全部改动，可直接摘取进比赛文档。

## 0. 优化目标与硬约束

**目标**：在不改动任何棋局逻辑的前提下，全面提升棋盘的材质质感、棋子立体感与操作反馈。

**硬约束（已严格遵守）**：

| 约束 | 执行情况 |
|---|---|
| 不修改 `board.gd` 的棋盘状态管理 | ✅ `board` 数组、`move_history`、`current_player`、胜负判定、`place_stone` / `set_ai_move` / `undo_*` / `restart` 全部原样未动 |
| 不修改 `gomoku_ai.gd` 的调用逻辑 | ✅ `ui.gd` 对 AI 的调用契约（`set_difficulty` / `get_best_move` / `reset` / `get_last_stats`）完全不变 |
| 动画只能通过视觉节点或 Tween 驱动 `_draw` 参数 | ✅ 全部动画通过「视觉专用变量 + Tween + `queue_redraw()`」实现 |
| 单个效果报错超过 3 次就降级 | ✅ 木纹渐变一次成功，未触发降级；仍保留了纯色填充作为运行时兜底 |

**实现思路**：`board.gd` 中新增了一个与棋局状态完全隔离的「视觉状态」区块，只**读取**棋局数据，从不写入：

```gdscript
# 视觉状态（仅服务渲染与动画，不参与任何棋局判定）
var _wood_texture: GradientTexture2D = null
var _stone_scale: Dictionary = {}              # Vector2i -> float
var _hover_cell: Vector2i = Vector2i(-1, -1)
var _win_line: Array = []
var _win_active: bool = false
var _win_phase: float = 0.0
```

落子动画的触发也**不侵入**状态代码，而是监听已有的 `stone_placed` 信号：

```gdscript
func _ready() -> void:
	board = make_empty_board()
	_wood_texture = _build_wood_texture()
	# 只监听落子信号来驱动动画，不介入棋局状态代码
	stone_placed.connect(_on_stone_placed_visual)
	queue_redraw()
```

---

## 1. 优先级 1：棋盘质感与动画

### 1.1 木纹质感（径向渐变）

用 `GradientTexture2D` 的**径向填充**替换原来的纯色 `ColorRect` 底色，模拟打了顶光的木质棋盘：

| 位置 | 颜色 | 说明 |
|---|---|---|
| 中心（offset 0.0） | `#F0D6A6` | 高光区，略亮于规格给定色 |
| 中段（offset 0.45） | `#E6C280` | 规格主色 |
| 边缘（offset 1.0） | `#D4A76A` | 规格暗色，压出木料的边缘厚度 |

```gdscript
texture.fill = GradientTexture2D.FILL_RADIAL
texture.fill_from = Vector2(0.5, 0.42)   # 光源略偏上
texture.fill_to = Vector2(1.0, 0.98)
```

另外叠加了 14 条**极淡的横向木纹**（用固定随机种子生成，保证每次渲染一致），alpha 仅 0.028~0.060，避免棋盘显得过于平滑死板。

> 兜底设计：若纹理构建失败（`_wood_texture == null`），自动回退为原来的纯色填充，不会导致黑屏。

### 1.2 棋子立体感

原来的棋子只是一个纯色圆 + 一个小高光点，v1.1 改为三层结构：

1. **外阴影** —— 向右下偏移的半透明黑圆（`alpha = 0.28`），把棋子从棋盘上"抬"起来
2. **边缘压暗** —— 用 `draw_arc` 在半径内侧描一圈更深的颜色，制造球面转折
3. **双层高光** —— 左上角一片柔光（alpha 0.20）+ 更小的一点镜面高光（alpha 0.55），黑子白子分别调过强度

### 1.3 落子弹跳动画（Q 弹）

**轨迹**：`0.5× → 1.2× → 1.0×`，总时长 260 ms。

```gdscript
tween.tween_method(_set_stone_scale.bind(cell), 0.5, 1.2, 0.12)
	.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)     # 快速弹起
tween.tween_method(_set_stone_scale.bind(cell), 1.2, 1.0, 0.14)
	.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)     # 回弹过冲
```

第二段使用 `TRANS_BACK`，会在落到 1.0 之前**先略微缩小到约 0.98 再弹回 1.0**，形成果冻般的回弹手感。

实测缩放轨迹（毫秒 = 缩放值）：

```
0=0.500  7=0.579  14=0.653  20=0.722  27=0.787  34=0.846  41=0.902
48=0.952  55=0.998  62=1.039  69=1.076  76=1.108  83=1.135  90=1.157
→ 峰值 1.2 → 157=1.175  159=1.014  166=1.004  173=0.998
180=0.985  187=0.981  194=0.980  201=0.980  208=0.981
… 257=1.000
```

### 1.4 悬停预览（Ghost Stone）

鼠标悬停在**空**交叉点时，绘制一枚当前回合颜色的半透明棋子（`alpha = 0.4`），并描一圈边以保证在木色底上依然清晰。

实现要点：悬停检测走 `_process()` 轮询 `get_local_mouse_position()`，而不是改 `_input()` —— 这样**完全不影响**原有的点击落子代码路径；鼠标移出棋盘时 `local_to_grid()` 返回 `(-1,-1)`，预览自动消失。

### 1.5 最新一手标记

最后一手位置绘制小红点（`#D92632`，半径 4px），并随该棋子的弹跳一起缩放，视觉上始终贴合。

---

## 2. 优先级 2：UI 面板美化

### 2.1 全局 Theme

新建统一 `Theme` 并挂到根节点，所有子控件自动继承：

- **按钮圆角**：`StyleBoxFlat`，圆角半径 **8px**，四态配色

  | 状态 | 底色 | 边框 |
  |---|---|---|
  | normal | `#3A4356` | `#545F78` |
  | hover | `#4A566E` | `#D9A441`（描金） |
  | pressed | `#2B3242` | `#D9A441` |
  | disabled | `#292E3B` | `#3B404F` |

  文字色随状态变化（悬停变纯白、按下变金色、禁用变灰）。

- **中文字体**：用 `SystemFont` 而非内置字体（Godot 内置字体不含 CJK 字形，直接用会显示成豆腐块）。字体族按优先级回退：
  `Microsoft YaHei UI → Microsoft YaHei → SimHei → SimSun → Noto Sans CJK SC → Source Han Sans SC → PingFang SC → sans-serif`

- **字重分级**：正文 400，标题 700（`SystemFont.font_weight`）。

- `OptionButton` 在 Godot 4 中继承自 `Button`，自动套用同一套圆角样式，无需重复配置。

### 2.2 顶部回合提示

字号 **24 → 30**，字重 700，并加 **8px 描边**。配色随回合翻转：

| 状态 | 文字色 | 描边色 | 效果 |
|---|---|---|---|
| 黑棋回合 | 近白 `#FAFAFF` | 深色 `#0A0D14` | 白字黑边 |
| 白棋回合 | 深色 `#171A21` | 浅色 `#EBEBF5` | 黑字白边 |
| 黑棋胜利 | 金色 `#D9A441` | 深棕 | 高亮庆祝 |

### 2.3 胜利五连闪烁

胜负判定后，从最后一手向四个方向回溯，找出真正连成五子的那条线（**只读**棋盘，不修改任何数据），然后让这五枚棋子做呼吸式闪烁：

```gdscript
flash = 0.42 + 0.58 * absf(sin(_win_phase))   # 相位由 _process 累积
```

非获胜棋子保持不透明，形成对比。重新开始或悔棋后闪烁自动复位。

### 2.4 胜负弹窗

游戏结束时在**棋盘正中**弹出结算面板（不是窗口正中 —— 因为右侧有信息栏，棋盘整体偏左，居中到窗口会显得歪）：

- 圆角 14px、金色描边、16px 投影
- 文案：`你赢了！`（金）/ `你输了`（红）/ `和棋`
- 动画：**淡入**（`modulate.a` 0→1，0.28s）+ **缩放弹出**（`scale` 0.72→1.0，`TRANS_BACK`，0.42s）
- 面板 `mouse_filter = IGNORE`，不会挡住棋盘的鼠标点击

---

## 3. 优先级 3：音效与细节

### 3.1 落子音效（程序合成，零素材依赖）

没有引入任何外部音频文件，而是用 `AudioStreamWAV` **现场合成**一记短促的"砰"声：

```gdscript
freq = 430.0 * exp(-20.0 * t) + 72.0   # 频率从 ~500Hz 快速下滑到 72Hz
env  = exp(-26.0 * t)                  # 指数衰减包络
sample = sin(TAU * freq * t) * env
```

- 格式：16-bit PCM / 22050 Hz / 单声道 / 2646 帧 / **0.12 秒**
- 播放音量 -7 dB；胜负确定时用 `pitch_scale = 0.78` 压低音调，听感更"沉"

这样既满足"有落子反馈音"的需求，又不增加任何资源文件体积，也避免了 `AudioStreamGenerator` 需要实时填充缓冲区的复杂度。

### 3.2 按钮悬停放大

按钮在 `mouse_entered` / `mouse_exited` 时用 Tween 在 **1.06×** 与 1.0× 之间过渡（0.12s，`TRANS_QUAD` / `EASE_OUT`），配合 Theme 的描金边框，形成明确的"可点击"反馈。缩放前会重算 `pivot_offset` 为控件中心，保证从中心放大而不是从左上角。

---

## 4. 验证结果

全部效果均在真实渲染窗口（`--rendering-driver opengl3`）+ 截图下逐项确认：

| 验证项 | 方法 | 结果 |
|---|---|---|
| 木纹渐变 + 木纹纹理 | 截图 | ✅ |
| 棋子三层立体感 | 截图 | ✅ |
| 落子弹跳轨迹 | 逐帧采样 `scale` 值 | ✅ 0.5→1.2→1.0，实测峰值 1.175，257ms 归位 |
| 悬停预览 | 移动鼠标后读取 `_hover_cell` + 截图 | ✅ `hover_cell=(5,9)`，半透明棋子正常绘制 |
| 按钮四态样式 | 截图（含 hover 态） | ✅ 金色描边 + 1.06× 放大 |
| 回合提示描边配色 | 读取 `get_theme_color("font_color")` + 截图 | ✅ 黑白两态正确翻转 |
| 胜利五连闪烁 | 截图 + 读取 `_win_line` | ✅ 5 枚棋子同步呼吸 |
| 胜负弹窗 | 读取中心坐标 + 截图 | ✅ 中心 `(360, 380)` = 棋盘正中 |
| 落子音效 | 读取 `AudioStreamWAV` 属性 + `playing` 状态 | ✅ 0.12s / 22050Hz，落子后 `playing=true` |
| 回归：棋局逻辑 | `--headless --quit-after 90` 跑主场景 | ✅ 无任何 ERROR |

---

## 5. 性能与兼容性

| 项 | 数据 |
|---|---|
| 木纹纹理 | 640×640 `GradientTexture2D`，启动时构建一次，之后复用 |
| 每帧开销 | `_process()` 只做一次悬停格比较；仅当悬停格或闪烁相位变化时才 `queue_redraw()` |
| 动画实现 | 全部基于 `Tween`（引擎内建插值），无逐帧手写计时器 |
| 外部依赖 | **零** —— 无外部字体文件、无音频素材、无 Shader 文件 |
| 可移植性 | 未使用任何平台相关 API；中文字体通过 `SystemFont` + 回退链解析 |

> 注意：`board.gd` 的 `_process()` 只在需要时重绘，静态局面下不会产生持续的重绘开销。

---

## 6. 文件改动清单（v1.1）

| 文件 | 改动性质 |
|---|---|
| `scripts/board.gd` | **仅新增**视觉状态与绘制函数；棋局状态代码一行未改 |
| `scripts/ui.gd` | 新增全局 Theme、胜负弹窗、合成音效、按钮悬停；AI 调用逻辑未改 |
| `scripts/gomoku_ai.gd` | **完全未改动** |
| `scenes/Main.tscn` | **完全未改动** |
| `project.godot` | 仅新增 `config/version="1.1.0"` |
| `docs/screenshot.png`、`docs/ui_win.png` | 新增配图 |
