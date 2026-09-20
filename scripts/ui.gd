extends Control
##
## 五子棋界面控制 —— ui.gd
##
## 挂载在 Main.tscn 的根节点 BoardUI (Control) 上。
##
## 职责：
##   1. 顶部轮次提示、右侧玩法设置面板、胜负弹窗的刷新
##   2. 把 ChessBoard 的信号接到界面
##   3. 驱动 AI：从 res://scripts/gomoku_ai.gd 取招，再交给 board.set_ai_move()
##   4. 玩法参数（棋盘大小 / 连珠数 / AI 难度）的下发
##
## 本脚本不实现任何 AI 算法，只做调用与界面联动。
##

## AI 算法脚本路径（缺失时界面自动降级为双人对弈）
const AI_SCRIPT_PATH: String = "res://scripts/gomoku_ai.gd"

# ---------------------------------------------------------------------------
# 与 board.gd 保持一致的常量
# ---------------------------------------------------------------------------
const EMPTY: int = 0
const BLACK: int = 1
const WHITE: int = 2

## 玩家执子颜色 —— 由右侧「执子」选项切换（执黑先行 / 执白后行）
var human_color: int = BLACK

## AI 执子颜色 —— 恒为玩家的对手色
var ai_color: int = WHITE

const THINK_DELAY: float = 0.12   ## 让「AI 思考中…」先绘制的短暂延迟

## 玩法参数范围（与 board.gd 的常量保持一致）
const MIN_BOARD_SIZE: int = 9
const MAX_BOARD_SIZE: int = 19

## 棋盘边长只取奇数：9 / 11 / 13 / 15 / 17 / 19
const BOARD_SIZE_STEP: int = 2

## 连珠数下限固定为 5 —— 不存在「五珠以下」的玩法
const MIN_WIN_COUNT: int = 5
const MAX_WIN_COUNT: int = 6
const MIN_AI_LEVEL: int = 1
const MAX_AI_LEVEL: int = 3

const SLIDER_DEBOUNCE: float = 0.30   ## 滑块防抖：拖动停止后才重建棋局

# ---------------------------------------------------------------------------
# 木色主题配色
# ---------------------------------------------------------------------------
const COLOR_INK: Color = Color(0.243, 0.153, 0.137, 1.0)        ## #3E2723 深棕
const COLOR_INK_DEEP: Color = Color(0.169, 0.106, 0.090, 1.0)   ## 更深一档
const COLOR_PANEL: Color = Color(1.0, 1.0, 1.0, 0.667)          ## #FFFFFFAA
const COLOR_PANEL_EDGE: Color = Color(0.545, 0.400, 0.259, 0.55)
const COLOR_BTN: Color = Color(0.914, 0.824, 0.667, 0.94)       ## 暖木按钮
const COLOR_BTN_HOVER: Color = Color(0.965, 0.902, 0.784, 0.98)
const COLOR_BTN_DOWN: Color = Color(0.820, 0.706, 0.529, 1.0)
const COLOR_ACCENT: Color = Color(0.600, 0.361, 0.161, 1.0)     ## #996633 棕金
const COLOR_CREAM: Color = Color(1.0, 0.965, 0.878, 1.0)
const COLOR_TEXT_DIM: Color = Color(0.435, 0.325, 0.267, 1.0)

const OUTLINE_SIZE: int = 7       ## 回合提示描边粗细
const HOVER_SCALE: float = 1.06   ## 按钮悬停放大倍率

