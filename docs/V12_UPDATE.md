# v1.2 更新说明 · 参数化 / 木色 UI / 滑动调节面板

> 本文档记录 v1.2 四个模块的改动，可直接摘取进比赛文档。
> **v1.2.1 修正**见文末 —— 修掉一个真实的显示 Bug，并收紧连珠数下限、新增「执子」选项。

## 总览

| 模块 | 内容 | 状态 |
|---|---|---|
| 1 | 背景图片处理（webp → png，落入 `assets/ui/`） | ✅ |
| 2 | 玩法参数化（`BOARD_SIZE` / `WIN_COUNT` / `AI_LEVEL`）+ AI 规则自适应 | ✅ |
| 3 | 木色 UI 全面替换（TextureRect 背景 + 暖木棋盘 + 宋楷字体） | ✅ |
| 4 | 右侧信息栏与滑动调节面板（RightPanel + HSlider + 执子选项） | ✅ |

**棋盘数组结构始终未变**：依然是 `board[row][col]` 的二维 `Array`，
`0=空 / 1=黑 / 2=白`。v1.2 只让**尺寸**、**连珠数**与**AI 档位**变成可调参数。

---

## 模块 1 · 背景图片处理

原始素材是 **WebP**（2088×2007, 174 KB），Godot 不能直接当 `Texture2D` 引用 WebP 文件，
因此用引擎自身的图像管线做了一次转换：

```gdscript
var img := Image.load_from_file("res://assets/ui/_src.webp")
img.resize(1600, 1538, Image.INTERPOLATE_LANCZOS)   # 下采样，够 1000x760 窗口用
img.save_png("res://assets/ui/wood_bg.png")
```

- 产物：`assets/ui/wood_bg.png`（1600×1538, 1.8 MB）
- 转换脚本用完即删，仓库里只留最终 PNG
- Godot 首次运行需要 `godot --headless --import` 生成 `.import` 与 `.ctex`，否则
  场景加载会报 `No loader found for resource`（这是踩过的坑，见 CLAUDE.md）

---

## 模块 2 · 玩法参数化与 AI 自适应

### 2.1 board.gd：三个全局参数

```gdscript
var board_size: int = 15   # 9 ~ 19
var win_count:  int = 5    # 3 ~ 6
var ai_level:   int = 2    # 1 ~ 3
```

对外接口：

```gdscript
func set_rules(new_size: int, new_win: int, new_level: int = -1) -> void
```

`set_rules()` 会做三重夹取（含「连珠数不能超过棋盘边长」），重算几何，清空视觉动画记录，
然后重开一局。

### 2.2 几何自适应

棋盘绘制区固定 640×640，格宽与棋子半径随尺寸重算：

| 棋盘 | 格宽 | 棋子半径 | 星位 |
|---|---|---|---|
| 9×9 | 70.0 px | 28.0 px | 仅天元 |
| 11×11 | 56.0 px | 22.4 px | 仅天元 |
| 13×13 | 46.7 px | 18.7 px | 天元 + 4 星位 |
| **15×15** | **40.0 px** | **16.0 px** | 天元 + 4 星位（与原版一致） |
| 19×19 | 31.1 px | 12.4 px | 天元 + 4 星位 |

```gdscript
cell_size    = 560.0 / (board_size - 1)
stone_radius = clampf(cell_size * 0.40, 6.0, 30.0)
```

胜负判定从写死的「5 连」改成 `count >= win_count`；
和棋判定从 `BOARD_SIZE * BOARD_SIZE` 改成 `board_size * board_size`。

### 2.3 gomoku_ai.gd：规则自适应

**① 棋盘尺寸 → 搜索深度**

大棋盘分支因子爆炸，必须收敛深度；小棋盘则可以搜得更深：

```gdscript
base = 5 (n<=9) / 4 (n<=12) / 3 (n<=15) / 2 (n>15)
depth = clampi(base + difficulty - 1, 1, 6)     # EASY=-1 / NORMAL=0 / HARD=+1
```

实测：9×9 普通档跑到 **深度 5 / 465ms**，19×19 普通档 **深度 2 / 9ms**。

**② 连珠数 → 评估权重**

评估函数不再假设「5 连」，而是全部相对于当前连珠数 `w`：

| 连子数 | 含义 | 分值 |
|---|---|---|
| `>= w` | 达成连珠 | `SCORE_FIVE` = 1,000,000 |
| `== w-1`，两端空 | 活四 | `SCORE_OPEN_FOUR` = 100,000 |
| `== w-1`，一端空 | 冲四 | `SCORE_FOUR` = 10,000 |
| `== w-2`，两端空 | 活三 | 见下方动态权重 |
| `== w-2`，一端空 | 眠三 | `SCORE_SLEEPING_THREE` = 100 |
| `== w-3`，两端空 | 活二 | `SCORE_OPEN_TWO` = 10 |

