extends Node2D
##
## 五子棋棋盘 —— board.gd
##
## 职责：
##   1. 在 _draw() 中绘制 15x15 棋盘网格、星位与棋子（带阴影）
##   2. 通过 _input() 监听鼠标左键，把屏幕坐标换算为最近的网格交叉点
##   3. 维护对局状态（当前行动方、历史记录、胜负判定）
##
## 本脚本【不包含任何 AI 算法】。AI 通过预留接口 set_ai_move(row, col) 落子。
##

## 落子成功后发出（人类与 AI 落子都会发出）
signal stone_placed(row: int, col: int)

## 对局结束（winner: 1 = 黑棋, 2 = 白棋, 0 = 和棋）
signal game_over(winner: int)


# ---------------------------------------------------------------------------
# 玩法参数（可在运行时调整）
# 【重要】棋盘数据结构不变：依然是 board[row][col] 的二维数组，
# 0=空 / 1=黑 / 2=白。改动只影响尺寸、连珠数与 AI 档位。
# ---------------------------------------------------------------------------
const MIN_BOARD_SIZE: int = 9
const MAX_BOARD_SIZE: int = 19
const MIN_WIN_COUNT: int = 3
const MAX_WIN_COUNT: int = 6
const MIN_AI_LEVEL: int = 1
const MAX_AI_LEVEL: int = 3

## 棋盘交叉点数（9-19），默认 15
var board_size: int = 15

## 连珠取胜所需子数（3-6），默认 5
var win_count: int = 5

## AI 难度档（1-3），默认 2（普通）
var ai_level: int = 2

# ---------------------------------------------------------------------------
# 棋盘几何（随 board_size 自适应；15 路时恰好回到「每格 40px、留白 40px」）
# ---------------------------------------------------------------------------
const BOARD_PX: float = 640.0       ## 棋盘绘制区域固定 640x640
const BOARD_MARGIN: float = 40.0    ## 网格四周留白

var cell_size: float = 40.0         ## 每格像素
var grid_px: float = 560.0          ## 网格跨度 = (board_size - 1) * cell_size
var origin_x: float = 40.0          ## 网格起点
var origin_y: float = 40.0
var stone_radius: float = 16.0      ## 棋子半径（随格宽缩放）
var star_radius: float = 3.5        ## 星位圆点半径
var mark_radius: float = 4.0        ## 最后一手标记半径

# ---------------------------------------------------------------------------
# 视觉常量
# ---------------------------------------------------------------------------
const LINE_WIDTH: float = 1.5       ## 网格线宽
const BORDER_WIDTH: float = 2.0     ## 外框线宽
const SHADOW_OFFSET: Vector2 = Vector2(2.5, 2.5)

const COLOR_BOARD: Color = Color(0.878, 0.733, 0.510, 1.0)   ## 棋盘木色（降级用）
const COLOR_BOARD_EDGE: Color = Color(0.545, 0.400, 0.235, 1.0)
const COLOR_LINE: Color = Color(0.353, 0.220, 0.102, 1.0)    ## 深棕色网格线
const COLOR_SHADOW: Color = Color(0.0, 0.0, 0.0, 0.28)       ## 棋子阴影
const COLOR_BLACK: Color = Color(0.106, 0.106, 0.118, 1.0)
const COLOR_WHITE: Color = Color(0.960, 0.960, 0.945, 1.0)
const COLOR_HIGHLIGHT: Color = Color(1.0, 1.0, 1.0, 0.55)
const COLOR_MARK: Color = Color(0.851, 0.196, 0.196, 1.0)    ## 最后一手红点

# ---------------------------------------------------------------------------
# 木质渐变配色（径向：中心 → 边缘）
# ---------------------------------------------------------------------------
const COLOR_WOOD_CENTER: Color = Color(0.941, 0.839, 0.651, 1.0)  ## #F0D6A6
const COLOR_WOOD_MID: Color = Color(0.902, 0.761, 0.502, 1.0)     ## #E6C280
const COLOR_WOOD_EDGE: Color = Color(0.831, 0.655, 0.416, 1.0)    ## #D4A76A