# ---------------------------------------------------------------------------
# 节点引用（board / _ai 故意不加静态类型：它们的脚本在解析期不可见）
# ---------------------------------------------------------------------------
@onready var board = $ChessBoard
@onready var turn_label: Label = $UILayer/TurnLabel
@onready var start_screen: Control = $UILayer/StartScreen
@onready var start_title: Label = $UILayer/StartScreen/Center/Panel/VBox/TitleLabel
@onready var start_button: Button = $UILayer/StartScreen/Center/Panel/VBox/StartButton
@onready var size_slider: HSlider = $UILayer/RightPanel/SizePanel/SizeBox/SizeSlider
@onready var size_label: Label = $UILayer/RightPanel/SizePanel/SizeBox/SizeLabel
@onready var win_slider: HSlider = $UILayer/RightPanel/WinPanel/WinBox/WinSlider
@onready var win_label: Label = $UILayer/RightPanel/WinPanel/WinBox/WinLabel
@onready var side_option: OptionButton = $UILayer/RightPanel/SidePanel/SideBox/SideOption
@onready var side_label: Label = $UILayer/RightPanel/SidePanel/SideBox/SideLabel
@onready var ai_slider: HSlider = $UILayer/RightPanel/AiPanel/AiBox/AiSlider
@onready var ai_label: Label = $UILayer/RightPanel/AiPanel/AiBox/AiLabel
@onready var restart_button: Button = $UILayer/RightPanel/BtnPanel/BtnBox/RestartButton
@onready var undo_button: Button = $UILayer/RightPanel/BtnPanel/BtnBox/UndoButton
@onready var ai_status_label: Label = $UILayer/RightPanel/InfoPanel/InfoBox/AiStatusLabel
@onready var move_count_label: Label = $UILayer/RightPanel/InfoPanel/InfoBox/MoveCountLabel

## gomoku_ai.gd 的实例（RefCounted）；脚本缺失时为 null
var _ai = null

## 防止 AI 思考期间重复触发
var _ai_thinking: bool = false

## 是否已点过「开始游戏」。未开始前：棋盘锁定、AI 不动、轮次标签显示标题。
var _game_started: bool = false

## 滑块防抖计时器
var _apply_timer: Timer = null

## 胜负弹窗
var _result_layer: Control = null
var _result_panel: PanelContainer = null
var _result_label: Label = null

## 落子音效播放器
var _place_player: AudioStreamPlayer = null


func _ready() -> void:
	_build_theme()
	_setup_labels()
	_setup_sliders()
	_setup_side_option()
	_setup_start_screen()
	_connect_signals()
	_setup_button_hover()
	_build_result_panel()
	_build_sound()
	_load_ai()
	_sync_sliders_from_board()
	_update_rule_labels()
	_refresh_ui()


# ---------------------------------------------------------------------------
# 开始界面
# ---------------------------------------------------------------------------
func _setup_start_screen() -> void:
	_game_started = false
	start_screen.visible = true
	start_screen.modulate.a = 1.0
	start_screen.scale = Vector2.ONE
	# 标题卡用比普通面板更大的留白与投影
	var panel: PanelContainer = $UILayer/StartScreen/Center/Panel
	panel.add_theme_stylebox_override("panel", _title_box())
	start_title.add_theme_font_override("font", _make_font(700))
	_sync_input_lock()


## 标题卡样式
func _title_box() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = Color(1.0, 0.988, 0.949, 0.96)
	box.border_color = COLOR_ACCENT
	box.set_border_width_all(2)
	box.set_corner_radius_all(12)
	box.content_margin_left = 52.0
	box.content_margin_right = 52.0
	box.content_margin_top = 30.0
	box.content_margin_bottom = 30.0
	box.shadow_color = Color(0.2, 0.12, 0.04, 0.35)
	box.shadow_size = 14
	return box


## 未开始时锁住棋盘（重新开始 / 改参数都会把 input_locked 复位，这里统一纠正）
func _sync_input_lock() -> void:
	board.input_locked = not _game_started


## 点击「开始游戏」：标题卡淡出放大后隐藏，解锁棋盘
func _on_start_pressed() -> void:
	if _game_started:
		return
	_game_started = true
	start_screen.pivot_offset = start_screen.size * 0.5
	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(start_screen, "modulate:a", 0.0, 0.35)
	tween.tween_property(start_screen, "scale", Vector2(1.08, 1.08), 0.35).set_trans(
		Tween.TRANS_QUAD
	).set_ease(Tween.EASE_OUT)
	await tween.finished
	start_screen.visible = false
	start_screen.scale = Vector2.ONE
	_sync_input_lock()
	_refresh_ui()
	# 玩家执白时由 AI 先手
	_maybe_start_ai_turn()