**活三权重随连珠数动态提升**（这是本模块的核心）：

```gdscript
if _win_count <= 3:  return SCORE_OPEN_FOUR / 2    #  50,000 —— 三连几乎等同胜势
if _win_count == 4:  return SCORE_OPEN_THREE * 10  #  10,000 —— 提升到冲四同级
return SCORE_OPEN_THREE                            #   1,000 —— 标准五子棋
```

原因：连珠数越少，「活三 → 活四 → 取胜」的链条越短。4 连规则下活三只需两步就能赢，
若仍按标准五子棋的 1000 分处理，AI 会严重低估威胁。

**③ 边界安全**

候选点生成、成五点搜索、活四点搜索三处循环都加了显式保护：

```gdscript
for r in _n:
    if r < 0 or r >= _n: continue
    var base: int = (r + PAD) * _w + PAD
    for c in _n:
        if c < 0 or c >= _n: continue
        var idx: int = base + c
        if idx < 0 or idx >= cell_count: continue
```

底层棋盘本身带 `PAD=2` 的 `WALL` 哨兵边界，所以扫描永不越界；
这些守卫是针对「尺寸可变」新增的第二道保险。

### 2.4 验证结果

7 组尺寸/连珠组合 × 11 项断言 = **77 条全部通过**：

| 组合 | 格宽 | 棋子半径 | 判胜 | AI 深度 | AI 耗时 |
|---|---|---|---|---|---|
| 9×9 / 4连 | 70.0 | 28.0 | ✅ | 5 | 465 ms |
| 9×9 / 3连 | 70.0 | 28.0 | ✅ | 5 | 0 ms（战术预检） |
| 11×11 / 6连 | 56.0 | 22.4 | ✅ | 4 | 140 ms |
| 13×13 / 5连 | 46.7 | 18.7 | ✅ | 3 | 28 ms |
| 15×15 / 5连 | 40.0 | 16.0 | ✅ | 3 | 28 ms |
| 19×19 / 5连 | 31.1 | 12.4 | ✅ | 2 | 9 ms |
| 19×19 / 4连 | 31.1 | 12.4 | ✅ | 2 | 1 ms |

同时验证了：`win_count - 1` 子**不**判胜、刚好 `win_count` 子判胜、越界落子被拒。

---

## 模块 3 · 木色 UI 全面替换

### 3.1 背景层

`Main.tscn` 的第一个子节点从 `ColorRect` 换成 `TextureRect`：

```
expand_mode  = 1   # EXPAND_IGNORE_SIZE
stretch_mode = 6   # STRETCH_KEEP_ASPECT_COVERED
```

> 取舍：源图接近正方形（1600×1538），窗口是 1000×760（≈1.32:1）。
> `Keep Aspect Covered` 会等比放大到铺满，代价是**上下各裁掉约 100px**，
> 背景图的回纹外框上下两边会被裁掉一部分（左右两边完整保留）。

### 3.2 棋盘底色

棋盘不再是不透明木色，而是**半透明暖木叠加**，让底层羊皮纸纹理透出来：

```gdscript
draw_texture_rect(_wood_texture, rect, false, Color(1, 1, 1, 0.55))
```

外框改为双层（外粗深棕 + 内细浅棕），做出木牌厚度。棋子半径、边缘压暗宽度、
最后一手标记半径全部改成**按 `stone_radius` 比例计算**，所以 9~19 路都协调。

### 3.3 字体与配色

| 项 | 值 |
|---|---|
| 字体族 | `KaiTi → 楷体 → STKaiti → SimSun → 宋体 → NSimSun → 微软雅黑 → Noto Serif CJK` |
| 正文色 | **`#3E2723`** 深棕 |
| 更深一档 | `#2B1B17` |
| 面板底 | **`#FFFFFFAA`** 半透明白 |
| 面板描边 | `#8B6642` @ 55% |
| 强调色 | `#996633` 棕金 |

> 字体用 `SystemFont` + 回退链而非内置字体：Godot 内置字体**不含 CJK 字形**，
> 直接用会显示成方框。

---

## 模块 4 · 右侧滑动调节面板

### 4.1 结构