# ---------------------------------------------------------------------------
# 视觉动画参数
# ---------------------------------------------------------------------------
const GHOST_ALPHA: float = 0.4           ## 悬停预览棋子透明度
const DROP_SCALE_FROM: float = 0.5       ## 落子起始缩放（弹跳起点）
const DROP_SCALE_OVERSHOOT: float = 1.2  ## 回弹过冲峰值
const DROP_UP_TIME: float = 0.12         ## 0.5 → 1.2 用时
const DROP_SETTLE_TIME: float = 0.14     ## 1.2 → 1.0 用时
const WIN_FLASH_SPEED: float = 3.2       ## 胜利五连闪烁速度

# ---------------------------------------------------------------------------
# 棋子取值
# ---------------------------------------------------------------------------
const EMPTY: int = 0
const BLACK: int = 1
const WHITE: int = 2

## 连子判定方向：横、竖、右下、右上
const DIRECTIONS: Array = [
	Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, -1)
]


# ---------------------------------------------------------------------------
# 对局状态
# ---------------------------------------------------------------------------
## 15x15 二维数组，board[row][col]，0 = 空，1 = 黑，2 = 白
var board: Array = []

## 当前行动方（BLACK / WHITE）
var current_player: int = BLACK

## 最后一手坐标，(-1, -1) 表示尚无落子
var last_move: Vector2i = Vector2i(-1, -1)

## 是否已分出胜负
var game_finished: bool = false

## 胜者：1 = 黑，2 = 白，0 = 未结束或和棋
var winner: int = 0

## 为 true 时忽略鼠标输入（AI 思考期间由 UI 置位）
var input_locked: bool = false

## 落子历史：[{ "row": int, "col": int, "color": int }]
var move_history: Array = []


# ---------------------------------------------------------------------------
# 视觉状态
# 仅服务渲染与动画，不参与任何棋局判定；棋局状态一律以上方变量为准。
# ---------------------------------------------------------------------------
var _wood_texture: GradientTexture2D = null
var _stone_scale: Dictionary = {}              ## Vector2i -> float，落子弹跳缩放
var _hover_cell: Vector2i = Vector2i(-1, -1)   ## 当前悬停的空交叉点
var _win_line: Array = []                      ## 获胜五连的坐标列表
var _win_active: bool = false
var _win_phase: float = 0.0


func _ready() -> void:
	_update_geometry()
	board = make_empty_board()
	_wood_texture = _build_wood_texture()
	# 只监听落子信号来驱动动画，不介入棋局状态代码
	stone_placed.connect(_on_stone_placed_visual)
	queue_redraw()


# ---------------------------------------------------------------------------
# 玩法参数与几何
# ---------------------------------------------------------------------------
## 依据 board_size 重算全部绘制几何（15 路时格宽恰好 40px）
func _update_geometry() -> void:
	grid_px = BOARD_PX - BOARD_MARGIN * 2.0
	cell_size = grid_px / float(maxi(board_size - 1, 1))
	origin_x = BOARD_MARGIN
	origin_y = BOARD_MARGIN
	stone_radius = clampf(cell_size * 0.40, 6.0, 30.0)
	star_radius = clampf(cell_size * 0.088, 1.5, 5.0)
	mark_radius = clampf(stone_radius * 0.25, 2.0, 6.0)


## 星位（含天元）；小棋盘只保留天元
func _star_points() -> Array:
	var n: int = board_size
	var pts: Array = [Vector2i(n / 2, n / 2)]
	if n >= 13:
		var e: int = 3
		pts.append(Vector2i(e, e))
		pts.append(Vector2i(e, n - 1 - e))
		pts.append(Vector2i(n - 1 - e, e))
		pts.append(Vector2i(n - 1 - e, n - 1 - e))
	return pts