# ---------------------------------------------------------------------------
# 初始化：木色全局主题
# ---------------------------------------------------------------------------
## 中文衬线字体：楷体 → 宋体 → 雅黑 → 系统兜底
func _make_font(weight: int) -> SystemFont:
	var serif_font: SystemFont = SystemFont.new()
	serif_font.font_names = PackedStringArray([
		"KaiTi", "楷体", "STKaiti", "SimSun", "宋体", "NSimSun",
		"Microsoft YaHei UI", "Noto Serif CJK SC", "Source Han Serif SC", "serif"
	])
	serif_font.font_weight = weight
	serif_font.allow_system_fallback = true
	return serif_font


## 半透明白色圆角面板（#FFFFFFAA + 8px 圆角）
func _panel_box() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = COLOR_PANEL
	box.border_color = COLOR_PANEL_EDGE
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	box.shadow_color = Color(0.25, 0.15, 0.05, 0.22)
	box.shadow_size = 4
	return box


## 暖木色圆角按钮
func _button_box(bg: Color, border: Color) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 16.0
	box.content_margin_right = 16.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box


func _slider_track() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = Color(0.780, 0.678, 0.549, 0.85)
	box.set_corner_radius_all(4)
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	return box


func _slider_fill() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = COLOR_ACCENT
	box.set_corner_radius_all(4)
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	return box


## 胜负弹窗面板
func _result_box() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = Color(0.996, 0.976, 0.925, 0.97)
	box.border_color = COLOR_ACCENT
	box.set_border_width_all(3)
	box.set_corner_radius_all(14)
	box.content_margin_left = 52.0
	box.content_margin_right = 52.0
	box.content_margin_top = 26.0
	box.content_margin_bottom = 26.0
	box.shadow_color = Color(0.2, 0.12, 0.04, 0.45)
	box.shadow_size = 16
	return box


## 全局主题：木色面板 + 楷体/宋体 + 深棕文字
func _build_theme() -> void:
	var wood_theme: Theme = Theme.new()
	wood_theme.default_font = _make_font(400)
	wood_theme.default_font_size = 15

	# 按钮
	wood_theme.set_stylebox("normal", "Button", _button_box(COLOR_BTN, COLOR_PANEL_EDGE))
	wood_theme.set_stylebox("hover", "Button", _button_box(COLOR_BTN_HOVER, COLOR_ACCENT))
	wood_theme.set_stylebox("pressed", "Button", _button_box(COLOR_BTN_DOWN, COLOR_ACCENT))
	wood_theme.set_stylebox(
		"disabled", "Button",
		_button_box(Color(0.85, 0.80, 0.72, 0.5), Color(0.60, 0.50, 0.40, 0.25))
	)
	wood_theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	wood_theme.set_color("font_color", "Button", COLOR_INK)
	wood_theme.set_color("font_hover_color", "Button", COLOR_INK_DEEP)
	wood_theme.set_color("font_pressed_color", "Button", Color(0.35, 0.18, 0.06))
	wood_theme.set_color("font_disabled_color", "Button", Color(0.55, 0.48, 0.42))
	wood_theme.set_font_size("font_size", "Button", 16)

	# 文字与面板统一深棕
	wood_theme.set_color("font_color", "Label", COLOR_INK)
	wood_theme.set_stylebox("panel", "PanelContainer", _panel_box())

	# 滑块：暖木轨道 + 棕色已填充区
	wood_theme.set_stylebox("slider", "HSlider", _slider_track())
	wood_theme.set_stylebox("grabber_area", "HSlider", _slider_fill())
	wood_theme.set_stylebox("grabber_area_highlight", "HSlider", _slider_fill())

	theme = wood_theme