```
UILayer/RightPanel  (VBoxContainer, x 686~976 = 290px, alignment=CENTER 垂直居中)
├── TitlePanel  → 「玩法设置」
├── SizePanel   → 「棋盘大小：15 x 15」 + HSlider(9~19, step 1)
├── WinPanel    → 「连珠数：5」        + HSlider(3~6,  step 1)
├── AiPanel     → 「AI 难度：普通」    + HSlider(1~3,  step 1)
├── BtnPanel    → [重新开始] [悔棋]
└── InfoPanel   → AI 状态 / 步数统计
```

每个分组都用 `PanelContainer` 包裹，统一套用 `StyleBoxFlat`：
圆角 8px、`#FFFFFFAA` 底色、`#8B6642` 描边、4px 投影 —— 从木纹背景中清晰浮起。

### 4.2 滑动条防抖（关键稳定性设计）

**问题**：拖动 `HSlider` 时 `value_changed` 会以每秒几十次的频率触发。
若每次都重建棋局（重新分配棋盘数组、重算 AI 线表、重绘），会明显卡顿甚至崩溃。

**方案**：双层防护

```gdscript
# 拖动中：只更新标签文字，绝不重建
func _on_slider_changed(_value: float) -> void:
    _update_rule_labels()
    _apply_timer.start()      # 0.3s 一次性定时器，连续拖动会不断顺延

# 拖动结束：立刻应用
func _on_slider_drag_ended(_value_changed: bool) -> void:
    _apply_timer.stop()
    _apply_slider_rules()
```

- `drag_ended` 满足「拖动结束才重建」的明确要求
- 定时器兜底覆盖**非拖动**的改值方式（点击滑轨、方向键），
  这类操作不会发 `drag_ended`，只靠它会导致改了不生效

**实测**：把三个滑块连续改成 12/5/3 后立即检查，棋盘仍是 15×15；
发出 `drag_ended` 后才重建为 12×12 且棋盘清空。防抖生效。

### 4.3 容错

按需求预留了降级方案（若 HSlider 出现难以处理的 Bug 可换成
`OptionButton` 固定预设 9×9-4连 / 13×13-5连 / 15×15-5连）。
**实际开发中 HSlider 一次跑通，未触发降级。**

---

## 验证汇总

| 项目 | 结果 |
|---|---|
| 三个脚本语法检查 | ✅ 全部通过 |
| 主场景无头运行 120 帧 | ✅ 无 ERROR |
| 玩法参数化（7 组组合 × 11 断言） | ✅ 77/77 |
| 滑动条防抖（拖动中不重建） | ✅ |
| `drag_ended` 后重建 | ✅ |
| 9×9 / 19×19 人机对弈 | ✅ 正常应手 |
| 字体族生效 | ✅ `KaiTi` 在首位 |
| 多尺寸截图 | ✅ `ui_9x9.png` / `screenshot.png` / `ui_19x19.png` |

## 文件改动清单（v1.2）

| 文件 | 改动 |
|---|---|
| `assets/ui/wood_bg.png` | **新增** 背景图（由 webp 转换） |
| `scenes/Main.tscn` | 重写：ColorRect → TextureRect；BottomBar/SidePanel → RightPanel |
| `scripts/board.gd` | 参数化尺寸/连珠数；几何与绘制全面动态化 |
| `scripts/gomoku_ai.gd` | 新增 `set_rules()`；深度随尺寸、权重随连珠数；边界守卫 |
| `scripts/ui.gd` | 重写：木色主题、RightPanel、滑块防抖、胜负弹窗上移 |
| `project.godot` | 版本号 → 1.2.0 |
| `docs/ui_9x9.png`、`ui_19x19.png` | 新增配图 |

---

# v1.2.1 修正

## 修正 1 · 连珠数下限收紧为 5

**问题**：v1.2 的连珠数滑块范围是 3~6，存在「五珠以下」的玩法，不符合规则。

**修正**：下限固定为 **5**，三层同时收紧，防止绕过 UI 直接调 API：

| 位置 | 措施 |
|---|---|
| `Main.tscn` | `WinSlider.min_value = 5`（滑块拖不到 5 以下） |
| `ui.gd` | `MIN_WIN_COUNT = 5`，`_apply_slider_rules()` 里 `clampi` |
| `board.gd` | `MIN_WIN_COUNT = 5`，`set_rules()` 里再 `clampi` 一次 |

> `gomoku_ai.gd` 的 `set_rules()` 仍按 3~6 夹取 —— 那是**算法自身的兼容范围**
> （便于复用），规则层的 5~6 限制由前三者负责。

**实测**：滑块下限 = 5；强行 `win_slider.value = 3` 被夹到 5；
`board.set_rules(15, 3)` 后 `win_count == 5`。

## 修正 2 · 调整棋盘大小的显示 Bug（真实崩溃级问题）

### 根因

