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


func _ready() -> void:
	_apply_cjk_theme()
	_setup_difficulty_options()
	_connect_signals()
	_load_ai()
	_refresh_ui()


# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
## Godot 内置字体不含中文字形，这里用系统字体保证中文正常显示
func _apply_cjk_theme() -> void:
	var cjk_font: SystemFont = SystemFont.new()
	cjk_font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
		"Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC", "sans-serif"
	])
	cjk_font.allow_system_fallback = true

	var ui_theme: Theme = Theme.new()
	ui_theme.default_font = cjk_font
	ui_theme.default_font_size = 16
	theme = ui_theme


func _setup_difficulty_options() -> void:
	# 索引 0/1/2 与 gomoku_ai.gd 的 DIFFICULTY_EASY / NORMAL / HARD 对应
	difficulty_option.clear()
	difficulty_option.add_item("简单", 0)
	difficulty_option.add_item("普通", 1)
	difficulty_option.add_item("困难", 2)
	difficulty_option.select(1)


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
	_refresh_ui()
	if board.game_finished or _ai_thinking:
		return
	if _ai != null and board.current_player == AI_COLOR:
		_run_ai_turn()


func _on_game_over(winner: int) -> void:
	if winner == HUMAN_COLOR:
		turn_label.text = "黑棋胜利！"
	elif winner == AI_COLOR:
		turn_label.text = "白棋胜利！"
	else:
		turn_label.text = "和棋"
	if _ai != null and _ai.has_method("reset"):
		_ai.reset()


# ---------------------------------------------------------------------------
# 按钮回调
# ---------------------------------------------------------------------------
func _on_restart_pressed() -> void:
	if _ai_thinking:
		return
	board.restart()
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
			turn_label.text = "黑棋胜利！"
		elif board.winner == AI_COLOR:
			turn_label.text = "白棋胜利！"
		else:
			turn_label.text = "和棋"
	elif board.current_player == BLACK:
		turn_label.text = "黑棋回合"
	else:
		turn_label.text = "白棋回合"

	move_count_label.text = "步数统计：%d 手" % board.get_move_count()
	undo_button.disabled = board.get_move_count() == 0 or _ai_thinking