## 应用新规则并重开一局。
## 【注意】棋盘结构不变，仍是 board[row][col]；只是尺寸与连珠数变了。
func set_rules(new_size: int, new_win: int, new_level: int = -1) -> void:
	board_size = clampi(new_size, MIN_BOARD_SIZE, MAX_BOARD_SIZE)
	# 连珠数不能超过棋盘边长
	win_count = clampi(new_win, MIN_WIN_COUNT, mini(MAX_WIN_COUNT, board_size))
	if new_level >= 0:
		ai_level = clampi(new_level, MIN_AI_LEVEL, MAX_AI_LEVEL)
	_update_geometry()
	# 尺寸变了，旧的动画/闪烁记录全部作废
	_stone_scale.clear()
	_win_line.clear()
	_win_active = false
	restart()


# ---------------------------------------------------------------------------
# 棋盘数据
# ---------------------------------------------------------------------------
## 生成 board_size x board_size 的空棋盘（结构仍是 Array[row][col]）
func make_empty_board() -> Array:
	var result: Array = []
	for _row in board_size:
		var line: Array = []
		line.resize(board_size)
		line.fill(EMPTY)
		result.append(line)
	return result


## 返回棋盘深拷贝，供 AI 使用（AI 不会污染本对象的状态）
func get_board_state() -> Array:
	return board.duplicate(true)


## 棋盘上已有的棋子总数
func get_move_count() -> int:
	return move_history.size()


func is_inside(row: int, col: int) -> bool:
	return row >= 0 and row < board_size and col >= 0 and col < board_size


# ---------------------------------------------------------------------------
# 坐标换算（全部基于当前 board_size 的动态几何）
# ---------------------------------------------------------------------------
## 网格坐标 (row, col) → 本节点局部像素坐标
func grid_to_local(cell: Vector2i) -> Vector2:
	return Vector2(origin_x + cell.y * cell_size, origin_y + cell.x * cell_size)


## 本节点局部像素坐标 → 最近的网格交叉点；超出范围或离交叉点过远返回 (-1, -1)
func local_to_grid(pos: Vector2) -> Vector2i:
	var col: int = int(round((pos.x - origin_x) / cell_size))
	var row: int = int(round((pos.y - origin_y) / cell_size))
	if not is_inside(row, col):
		return Vector2i(-1, -1)
	# 距最近交叉点超过半格则视为误触，不落子
	if pos.distance_to(grid_to_local(Vector2i(row, col))) > cell_size * 0.5:
		return Vector2i(-1, -1)
	return Vector2i(row, col)


# ---------------------------------------------------------------------------
# 输入处理
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if game_finished or input_locked:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse_event: InputEventMouseButton = event
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	# 鼠标悬停在 UI 控件（按钮等）上时不落子
	if get_viewport().gui_get_hovered_control() != null:
		return
	var cell: Vector2i = local_to_grid(to_local(mouse_event.position))
	if cell.x < 0:
		return
	place_stone(cell.x, cell.y)


# ---------------------------------------------------------------------------
# 落子
# ---------------------------------------------------------------------------
## 人类落子：在 (row, col) 放下当前行动方的棋子
## input_locked 为 true（AI 思考期间）时拒绝，避免抢手
func place_stone(row: int, col: int) -> bool:
	if game_finished or input_locked or not is_inside(row, col) or board[row][col] != EMPTY:
		return false
	_apply_move(row, col, current_player)
	return true


## 预留接口：供 AI 控制器调用落子。
## color 省略（或传 0）时使用当前行动方。
## 注意：本接口【不】受 input_locked 限制 —— AI 思考期间正是 input_locked 为 true 的时候。
func set_ai_move(row: int, col: int, color: int = 0) -> bool:
	if game_finished or not is_inside(row, col) or board[row][col] != EMPTY:
		return false
	var who: int = color if color != EMPTY else current_player
	_apply_move(row, col, who)
	return true