## 标题加粗放大
func _setup_labels() -> void:
	turn_label.add_theme_font_override("font", _make_font(700))
	turn_label.add_theme_font_size_override("font_size", 30)
	var title: Label = $UILayer/RightPanel/TitlePanel/TitleLabel
	title.add_theme_font_override("font", _make_font(700))


## 滑块：拖动中只刷文字，拖动结束（或停止改动 0.3s）才重建棋局
func _setup_sliders() -> void:
	size_slider.min_value = MIN_BOARD_SIZE
	size_slider.max_value = MAX_BOARD_SIZE
	size_slider.step = float(BOARD_SIZE_STEP)   # 只产生奇数：9/11/13/15/17/19
	win_slider.min_value = MIN_WIN_COUNT
	win_slider.max_value = MAX_WIN_COUNT
	win_slider.step = 1.0
	ai_slider.min_value = MIN_AI_LEVEL
	ai_slider.max_value = MAX_AI_LEVEL
	ai_slider.step = 1.0

	for slider in [size_slider, win_slider, ai_slider]:
		slider.value_changed.connect(_on_slider_changed)
		slider.drag_ended.connect(_on_slider_drag_ended)

	_apply_timer = Timer.new()
	_apply_timer.name = "RuleApplyTimer"
	_apply_timer.one_shot = true
	_apply_timer.wait_time = SLIDER_DEBOUNCE
	_apply_timer.timeout.connect(_apply_slider_rules)
	add_child(_apply_timer)


## 「执子」下拉：执黑先行 / 执白后行
func _setup_side_option() -> void:
	side_option.clear()
	side_option.add_item("执黑 · 先行", 0)
	side_option.add_item("执白 · 后行", 1)
	side_option.select(0)


func _on_side_selected(index: int) -> void:
	if _ai_thinking:
		return
	if index == 0:
		human_color = BLACK
		ai_color = WHITE
	else:
		human_color = WHITE
		ai_color = BLACK
	_update_rule_labels()
	_restart_round()   # 换边必须重开一局


## 重开一局；若轮到 AI 先手（玩家执白）则自动启动 AI 回合
func _restart_round() -> void:
	board.restart()
	_sync_input_lock()   # restart 会把 input_locked 复位，未开始时必须重新锁上
	_hide_result_panel()
	if _ai != null and _ai.has_method("reset"):
		_ai.reset()
	_refresh_ui()
	_maybe_start_ai_turn()


## 当前轮到 AI 且对局未结束时启动 AI 回合
func _maybe_start_ai_turn() -> void:
	if not _game_started:
		return
	if _ai == null or _ai_thinking or board.game_finished:
		return
	if board.current_player == ai_color:
		_run_ai_turn()


func _connect_signals() -> void:
	board.stone_placed.connect(_on_stone_placed)
	board.game_over.connect(_on_game_over)
	restart_button.pressed.connect(_on_restart_pressed)
	undo_button.pressed.connect(_on_undo_pressed)
	side_option.item_selected.connect(_on_side_selected)
	start_button.pressed.connect(_on_start_pressed)


## 尝试加载 AI 脚本；失败时界面仍可作为双人对弈使用
func _load_ai() -> void:
	if not ResourceLoader.exists(AI_SCRIPT_PATH):
		ai_status_label.text = "AI 未接入\n（缺少 gomoku_ai.gd）"
		return
	var ai_script: GDScript = load(AI_SCRIPT_PATH)
	if ai_script == null:
		ai_status_label.text = "AI 脚本加载失败"
		return
	_ai = ai_script.new()
	if _ai == null:
		ai_status_label.text = "AI 实例化失败"
		return
	_push_rules_to_ai()
	ai_status_label.text = "AI 待命"


## 把当前玩法参数下发给 AI
func _push_rules_to_ai() -> void:
	if _ai == null:
		return
	if _ai.has_method("set_rules"):
		_ai.set_rules(int(win_slider.value))
	if _ai.has_method("set_difficulty"):
		_ai.set_difficulty(int(ai_slider.value) - 1)


