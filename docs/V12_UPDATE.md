# v1.2 更新说明 · 参数化 / 木色 UI / 滑动调节面板

> 本文档记录 v1.2 四个模块的改动，可直接摘取进比赛文档。

## 总览

| 模块 | 内容 | 状态 |
|---|---|---|
| 1 | 背景图片处理（webp → png，落入 `assets/ui/`） | ✅ |
| 2 | 玩法参数化（`BOARD_SIZE` / `WIN_COUNT` / `AI_LEVEL`）+ AI 规则自适应 | ✅ |
| 3 | 木色 UI 全面替换（TextureRect 背景 + 暖木棋盘 + 宋楷字体） | ✅ |
| 4 | 右侧信息栏与滑动调节面板（RightPanel + HSlider） | ✅ |

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