func _apply_move(row: int, col: int, color: int) -> void:
	board[row][col] = color
	last_move = Vector2i(row, col)
	move_history.append({"row": row, "col": col, "color": color})

	# 先把状态改完，再广播信号：
	# 否则监听者（UI）读到的 current_player / game_finished 还是落子前的旧值。
	var finished: bool = false
	if _has_win(row, col, color):
		game_finished = true
		winner = color
		finished = true
	elif move_history.size() >= board_size * board_size:
		game_finished = true
		winner = 0
		finished = true
	else:
		current_player = WHITE if color == BLACK else BLACK

	queue_redraw()
	stone_placed.emit(row, col)
	if finished:
		game_over.emit(winner)


## 以 (row, col) 为中心判定 color 是否连成 win_count 子
func _has_win(row: int, col: int, color: int) -> bool:
	for dir in DIRECTIONS:
		var count: int = 1
		count += _count_direction(row, col, dir.x, dir.y, color)
		count += _count_direction(row, col, -dir.x, -dir.y, color)
		if count >= win_count:
			return true
	return false


func _count_direction(row: int, col: int, dr: int, dc: int, color: int) -> int:
	var count: int = 0
	var r: int = row + dr
	var c: int = col + dc
	while is_inside(r, c) and board[r][c] == color:
		count += 1
		r += dr
		c += dc
	return count


# ---------------------------------------------------------------------------
# 对局控制
# ---------------------------------------------------------------------------
## 撤销 count 步，返回实际撤销的步数
func undo_moves(count: int = 1) -> int:
	var undone: int = 0
	while undone < count and not move_history.is_empty():
		var last: Dictionary = move_history.pop_back()
		board[last["row"]][last["col"]] = EMPTY
		undone += 1

	if undone > 0:
		game_finished = false
		winner = 0
		if move_history.is_empty():
			current_player = BLACK
			last_move = Vector2i(-1, -1)
		else:
			var prev: Dictionary = move_history[move_history.size() - 1]
			last_move = Vector2i(prev["row"], prev["col"])
			current_player = WHITE if prev["color"] == BLACK else BLACK
		queue_redraw()
	return undone


## 悔棋：至少撤销一步，并继续撤销直到轮到 color 行动（最多一整轮，避免一次点掉整盘棋）
func undo_to_player(color: int) -> int:
	if move_history.is_empty():
		return 0
	var undone: int = 0
	var limit: int = 2
	while undone < limit and not move_history.is_empty():
		# 已经撤销过、且轮到 color，就停下
		if undone > 0 and current_player == color:
			break
		if undo_moves(1) == 0:
			break
		undone += 1
	return undone


## 重新开始
func restart() -> void:
	board = make_empty_board()
	current_player = BLACK
	last_move = Vector2i(-1, -1)
	game_finished = false
	winner = 0
	input_locked = false
	move_history.clear()
	queue_redraw()


# ---------------------------------------------------------------------------
# 视觉动画
# 全部只【读取】棋局状态，不修改任何棋局数据。
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	_update_hover()
	_update_win_flash(delta)


## 悬停预览：跟随鼠标更新当前悬停的空交叉点
func _update_hover() -> void:
	var cell: Vector2i = Vector2i(-1, -1)
	if not game_finished and not input_locked:
		cell = local_to_grid(get_local_mouse_position())
	if cell != _hover_cell:
		_hover_cell = cell
		queue_redraw()


## 获胜五连闪烁；重新开始 / 悔棋后自动复位
func _update_win_flash(delta: float) -> void:
	if game_finished and winner != EMPTY:
		if not _win_active:
			_win_active = true
			_win_line = _compute_win_line()
			_win_phase = 0.0
		_win_phase += delta * WIN_FLASH_SPEED
		queue_redraw()
	elif _win_active:
		_win_active = false
		_win_line.clear()
		_win_phase = 0.0
		queue_redraw()