# ---------------------------------------------------------------------------
# 玩法参数面板
# ---------------------------------------------------------------------------
func _sync_sliders_from_board() -> void:
	size_slider.set_value_no_signal(board.board_size)
	win_slider.set_value_no_signal(board.win_count)
	ai_slider.set_value_no_signal(board.ai_level)
	side_option.select(0 if human_color == BLACK else 1)


func _level_name(level: int) -> String:
	if level <= MIN_AI_LEVEL:
		return "简单"
	if level >= MAX_AI_LEVEL:
		return "困难"
	return "普通"


func _update_rule_labels() -> void:
	var n: int = int(size_slider.value)
	size_label.text = "棋盘大小：%d x %d" % [n, n]
	win_label.text = "连珠数：%d" % int(win_slider.value)
	side_label.text = "执子：%s" % (
		"黑棋（你先手）" if human_color == BLACK else "白棋（AI 先手）"
	)
	ai_label.text = "AI 难度：%s" % _level_name(int(ai_slider.value))


## 拖动过程中只更新文字，绝不重建棋局（避免频繁重绘导致卡顿）
func _on_slider_changed(_value: float) -> void:
	_update_rule_labels()
	if _apply_timer != null:
		_apply_timer.start()   # 防抖：连续拖动会不断顺延


## 拖动结束 → 立刻应用新规则
func _on_slider_drag_ended(_value_changed: bool) -> void:
	if _apply_timer != null:
		_apply_timer.stop()
	_apply_slider_rules()


## 真正重建棋局：应用棋盘大小 / 连珠数 / AI 难度
func _apply_slider_rules() -> void:
	if _ai_thinking:
		# AI 正在思考：稍后重试，别把这次改动静默丢掉
		if _apply_timer != null:
			_apply_timer.start()
		return
	var n: int = int(size_slider.value)
	if n % 2 == 0:
		n += 1                      # 偶数盘没有唯一中心点，统一向上取奇数
	var w: int = int(win_slider.value)
	var level: int = int(ai_slider.value)
	# 连珠数下限 5（不存在五珠以下玩法），且不能超过棋盘边长
	w = clampi(w, MIN_WIN_COUNT, mini(MAX_WIN_COUNT, n))
	if int(win_slider.value) != w:
		win_slider.set_value_no_signal(w)

	board.set_rules(n, w, level)
	_sync_input_lock()   # set_rules→restart 会复位 input_locked
	_push_rules_to_ai()
	if _ai != null and _ai.has_method("reset"):
		_ai.reset()

	_hide_result_panel()
	_update_rule_labels()
	if _ai != null:
		ai_status_label.text = "AI 待命"
	_refresh_ui()
	_maybe_start_ai_turn()


# ---------------------------------------------------------------------------
# 棋盘信号
# ---------------------------------------------------------------------------
func _on_stone_placed(_row: int, _col: int) -> void:
	_play_place_sound()
	_refresh_ui()
	if board.game_finished or _ai_thinking:
		return
	if _ai != null and board.current_player == ai_color:
		_run_ai_turn()


func _on_game_over(winner: int) -> void:
	_refresh_ui()
	if _ai != null and _ai.has_method("reset"):
		_ai.reset()
	_play_place_sound(true)
	_show_result_panel(winner)


# ---------------------------------------------------------------------------
# 按钮回调
# ---------------------------------------------------------------------------
func _on_restart_pressed() -> void:
	if _ai_thinking:
		return
	if _ai != null:
		ai_status_label.text = "AI 待命"
	_restart_round()


func _on_undo_pressed() -> void:
	if _ai_thinking or board.get_move_count() == 0:
		return
	var undone: int = board.undo_to_player(human_color)
	if undone > 0:
		_hide_result_panel()
		if _ai != null and _ai.has_method("reset"):
			_ai.reset()
		if _ai != null:
			ai_status_label.text = "已悔棋 %d 手" % undone
	_refresh_ui()


