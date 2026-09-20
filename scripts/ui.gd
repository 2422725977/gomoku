extends Control
##
## 五子棋界面控制 —— ui.gd
##
## 挂载在 Main.tscn 的根节点 BoardUI (Control) 上。
##
## 职责：
##   1. 顶部轮次提示、底部按钮栏、右侧信息面板的刷新
##   2. 把 ChessBoard 的信号接到界面
##   3. 驱动 AI：从 res://scripts/gomoku_ai.gd 取招，再交给 board.set_ai_move()
##
## 本脚本不实现任何 AI 算法，只做调用与界面联动。
##

## AI 算法脚本路径（由并行的 AI 开发任务提供；缺失时界面自动降级为双人对弈）
const AI_SCRIPT_PATH: String = "res://scripts/gomoku_ai.gd"

# ---------------------------------------------------------------------------
# 与 board.gd 保持一致的常量
# ---------------------------------------------------------------------------
const BOARD_SIZE: int = 15
const EMPTY: int = 0
const BLACK: int = 1
const WHITE: int = 2

## 玩家执黑先行，AI 执白
const HUMAN_COLOR: int = BLACK
const AI_COLOR: int = WHITE

const THINK_DELAY: float = 0.12   ## 让「AI 思考中…」先绘制的短暂延迟

# ---------------------------------------------------------------------------
# 主题配色
# ---------------------------------------------------------------------------
const COLOR_BTN_BG: Color = Color(0.227, 0.263, 0.337, 1.0)        ## #3A4356
const COLOR_BTN_BG_HOVER: Color = Color(0.290, 0.337, 0.431, 1.0)  ## #4A566E
const COLOR_BTN_BG_DOWN: Color = Color(0.169, 0.196, 0.259, 1.0)   ## #2B3242
const COLOR_ACCENT: Color = Color(0.851, 0.643, 0.255, 1.0)        ## #D9A441
const COLOR_TEXT: Color = Color(0.902, 0.922, 0.961, 1.0)
const COLOR_TEXT_DIM: Color = Color(0.639, 0.675, 0.741, 1.0)

const OUTLINE_SIZE: int = 8       ## 回合提示描边粗细
const HOVER_SCALE: float = 1.06   ## 按钮悬停放大倍率

# ---------------------------------------------------------------------------
# 节点引用（board / _ai 故意不加静态类型：它们的脚本在解析期不可见）
# ---------------------------------------------------------------------------
@onready var board = $ChessBoard
@onready var turn_label: Label = $UILayer/TurnLabel
@onready var restart_button: Button = $UILayer/BottomBar/RestartButton
@onready var undo_button: Button = $UILayer/BottomBar/UndoButton
@onready var difficulty_option: OptionButton = $UILayer/BottomBar/DifficultyOption
@onready var ai_status_label: Label = $UILayer/SidePanel/AiStatusLabel
@onready var move_count_label: Label = $UILayer/SidePanel/MoveCountLabel

## gomoku_ai.gd 的实例（RefCounted）；脚本缺失时为 null
var _ai = null

## 防止 AI 思考期间重复触发
var _ai_thinking: bool = false

## 胜负弹窗
var _result_layer: Control = null
var _result_panel: PanelContainer = null
var _result_label: Label = null

## 落子音效播放器
var _place_player: AudioStreamPlayer = null


func _ready() -> void:
	_build_theme()
	_setup_labels()
	_setup_difficulty_options()
	_connect_signals()
	_setup_button_hover()
	_build_result_panel()
	_build_sound()
	_load_ai()
	_refresh_ui()


# ---------------------------------------------------------------------------
# 初始化：全局主题
# ---------------------------------------------------------------------------
## 中文字体：Godot 内置字体不含 CJK 字形，这里用系统字体并允许回退
func _make_font(weight: int) -> SystemFont:
	var cjk_font: SystemFont = SystemFont.new()
	cjk_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
		"Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC", "sans-serif"
	])
	cjk_font.font_weight = weight
	cjk_font.allow_system_fallback = true
	return cjk_font