## 从最后一手出发，找出连成五子的那条线（只读）
func _compute_win_line() -> Array:
	if last_move.x < 0:
		return []
	var color: int = board[last_move.x][last_move.y]
	if color == EMPTY:
		return []
	for dir in DIRECTIONS:
		var line: Array = [last_move]
		line.append_array(_collect_dir(last_move, dir.x, dir.y, color))
		line.append_array(_collect_dir(last_move, -dir.x, -dir.y, color))
		if line.size() >= win_count:
			return line
	return []


func _collect_dir(from: Vector2i, dr: int, dc: int, color: int) -> Array:
	var out: Array = []
	var r: int = from.x + dr
	var c: int = from.y + dc
	while is_inside(r, c) and board[r][c] == color:
		out.append(Vector2i(r, c))
		r += dr
		c += dc
	return out


## 落子弹跳：0.5 → 1.2 → 1.0
func _on_stone_placed_visual(row: int, col: int) -> void:
	var cell: Vector2i = Vector2i(row, col)
	_stone_scale[cell] = DROP_SCALE_FROM
	var tween: Tween = create_tween()
	tween.tween_method(
		_set_stone_scale.bind(cell), DROP_SCALE_FROM, DROP_SCALE_OVERSHOOT, DROP_UP_TIME
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		_set_stone_scale.bind(cell), DROP_SCALE_OVERSHOOT, 1.0, DROP_SETTLE_TIME
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	queue_redraw()


func _set_stone_scale(value: float, cell: Vector2i) -> void:
	_stone_scale[cell] = value
	queue_redraw()


## 木质棋盘渐变（径向：中心偏亮 → 边缘偏深）
func _build_wood_texture() -> GradientTexture2D:
	var gradient: Gradient = Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	gradient.colors = PackedColorArray([COLOR_WOOD_CENTER, COLOR_WOOD_MID, COLOR_WOOD_EDGE])
	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = int(BOARD_PX)
	texture.height = int(BOARD_PX)
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.42)   # 光源略偏上，更像顶光下的木面
	texture.fill_to = Vector2(1.0, 0.98)
	return texture


# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
func _draw() -> void:
	_draw_board_panel()
	_draw_grid()
	_draw_star_points()
	_draw_ghost_stone()
	_draw_stones()
	_draw_last_marker()


## 棋盘底色叠加透明度：让底层羊皮纸纹理透出来，同时保住网格线对比度
const BOARD_TINT_ALPHA: float = 0.55


func _draw_board_panel() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, Vector2(BOARD_PX, BOARD_PX))
	if _wood_texture != null:
		draw_texture_rect(_wood_texture, rect, false, Color(1.0, 1.0, 1.0, BOARD_TINT_ALPHA))
		_draw_wood_grain()
	else:
		draw_rect(rect, COLOR_BOARD, true)   # 纹理构建失败时的降级方案
	# 双层木框，做出木牌的厚度感
	draw_rect(rect, COLOR_BOARD_EDGE, false, BORDER_WIDTH * 2.0)
	draw_rect(rect.grow(-6.0), Color(0.62, 0.47, 0.29, 0.75), false, 1.0)


## 极淡的横向木纹，避免棋盘显得过于平滑死板
func _draw_wood_grain() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20260920
	for i in 14:
		var y: float = 16.0 + i * 45.0 + rng.randf_range(-9.0, 9.0)
		var alpha: float = rng.randf_range(0.028, 0.060)
		draw_line(
			Vector2(0.0, y),
			Vector2(BOARD_PX, y + rng.randf_range(-6.0, 6.0)),
			Color(0.44, 0.29, 0.12, alpha),
			rng.randf_range(1.0, 2.6)
		)


## 悬停预览棋子：半透明的当前回合色
func _draw_ghost_stone() -> void:
	if _hover_cell.x < 0 or game_finished or input_locked:
		return
	if board[_hover_cell.x][_hover_cell.y] != EMPTY:
		return
	var center: Vector2 = grid_to_local(_hover_cell)
	var tint: Color = COLOR_BLACK if current_player == BLACK else COLOR_WHITE
	tint.a = GHOST_ALPHA
	draw_circle(center, stone_radius, tint)
	# 描一圈边，让半透明棋子在木色底上也看得清
	draw_arc(center, stone_radius, 0.0, TAU, 40, Color(tint.r, tint.g, tint.b, 0.8), 1.6, true)