# ---------------------------------------------------------------------------
# 胜负弹窗
# ---------------------------------------------------------------------------
func _build_result_panel() -> void:
	_result_layer = Control.new()
	_result_layer.name = "ResultLayer"
	_result_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_layer.visible = false
	$UILayer.add_child(_result_layer)

	var center: CenterContainer = CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 纵向只用到 440：弹窗中心落在 y≈250，
	# 避开棋盘中央（第 7 行 y≈380）这条最常见的获胜连线。
	center.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	center.offset_left = 30.0
	center.offset_top = 60.0
	center.offset_right = 670.0
	center.offset_bottom = 440.0
	_result_layer.add_child(center)

	_result_panel = PanelContainer.new()
	_result_panel.add_theme_stylebox_override("panel", _result_box())
	_result_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_result_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_result_panel.add_child(vbox)

	_result_label = Label.new()
	_result_label.add_theme_font_override("font", _make_font(700))
	_result_label.add_theme_font_size_override("font_size", 46)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_result_label)

	var hint: Label = Label.new()
	hint.text = "点击「重新开始」再来一局"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)


## 淡入 + 缩放弹出胜负面板
func _show_result_panel(winner: int) -> void:
	if _result_layer == null:
		return
	if winner == human_color:
		_result_label.text = "你赢了！"
		_result_label.add_theme_color_override("font_color", COLOR_ACCENT)
	elif winner == ai_color:
		_result_label.text = "你输了"
		_result_label.add_theme_color_override("font_color", Color(0.62, 0.20, 0.16))
	else:
		_result_label.text = "和棋"
		_result_label.add_theme_color_override("font_color", COLOR_INK)

	_result_layer.visible = true
	_result_layer.modulate.a = 0.0
	_result_panel.scale = Vector2(0.72, 0.72)
	# 等一帧让容器完成布局，才能拿到正确的 size 做居中缩放
	await get_tree().process_frame
	if not is_instance_valid(_result_panel):
		return
	_result_panel.pivot_offset = _result_panel.size * 0.5

	var tween: Tween = create_tween().set_parallel(true)
	tween.tween_property(_result_layer, "modulate:a", 1.0, 0.28)
	tween.tween_property(_result_panel, "scale", Vector2.ONE, 0.42).set_trans(
		Tween.TRANS_BACK
	).set_ease(Tween.EASE_OUT)


func _hide_result_panel() -> void:
	if _result_layer != null:
		_result_layer.visible = false


# ---------------------------------------------------------------------------
# 按钮悬停放大
# ---------------------------------------------------------------------------
func _setup_button_hover() -> void:
	for node in [restart_button, undo_button, start_button]:
		var btn: Control = node
		btn.pivot_offset = btn.size * 0.5
		btn.mouse_entered.connect(_on_button_hover.bind(btn, true))
		btn.mouse_exited.connect(_on_button_hover.bind(btn, false))