## 圆角按钮样式（圆角半径 8px）
func _button_box(bg: Color, border: Color) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 9.0
	box.content_margin_bottom = 9.0
	return box


## 胜负弹窗面板样式
func _result_box() -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = Color(0.129, 0.149, 0.196, 0.96)
	box.border_color = COLOR_ACCENT
	box.set_border_width_all(2)
	box.set_corner_radius_all(14)
	box.content_margin_left = 52.0
	box.content_margin_right = 52.0
	box.content_margin_top = 26.0
	box.content_margin_bottom = 26.0
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	box.shadow_size = 16
	return box


## 全局主题：中文字体 + 圆角按钮（含悬停 / 按下 / 禁用态配色）
## OptionButton 继承自 Button，会自动套用同一套样式。
func _build_theme() -> void:
	var ui_theme: Theme = Theme.new()
	ui_theme.default_font = _make_font(400)
	ui_theme.default_font_size = 16

	ui_theme.set_stylebox(
		"normal", "Button", _button_box(COLOR_BTN_BG, Color(0.33, 0.38, 0.47))
	)
	ui_theme.set_stylebox("hover", "Button", _button_box(COLOR_BTN_BG_HOVER, COLOR_ACCENT))
	ui_theme.set_stylebox("pressed", "Button", _button_box(COLOR_BTN_BG_DOWN, COLOR_ACCENT))
	ui_theme.set_stylebox(
		"disabled", "Button", _button_box(Color(0.16, 0.18, 0.23), Color(0.23, 0.25, 0.31))
	)
	ui_theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	ui_theme.set_color("font_color", "Button", COLOR_TEXT)
	ui_theme.set_color("font_hover_color", "Button", Color.WHITE)
	ui_theme.set_color("font_pressed_color", "Button", COLOR_ACCENT)
	ui_theme.set_color("font_disabled_color", "Button", Color(0.42, 0.45, 0.53))
	ui_theme.set_font_size("font_size", "Button", 16)

	ui_theme.set_color("font_color", "Label", COLOR_TEXT)
	ui_theme.set_stylebox("panel", "PanelContainer", _result_box())

	theme = ui_theme


## 标题类文字统一加粗、放大
func _setup_labels() -> void:
	turn_label.add_theme_font_override("font", _make_font(700))
	turn_label.add_theme_font_size_override("font_size", 30)

	var side_title: Label = $UILayer/SidePanel/SideTitleLabel
	side_title.add_theme_font_override("font", _make_font(700))
	side_title.add_theme_font_size_override("font_size", 19)


## 按钮悬停时轻微放大
func _setup_button_hover() -> void:
	for node in [restart_button, undo_button, difficulty_option]:
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


func _setup_difficulty_options() -> void:
	# 索引 0/1/2 与 gomoku_ai.gd 的 DIFFICULTY_EASY / NORMAL / HARD 对应
	difficulty_option.clear()
	difficulty_option.add_item("简单", 0)
	difficulty_option.add_item("普通", 1)
	difficulty_option.add_item("困难", 2)
	difficulty_option.select(1)


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
	# 与棋盘区域对齐（ChessBoard 位于 (40,60)，尺寸 640x640），
	# 这样弹窗落在棋盘正中，而不是整个窗口的中偏右。
	center.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	center.offset_left = 40.0
	center.offset_top = 60.0
	center.offset_right = 680.0
	center.offset_bottom = 700.0
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
	if winner == HUMAN_COLOR:
		_result_label.text = "你赢了！"
		_result_label.add_theme_color_override("font_color", COLOR_ACCENT)
	elif winner == AI_COLOR:
		_result_label.text = "你输了"
		_result_label.add_theme_color_override("font_color", Color(0.87, 0.44, 0.44))
	else:
		_result_label.text = "和棋"
		_result_label.add_theme_color_override("font_color", COLOR_TEXT)

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