func _draw_grid() -> void:
	for i in board_size:
		var x: float = origin_x + i * cell_size
		draw_line(Vector2(x, origin_y), Vector2(x, origin_y + grid_px), COLOR_LINE, LINE_WIDTH)
		var y: float = origin_y + i * cell_size
		draw_line(Vector2(origin_x, y), Vector2(origin_x + grid_px, y), COLOR_LINE, LINE_WIDTH)


func _draw_star_points() -> void:
	for star in _star_points():
		draw_circle(grid_to_local(star), star_radius, COLOR_LINE)


func _draw_stones() -> void:
	# 胜负已分时，让获胜连线一起呼吸式闪烁
	var flash: float = 1.0
	if _win_active and not _win_line.is_empty():
		flash = 0.42 + 0.58 * absf(sin(_win_phase))
	for row in board_size:
		for col in board_size:
			var value: int = board[row][col]
			if value == EMPTY:
				continue
			var cell: Vector2i = Vector2i(row, col)
			var scale_f: float = _stone_scale.get(cell, 1.0)
			var alpha: float = 1.0
			if _win_active and _win_line.has(cell):
				alpha = flash
			_draw_stone(grid_to_local(cell), value, scale_f, alpha)


## 棋子绘制：外阴影 + 边缘压暗 + 左上高光，做出球面立体感
## 半径随棋盘尺寸缩放，9~19 路都能保持合适的棋子/格宽比例。
func _draw_stone(center: Vector2, color: int, scale_f: float = 1.0, alpha: float = 1.0) -> void:
	var radius: float = stone_radius * scale_f
	if radius <= 0.2:
		return
	var rim_r: float = maxf(radius * 0.94, radius - 1.0)
	var rim_w: float = maxf(radius * 0.12, 1.0)
	# 外阴影：向右下偏移的半透明黑圆
	draw_circle(
		center + SHADOW_OFFSET * scale_f, radius, Color(0.0, 0.0, 0.0, COLOR_SHADOW.a * alpha)
	)
	if color == BLACK:
		draw_circle(center, radius, Color(COLOR_BLACK.r, COLOR_BLACK.g, COLOR_BLACK.b, alpha))
		# 边缘压暗，制造球面转折
		draw_arc(center, rim_r, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.45 * alpha), rim_w, true)
		# 左上柔光 + 更小的镜面高光点
		draw_circle(
			center - Vector2(radius * 0.30, radius * 0.30), radius * 0.34, Color(1, 1, 1, 0.20 * alpha)
		)
		draw_circle(
			center - Vector2(radius * 0.36, radius * 0.36), radius * 0.15, Color(1, 1, 1, 0.55 * alpha)
		)
	else:
		draw_circle(center, radius, Color(COLOR_WHITE.r, COLOR_WHITE.g, COLOR_WHITE.b, alpha))
		draw_arc(
			center, rim_r, 0.0, TAU, 48, Color(0.55, 0.55, 0.58, 0.85 * alpha), rim_w, true
		)
		draw_circle(
			center - Vector2(radius * 0.30, radius * 0.30), radius * 0.36, Color(1, 1, 1, 0.55 * alpha)
		)
		draw_circle(
			center - Vector2(radius * 0.36, radius * 0.36), radius * 0.15, Color(1, 1, 1, 0.95 * alpha)
		)


func _draw_last_marker() -> void:
	if last_move.x < 0:
		return
	var center: Vector2 = grid_to_local(last_move)
	var scale_f: float = _stone_scale.get(last_move, 1.0)
	draw_circle(center, mark_radius * scale_f, COLOR_MARK)