func _on_button_hover(btn: Control, entered: bool) -> void:
	if not is_instance_valid(btn):
		return
	btn.pivot_offset = btn.size * 0.5
	var target: Vector2 = Vector2(HOVER_SCALE, HOVER_SCALE) if entered else Vector2.ONE
	var tween: Tween = create_tween()
	tween.tween_property(btn, "scale", target, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(
		Tween.EASE_OUT
	)


# ---------------------------------------------------------------------------
# 落子音效（用 AudioStreamWAV 现场合成，免外部素材）
# ---------------------------------------------------------------------------
func _build_sound() -> void:
	_place_player = AudioStreamPlayer.new()
	_place_player.name = "PlaceSound"
	_place_player.stream = _make_click_wav()
	_place_player.volume_db = -7.0
	add_child(_place_player)


## 合成一记短促的「砰」：频率快速下滑 + 指数衰减包络
func _make_click_wav() -> AudioStreamWAV:
	var rate: int = 22050
	var count: int = int(rate * 0.12)
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t: float = float(i) / float(rate)
		var freq: float = 430.0 * exp(-20.0 * t) + 72.0
		var env: float = exp(-26.0 * t)
		var sample: float = sin(TAU * freq * t) * env
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


func _play_place_sound(is_win: bool = false) -> void:
	if _place_player == null:
		return
	_place_player.pitch_scale = 0.78 if is_win else 1.0
	_place_player.play()


# ---------------------------------------------------------------------------
# AI 回合
# ---------------------------------------------------------------------------
func _run_ai_turn() -> void:
	if _ai_thinking or board.game_finished:
		return
	_ai_thinking = true
	board.input_locked = true
	ai_status_label.text = "AI 思考中…"

	# 先让界面把「思考中」画出来，再执行同步搜索
	await get_tree().create_timer(THINK_DELAY).timeout
	if not is_instance_valid(board) or board.game_finished:
		_finish_ai_turn("AI 待命")
		return

	var start_ms: int = Time.get_ticks_msec()
	var move: Vector2i = Vector2i(-1, -1)
	if _ai != null and _ai.has_method("get_best_move"):
		move = _ai.get_best_move(board.get_board_state(), ai_color)
	if not _is_legal(move):
		move = _find_fallback_move()
	if move.x < 0:
		_finish_ai_turn("AI 无处可下")
		return

	board.set_ai_move(move.x, move.y, ai_color)
	var elapsed: int = Time.get_ticks_msec() - start_ms

	var status: String = "AI 已落子 (%d, %d)  %d ms" % [move.x, move.y, elapsed]
	if _ai != null and _ai.has_method("get_last_stats"):
		var stats: Dictionary = _ai.get_last_stats()
		if stats.has("depth"):
			status += "  深度 %s" % str(stats["depth"])
	_finish_ai_turn(status)


func _finish_ai_turn(status: String) -> void:
	_ai_thinking = false
	board.input_locked = false
	if status != "":
		ai_status_label.text = status
	_refresh_ui()


func _is_legal(move: Vector2i) -> bool:
	var n: int = board.board_size
	return (
		move.x >= 0 and move.y >= 0
		and move.x < n and move.y < n
		and board.board[move.x][move.y] == EMPTY
	)


## AI 未返回有效落点时的兜底：取第一个空位
func _find_fallback_move() -> Vector2i:
	var n: int = board.board_size
	for row in n:
		for col in n:
			if board.board[row][col] == EMPTY:
				return Vector2i(row, col)
	return Vector2i(-1, -1)


# ---------------------------------------------------------------------------
# 界面刷新
# ---------------------------------------------------------------------------
func _refresh_ui() -> void:
	if not _game_started:
		# 开始界面：顶部显示标题而不是轮次
		_style_turn_label("五子棋 · Gomoku", COLOR_INK, COLOR_CREAM)
		move_count_label.text = "步数统计：0 手"
		undo_button.disabled = true
		return

	if board.game_finished:
		if board.winner == human_color:
			_style_turn_label("黑棋胜利！", COLOR_ACCENT, COLOR_CREAM)
		elif board.winner == ai_color:
			_style_turn_label("白棋胜利！", COLOR_INK_DEEP, COLOR_CREAM)
		else:
			_style_turn_label("和棋", COLOR_INK, COLOR_CREAM)
	elif board.current_player == BLACK:
		# 黑棋回合：深棕字 + 暖白描边
		_style_turn_label("黑棋回合", COLOR_INK_DEEP, COLOR_CREAM)
	else:
		# 白棋回合：米白字 + 深棕描边
		_style_turn_label("白棋回合", COLOR_CREAM, COLOR_INK_DEEP)

	move_count_label.text = "步数统计：%d 手" % board.get_move_count()
	undo_button.disabled = board.get_move_count() == 0 or _ai_thinking


## 回合提示统一走这里：换文案 + 前景色 + 描边色
func _style_turn_label(text: String, fg: Color, outline: Color) -> void:
	turn_label.text = text
	turn_label.add_theme_color_override("font_color", fg)
	turn_label.add_theme_color_override("font_outline_color", outline)
	turn_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