func _connect_signals() -> void:
	board.stone_placed.connect(_on_stone_placed)
	board.game_over.connect(_on_game_over)
	restart_button.pressed.connect(_on_restart_pressed)
	undo_button.pressed.connect(_on_undo_pressed)
	difficulty_option.item_selected.connect(_on_difficulty_selected)


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
	if _ai.has_method("set_difficulty"):
		_ai.set_difficulty(difficulty_option.selected)
	ai_status_label.text = "AI 待命"


# ---------------------------------------------------------------------------
# 棋盘信号
# ---------------------------------------------------------------------------
func _on_stone_placed(_row: int, _col: int) -> void:
	_play_place_sound()
	_refresh_ui()
	if board.game_finished or _ai_thinking:
		return
	if _ai != null and board.current_player == AI_COLOR:
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
	board.restart()
	_hide_result_panel()
	if _ai != null and _ai.has_method("reset"):
		_ai.reset()
	if _ai != null:
		ai_status_label.text = "AI 待命"
	_refresh_ui()


func _on_undo_pressed() -> void:
	if _ai_thinking or board.get_move_count() == 0:
		return
	var undone: int = board.undo_to_player(HUMAN_COLOR)
	if undone > 0:
		_hide_result_panel()
		if _ai != null and _ai.has_method("reset"):
			_ai.reset()
		if _ai != null:
			ai_status_label.text = "已悔棋 %d 手" % undone
	_refresh_ui()


func _on_difficulty_selected(index: int) -> void:
	if _ai != null and _ai.has_method("set_difficulty"):
		_ai.set_difficulty(index)
		ai_status_label.text = "难度已切换：%s" % difficulty_option.get_item_text(index)


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
		move = _ai.get_best_move(board.get_board_state(), AI_COLOR)
	if not _is_legal(move):
		move = _find_fallback_move()
	if move.x < 0:
		_finish_ai_turn("AI 无处可下")
		return

	board.set_ai_move(move.x, move.y, AI_COLOR)
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
	return (
		move.x >= 0 and move.y >= 0
		and move.x < BOARD_SIZE and move.y < BOARD_SIZE
		and board.board[move.x][move.y] == EMPTY
	)


## AI 未返回有效落点时的兜底：取第一个空位
func _find_fallback_move() -> Vector2i:
	for row in BOARD_SIZE:
		for col in BOARD_SIZE:
			if board.board[row][col] == EMPTY:
				return Vector2i(row, col)
	return Vector2i(-1, -1)


# ---------------------------------------------------------------------------
# 界面刷新
# ---------------------------------------------------------------------------
func _refresh_ui() -> void:
	if board.game_finished:
		if board.winner == HUMAN_COLOR:
			_style_turn_label("黑棋胜利！", COLOR_ACCENT, Color(0.12, 0.08, 0.0))
		elif board.winner == AI_COLOR:
			_style_turn_label("白棋胜利！", Color(0.97, 0.97, 1.0), Color(0.08, 0.08, 0.12))
		else:
			_style_turn_label("和棋", COLOR_TEXT, Color(0.04, 0.05, 0.08))
	elif board.current_player == BLACK:
		# 黑棋回合：白字 + 深色描边
		_style_turn_label("黑棋回合", Color(0.98, 0.98, 1.0), Color(0.04, 0.05, 0.08))
	else:
		# 白棋回合：深字 + 浅色描边
		_style_turn_label("白棋回合", Color(0.09, 0.10, 0.13), Color(0.92, 0.92, 0.96))

	move_count_label.text = "步数统计：%d 手" % board.get_move_count()
	undo_button.disabled = board.get_move_count() == 0 or _ai_thinking


## 回合提示统一走这里：换文案 + 前景色 + 描边色
func _style_turn_label(text: String, fg: Color, outline: Color) -> void:
	turn_label.text = text
	turn_label.add_theme_color_override("font_color", fg)
	turn_label.add_theme_color_override("font_outline_color", outline)
	turn_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