鼠标停在 **19 路**棋盘右下角时，`_hover_cell = (17, 17)`。
此时把棋盘切到 **9 路**，在**同一帧**的 `_draw()` 里仍用旧坐标索引新数组：

```
SCRIPT ERROR: Out of bounds get index '17' (on base: 'Array')
   at: _draw_ghost_stone (res://scripts/board.gd:524)
```

**关键点**：`_draw()` 里任何一次越界报错都会**中断整个 `_draw()`**，
于是排在 `_draw_ghost_stone()` 之后的 `_draw_stones()` 与 `_draw_last_marker()`
被直接跳过 —— **棋子整帧画不出来**。用户看到的就是「调大小后棋盘显示坏了」。

更糟的是：如果切换后鼠标恰好还映射到与旧值相同的格子，`_update_hover()`
认为「悬停格没变」就不会再 `queue_redraw()`，棋子可能**持续不显示**。

### 修正（三重防护）

1. `set_rules()` 里显式清空 `_hover_cell = Vector2i(-1, -1)`
2. `_draw_ghost_stone()` 加 `is_inside()` **加**数组实际尺寸双重判断
3. `_draw_stones()` 改为按 `mini(board_size, board.size())` 遍历实际数组，
   即便尺寸变量与数组短暂不同步也不会越界

### 复现与验证

| 步骤 | 修正前 | 修正后 |
|---|---|---|
| 19 路悬停右下角 → 切 9 路 | `Out of bounds get index '17'` | 无任何报错 |
| 切换后 `_hover_cell` | 残留 `(17,17)` | 重置为 `(-1,-1)` |
| 切换后棋子 | 该帧丢失 | 正常绘制 |

> 另用「初始就是 9 路」vs「15→19→9 切换过去」做**像素级 A/B 对比** ——
> 76 万像素**零差异**，确认切换不残留任何渲染状态。

## 修正 3 · 右侧新增「执子 / 先后手」选项

新增 `SidePanel`，内含 `OptionButton`：

| 选项 | 含义 |
|---|---|
| 执黑 · 先行 | 玩家执黑先手（默认） |
| 执白 · 后行 | 玩家执白，**AI 执黑先手** |

配套改动：

- `HUMAN_COLOR` / `AI_COLOR` 由 `const` 改为 `human_color` / `ai_color` **变量**
- 新增 `_maybe_start_ai_turn()`：轮到 AI 且对局未结束时自动启动 AI 回合 ——
  玩家执白时用它实现「AI 先手」
- 新增 `_restart_round()`：重开一局并在需要时让 AI 先手（重新开始按钮、换边、改参数共用）
- 胜负文案按 `human_color` 判定「你赢了 / 你输了」
- 悔棋改为 `undo_to_player(human_color)`
- 侧栏标签同时显示「执子：白棋（AI 先手）」，一眼看出当前先后手

**顺带修掉**：`_apply_slider_rules()` 原先在 `_ai_thinking` 时**直接 return**，
会把这次改动**静默丢弃**（滑块显示 19 但棋盘还是 15）。
现在改为重新启动防抖定时器，稍后重试。

**实测**：切到「执白 · 后行」后 AI 立即落下一枚**黑棋**；玩家随后落的是**白棋**；
切回「执黑 · 先行」后重开为空盘且轮到玩家先手。

## v1.2.1 验证汇总

21 条断言全部通过：

| 分组 | 断言数 | 结果 |
|---|---|---|
| 连珠数下限 = 5（滑块下限 / 强行设值 / API 直调） | 4 | ✅ |
| 调整棋盘大小不再越界（含 hover 重置） | 3 | ✅ |
| 执子 / 先后手（含 AI 先手、玩家执白落子、换边重开） | 14 | ✅ |
| 三个脚本语法检查 + 主场景无头运行 | — | ✅ 无 ERROR |

## v1.2.1 文件改动

| 文件 | 改动 |
|---|---|
| `scripts/board.gd` | `MIN_WIN_COUNT` → 5；`set_rules()` 清 `_hover_cell`；`_draw_ghost_stone()` / `_draw_stones()` 加边界保护 |
| `scripts/ui.gd` | `MIN_WIN_COUNT` → 5；`human_color`/`ai_color` 变量化；新增执子选项、`_restart_round()`、`_maybe_start_ai_turn()`；`_apply_slider_rules()` 不再丢弃改动 |
| `scenes/Main.tscn` | `WinSlider.min_value` → 5；新增 `SidePanel`（执子下拉） |
| `scripts/gomoku_ai.gd` | 仅补充注释（说明算法兼容 3~6，规则层限制 5~6） |
| `project.godot` | 版本号 → 1.2.1 |
