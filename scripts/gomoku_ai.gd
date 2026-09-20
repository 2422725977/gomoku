extends RefCounted

## =============================================================================
## 五子棋 AI —— 纯算法模块（不继承 Node / 不访问场景树 / 不引用其它脚本）
## Gomoku (Five-in-a-Row) AI - pure algorithm module, no scene-tree dependency.
##
## 使用 / Usage:
##     var ai = preload("res://scripts/gomoku_ai.gd").new()
##     ai.set_difficulty(ai.DIFFICULTY_HARD)
##     var mv: Vector2i = ai.get_best_move(board, ai_color)
##
## board: 15x15 的 Array[Array]，board[row][col]；0=空 1=黑 2=白
##        调用方的 board 绝不会被修改（内部使用独立副本搜索）。
## 返回: Vector2i(row, col)；无合法着法时返回 Vector2i(-1, -1)。
##
## 算法 / Algorithm:
##   * 负极大值(Negamax) + Alpha-Beta 剪枝
##   * 迭代加深 + 2 秒硬超时（Time.get_ticks_msec），超时立即返回当前最优着法
##   * 增量式线型评估：棋盘切成若干条“线”，落子只重算经过该点的 4 条线
##   * 置换表：Zobrist 增量哈希，容量上限 20 万条，超限清空，reset() 清空
##   * 候选点：距任一棋子切比雪夫距离 <= 2 的空点；空盘返回天元
##   * 战术预检：我方成五 / 对方成五必挡 / 我方成活四 -> 直接短路返回
## =============================================================================

# ------------------------------------------------------------------ 基础常量
const BOARD_SIZE: int = 15
const EMPTY: int = 0
const BLACK: int = 1
const WHITE: int = 2
const WALL: int = 3
const PAD: int = 2          # 哨兵边界厚度（>= 2，用于容纳邻域偏移）
const DIR_COUNT: int = 4

# ------------------------------------------------------------------ 难度等级
const DIFFICULTY_EASY: int = 0
const DIFFICULTY_NORMAL: int = 1
const DIFFICULTY_HARD: int = 2

# ------------------------------------------------------------------ 棋型分值
const SCORE_FIVE: int = 1000000          # 五连
const SCORE_OPEN_FOUR: int = 100000      # 活四
const SCORE_FOUR: int = 10000            # 冲四
const SCORE_OPEN_THREE: int = 1000       # 活三
const SCORE_SLEEPING_THREE: int = 100    # 眠三
const SCORE_OPEN_TWO: int = 10           # 活二

# ------------------------------------------------------------------ 搜索参数
const WIN_SCORE: int = 1000000           # 终局获胜分（与五连同量级）
const WIN_THRESHOLD: int = 900000        # 大于该值视为“必胜/必败”分
const WIN_DECAY: int = 10                # 每深一层衰减，越快取胜分越高
const INF_SCORE: int = 100000000         # Alpha-Beta 的 ±∞
const TIME_LIMIT_MS: int = 2000          # 2 秒硬超时
const TIME_CHECK_MASK: int = 63          # 每 64 个结点查一次时钟
const TT_MAX_ENTRIES: int = 200000       # 置换表容量上限
const TT_EXACT: int = 0
const TT_LOWER: int = 1
const TT_UPPER: int = 2
const TT_SCORE_OFFSET: int = 67108864    # 1 << 26，保证编码后的分数段非负
const TT_MOVE_MASK: int = 8191           # 13 位着法编码
const NEIGHBOR_RANGE: int = 2            # 候选点切比雪夫距离
const MAX_CANDIDATES_ROOT: int = 18      # 根结点最多搜索的候选数
const MAX_CANDIDATES: int = 12           # 内部结点最多搜索的候选数
const EASY_RANDOM_CHANCE: float = 0.1    # 简单难度随机落子概率

# ------------------------------------------------------------------ 内部状态
var difficulty: int = DIFFICULTY_NORMAL

## 连珠数（3-6），由 UI 经 set_rules() 下发；默认 5 = 标准五子棋。
## 棋盘尺寸不单独存：每次 get_best_move 都从传入的 board 推断（board.size()）。
var _win_count: int = 5

var _n: int = BOARD_SIZE
var _w: int = BOARD_SIZE + PAD * 2        # 带哨兵边界的行宽
var _tables_n: int = -1                   # 线表已按哪个尺寸构建
var _grid: PackedInt32Array = PackedInt32Array()          # 带边界的一维棋盘
var _near: PackedInt32Array = PackedInt32Array()          # 每格邻域内棋子数
var _near_offsets: PackedInt32Array = PackedInt32Array()  # 5x5 邻域偏移（不含自身）
var _steps: PackedInt32Array = PackedInt32Array()         # 4 个方向的步长
var _line_cells: Array = []                               # 每条线的格点索引
var _line_of_cell: PackedInt32Array = PackedInt32Array()  # 每格 x 4 个方向的线 id
var _lscore_b: PackedInt32Array = PackedInt32Array()      # 每条线的黑方分
var _lscore_w: PackedInt32Array = PackedInt32Array()      # 每条线的白方分
var _tmp_sb: int = 0                                      # _score_line 输出（黑）
var _tmp_sw: int = 0                                      # _score_line 输出（白）
var _tot_b: int = 0                                       # 全局黑方总分
var _tot_w: int = 0                                       # 全局白方总分
var _stone_count: int = 0
var _undo: PackedInt32Array = PackedInt32Array()          # 线分数撤销栈
var _tt: Dictionary = {}                                  # 置换表 key -> 打包值
var _zob_b: PackedInt64Array = PackedInt64Array()
var _zob_w: PackedInt64Array = PackedInt64Array()
var _zob_side: int = 0
var _zob_size: int = -1
var _nodes: int = 0
var _deadline_ms: int = 0
var _time_up: bool = false
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _last_stats: Dictionary = {"nodes": 0, "depth": 0, "score": 0, "elapsed_ms": 0.0}


func _init() -> void:
	_rng.randomize()


# =============================================================================
# 公开 API / Public API
# =============================================================================

## 设置难度：0=简单(深度1+10%随机) 1=普通(深度3) 2=困难(深度5+2秒)
func set_difficulty(level: int) -> void:
	if level < DIFFICULTY_EASY:
		level = DIFFICULTY_EASY
	elif level > DIFFICULTY_HARD:
		level = DIFFICULTY_HARD
	difficulty = level


## 规则自适应：设置连珠数。
## 游戏规则层限制为 5~6（不存在「五珠以下」的玩法）；
## 算法本身兼容 3~6 以便复用，因此这里按 3~6 夹取。
## 棋盘尺寸无需传入 —— get_best_move() 会从 board.size() 自动推断。
func set_rules(win_count: int) -> void:
	_win_count = clampi(win_count, 3, 6)


## 清理置换表与内部状态（两局之间调用）
func reset() -> void:
	_tt.clear()
	_undo.clear()
	_nodes = 0
	_time_up = false
	_last_stats = {"nodes": 0, "depth": 0, "score": 0, "elapsed_ms": 0.0}


## 上一次搜索的统计信息
func get_last_stats() -> Dictionary:
	return _last_stats.duplicate()


## 计算最佳着法。
## board: 15x15 的 Array[Array]，board[row][col]，0=空 1=黑 2=白
## ai_color: 1=黑 2=白
## 返回 Vector2i(row, col)；无合法着法时返回 Vector2i(-1, -1)。
func get_best_move(board: Array, ai_color: int) -> Vector2i:
	var started: int = Time.get_ticks_msec()
	_nodes = 0
	_time_up = false
	var me: int = BLACK
	if ai_color == WHITE:
		me = WHITE

	if not _load_board(board):
		_set_stats(0, 0, started)
		return Vector2i(-1, -1)

	# 空盘 -> 天元
	if _stone_count == 0:
		var mid: int = _n >> 1
		_set_stats(0, 0, started)
		return Vector2i(mid, mid)

	# 棋盘已满 -> 无棋可下
	if _stone_count >= _n * _n:
		_set_stats(0, 0, started)
		return Vector2i(-1, -1)

	# ---------- 战术预检（先于搜索，命中则直接短路返回） ----------
	var forced: Vector2i = _find_tactic_move(me)
	if forced.x >= 0:
		_set_stats(0, 0, started)
		return forced

	_deadline_ms = started + TIME_LIMIT_MS

	# ---------- 根结点候选（按威胁值排序） ----------
	var root_moves: PackedInt32Array = _generate_moves(me, -1, MAX_CANDIDATES_ROOT)
	if root_moves.is_empty():
		_set_stats(0, 0, started)
		return Vector2i(-1, -1)

	# ---------- 简单难度：10% 概率随机走一个合法候选点 ----------
	if difficulty == DIFFICULTY_EASY and _rng.randf() < EASY_RANDOM_CHANCE:
		var all_moves: PackedInt32Array = _generate_moves(me, -1, -1)
		if not all_moves.is_empty():
			var pick: int = all_moves[_rng.randi_range(0, all_moves.size() - 1)]
			_set_stats(0, 0, started)
			return _idx_to_pos(pick)

	# ---------- 迭代加深 + Alpha-Beta ----------
	var max_depth: int = _depth_for_difficulty()
	var best_move: int = root_moves[0]
	var best_score: int = 0
	var reached_depth: int = 0
	var key: int = _root_hash(me)

	var d: int = 1
	while d <= max_depth:
		var alpha: int = -INF_SCORE
		var iter_best: int = -INF_SCORE
		var iter_move: int = best_move
		var iter_found: bool = false
		for i in root_moves.size():
			if _time_up:
				break
			if Time.get_ticks_msec() >= _deadline_ms:
				_time_up = true
				break
			var m: int = root_moves[i]
			var zk: int = _zob_b[m]
			if me == WHITE:
				zk = _zob_w[m]
			var won: bool = _make_move(m, me)
			var sc: int = 0
			if won:
				sc = WIN_SCORE
			else:
				sc = -_negamax(d - 1, -INF_SCORE, -alpha, _other(me), 1, key ^ zk ^ _zob_side)
			_unmake_move(m)
			if _time_up:
				break
			if won:
				iter_best = WIN_SCORE
				iter_move = m
				iter_found = true
				break
			if sc > iter_best:
				iter_best = sc
				iter_move = m
				iter_found = true
			if iter_best > alpha:
				alpha = iter_best
		# 部分完成的迭代也接受：只接受“已确认不劣于”的着法
		if iter_found:
			best_move = iter_move
			best_score = iter_best
			reached_depth = d
			root_moves = _promote(root_moves, best_move)
		if _time_up:
			break
		if best_score > WIN_THRESHOLD:
			break        # 已找到必胜着法，无需再深
		d += 1

	_set_stats(reached_depth, best_score, started)
	return _idx_to_pos(best_move)


# =============================================================================
# 难度与统计
# =============================================================================

## 搜索深度：先按【棋盘尺寸】定基准（大棋盘分支爆炸，必须收敛深度），
## 再按【难度档位】微调：EASY=-1 / NORMAL=0 / HARD=+1。
##   9 路 → 5 层    12 路 → 4 层    15 路 → 3 层    19 路 → 2 层
func _depth_for_difficulty() -> int:
	var base: int = 2
	if _n <= 9:
		base = 5
	elif _n <= 12:
		base = 4
	elif _n <= 15:
		base = 3
	else:
		base = 2
	return clampi(base + difficulty - 1, 1, 6)


## 不同连珠数下的「活三」权重。
## 连珠数越少，「活三 → 活四 → 取胜」的链条越短，活三的威胁就越大：
##   WIN_COUNT=3 时活三几乎等同胜势；WIN_COUNT=4 时需要大幅提升到冲四同级。
func _open_three_score() -> int:
	if _win_count <= 3:
		return SCORE_OPEN_FOUR / 2
	if _win_count == 4:
		return SCORE_OPEN_THREE * 10
	return SCORE_OPEN_THREE


func _set_stats(depth: int, score: int, started_ms: int) -> void:
	_last_stats = {
		"nodes": _nodes,
		"depth": depth,
		"score": score,
		"elapsed_ms": float(Time.get_ticks_msec() - started_ms),
	}


# =============================================================================
# 战术预检 / Immediate-tactic pre-check
# 顺序：我方成五 > 对方成五必挡 > 我方成活四
# =============================================================================

func _find_tactic_move(me: int) -> Vector2i:
	var opp: int = _other(me)
	# 1) 我方一步成五 -> 直接取胜
	var win_idx: int = _find_five_move(me)
	if win_idx >= 0:
		return _idx_to_pos(win_idx)
	# 2) 对方一步成五（冲四/活四）-> 必须封堵
	var block_idx: int = _find_five_move(opp)
	if block_idx >= 0:
		return _idx_to_pos(block_idx)
	# 3) 我方一步成活四 -> 对手无法同时封堵两端，必胜
	var four_idx: int = _find_open_four_move(me)
	if four_idx >= 0:
		return _idx_to_pos(four_idx)
	return Vector2i(-1, -1)


## 找出能立刻成五的空点；多个点时取防守价值最高的那个
func _find_five_move(color: int) -> int:
	var best_idx: int = -1
	var best_val: int = -1
	var cell_count: int = _grid.size()
	for r in _n:
		if r < 0 or r >= _n:
			continue
		var base: int = (r + PAD) * _w + PAD
		for c in _n:
			if c < 0 or c >= _n:
				continue
			var idx: int = base + c
			if idx < 0 or idx >= cell_count:
				continue
			if _grid[idx] != EMPTY:
				continue
			if _near[idx] == 0:
				continue
			_grid[idx] = color
			var make_five: bool = _makes_five(idx, color)
			_grid[idx] = EMPTY
			if make_five:
				var val: int = _point_score(idx, _other(color))
				if val > best_val:
					best_val = val
					best_idx = idx
	return best_idx


## 找出能立刻形成“活四”的空点（对手挡不住）
func _find_open_four_move(color: int) -> int:
	var best_idx: int = -1
	var best_val: int = -1
	var cell_count: int = _grid.size()
	for r in _n:
		if r < 0 or r >= _n:
			continue
		var base: int = (r + PAD) * _w + PAD
		for c in _n:
			if c < 0 or c >= _n:
				continue
			var idx: int = base + c
			if idx < 0 or idx >= cell_count:
				continue
			if _grid[idx] != EMPTY:
				continue
			if _near[idx] == 0:
				continue
			_grid[idx] = color
			var made: bool = _is_open_four_at(idx, color)
			_grid[idx] = EMPTY
			if made:
				var val: int = _point_score(idx, _other(color))
				if val > best_val:
					best_val = val
					best_idx = idx
	return best_idx


## 假设 idx 处已落 color 子，判断该点是否形成活四（两端皆空的四连）
func _is_open_four_at(idx: int, color: int) -> bool:
	for d in DIR_COUNT:
		if _dir_pattern(idx, _steps[d], color) == SCORE_OPEN_FOUR:
			return true
	return false


# =============================================================================
# 搜索核心 / Negamax + Alpha-Beta
# =============================================================================

func _negamax(depth: int, alpha: int, beta: int, to_move: int, ply: int, key: int) -> int:
	_nodes += 1
	if (_nodes & TIME_CHECK_MASK) == 0:
		if Time.get_ticks_msec() >= _deadline_ms:
			_time_up = true
	if _time_up:
		return 0
	# 到达叶子 -> 直接用增量维护的线型总分评估
	if depth <= 0:
		return _evaluate(to_move)

	var alpha_orig: int = alpha
	var tt_move: int = -1
	var packed: int = int(_tt.get(key, 0))
	if packed != 0:
		tt_move = packed & TT_MOVE_MASK
		if ((packed >> 15) & 15) >= depth:
			var s: int = (packed >> 19) - TT_SCORE_OFFSET
			# 将置换表中的“本结点相对步数”还原为当前 ply 下的分数
			if s > WIN_THRESHOLD:
				s -= ply * WIN_DECAY
			elif s < -WIN_THRESHOLD:
				s += ply * WIN_DECAY
			var flag: int = (packed >> 13) & 3
			if flag == TT_EXACT:
				return s
			if flag == TT_LOWER:
				if s > alpha:
					alpha = s
			elif flag == TT_UPPER:
				if s < beta:
					beta = s
			if alpha >= beta:
				return s

	var moves: PackedInt32Array = _generate_moves(to_move, tt_move, MAX_CANDIDATES)
	if moves.is_empty():
		return _evaluate(to_move)

	var best: int = -INF_SCORE
	var best_move: int = -1
	var a: int = alpha
	for m in moves:
		var zk: int = _zob_b[m]
		if to_move == WHITE:
			zk = _zob_w[m]
		var won: bool = _make_move(m, to_move)
		var sc: int = 0
		if won:
			# 终局：越快取胜分越高（ply 越小分越高）
			sc = WIN_SCORE - ply * WIN_DECAY
		else:
			sc = -_negamax(depth - 1, -beta, -a, _other(to_move), ply + 1, key ^ zk ^ _zob_side)
		_unmake_move(m)
		if _time_up:
			return 0
		if sc > best:
			best = sc
			best_move = m
		if best > a:
			a = best
		if a >= beta:
			break
		if best > WIN_THRESHOLD:
			break        # 已找到必胜着法

	var flag_out: int = TT_EXACT
	if best <= alpha_orig:
		flag_out = TT_UPPER
	elif best >= beta:
		flag_out = TT_LOWER
	_store_tt(key, depth, best, flag_out, best_move, ply)
	return best


## 叶子评估：增量维护的线型总分，转换为“轮到 to_move 一方”的视角
func _evaluate(to_move: int) -> int:
	if to_move == BLACK:
		return _tot_b - _tot_w
	return _tot_w - _tot_b


# =============================================================================
# 置换表 / Transposition table
# 打包格式（int64）: [分数+OFFSET : 高位][depth : 4bit][flag : 2bit][move : 13bit]
# =============================================================================

func _store_tt(key: int, depth: int, score: int, flag: int, move: int, ply: int) -> void:
	if _tt.size() >= TT_MAX_ENTRIES:
		_tt.clear()          # 容量封顶，避免内存无限增长
	var s: int = score
	if s > WIN_THRESHOLD:
		s += ply * WIN_DECAY
	elif s < -WIN_THRESHOLD:
		s -= ply * WIN_DECAY
	_tt[key] = ((s + TT_SCORE_OFFSET) << 19) | (depth << 15) | (flag << 13) | (move & TT_MOVE_MASK)


# =============================================================================
# 候选生成与排序 / Candidate generation & move ordering
# =============================================================================

## 生成候选点并按威胁值降序排列；limit < 0 表示不截断
## 边界保护：行列严格限制在 [0, _n) 内，索引再夹一次 _grid 范围。
func _generate_moves(color: int, tt_move: int, limit: int) -> PackedInt32Array:
	var opp: int = _other(color)
	var keys: PackedInt64Array = PackedInt64Array()
	var cell_count: int = _grid.size()
	for r in _n:
		if r < 0 or r >= _n:
			continue
		var base: int = (r + PAD) * _w + PAD
		for c in _n:
			if c < 0 or c >= _n:
				continue
			var idx: int = base + c
			if idx < 0 or idx >= cell_count:
				continue
			if _grid[idx] != EMPTY:
				continue
			if _near[idx] == 0:
				continue     # 只考虑距任一棋子切比雪夫距离 <= 2 的空点
			var h: int = _point_score(idx, color) * 2 + _point_score(idx, opp)
			keys.push_back(-(h * 4096 + idx))
	var out: PackedInt32Array = PackedInt32Array()
	if keys.is_empty():
		return out
	keys.sort()              # 原生排序，降序效果由负号实现
	var count: int = keys.size()
	if limit >= 0 and count > limit:
		count = limit
	for i in count:
		out.push_back((-keys[i]) % 4096)

	# 置换表着法优先搜索
	if tt_move >= 0 and out.size() > 1 and out[0] != tt_move:
		var found: bool = false
		for i in out.size():
			if out[i] == tt_move:
				found = true
				break
		if found:
			var promoted: PackedInt32Array = PackedInt32Array()
			promoted.push_back(tt_move)
			for i in out.size():
				if out[i] != tt_move:
					promoted.push_back(out[i])
			out = promoted
	return out


## 假设在 idx 落 color 子后的棋型价值（4 个方向之和）
func _point_score(idx: int, color: int) -> int:
	var total: int = 0
	for d in DIR_COUNT:
		total += _dir_pattern(idx, _steps[d], color)
	return total


## 假设 idx 处已落 color 子，统计该方向上包含 idx 的棋型分
func _dir_pattern(idx: int, step: int, color: int) -> int:
	var count: int = 1
	var i: int = idx + step
	while _grid[i] == color:
		count += 1
		i += step
	var open_a: bool = _grid[i] == EMPTY
	i = idx - step
	while _grid[i] == color:
		count += 1
		i -= step
	var open_b: bool = _grid[i] == EMPTY
	return _pattern_score(count, open_a, open_b, false)


## 棋型打分：count=连子数，open_a/open_b=两端是否为空，has_gap=中间是否跨了一个空位
## 所有档位都相对【当前连珠数 w】判定，因此 3~6 连规则共用同一套评估。
func _pattern_score(count: int, open_a: bool, open_b: bool, has_gap: bool) -> int:
	var opens: int = 0
	if open_a:
		opens += 1
	if open_b:
		opens += 1
	var w: int = _win_count
	if has_gap:
		# 中间有空位：补上该空位即达成 w 连，因此最高只能算“冲四”
		if count >= w - 1:
			return SCORE_FOUR
	elif count >= w:
		return SCORE_FIVE              # 达成连珠（含超长连）
	if count == w - 1:
		if opens == 2:
			return SCORE_OPEN_FOUR
		if opens == 1:
			return SCORE_FOUR
		return 0
	if count == w - 2 and count >= 2:
		if opens == 2:
			return _open_three_score()
		if opens == 1:
			return SCORE_SLEEPING_THREE
		return 0
	if count == w - 3 and count >= 2:
		if opens == 2:
			return SCORE_OPEN_TWO
		return 0
	return 0


# =============================================================================
# 落子 / 撤销 + 增量线型评分
# =============================================================================

## 落子；返回该手是否直接形成五连（终局）
func _make_move(idx: int, color: int) -> bool:
	_grid[idx] = color
	_stone_count += 1
	for k in _near_offsets:
		_near[idx + k] += 1
	# 只重算经过该点的 4 条线
	var cell_base: int = idx * DIR_COUNT
	for d in DIR_COUNT:
		var lid: int = _line_of_cell[cell_base + d]
		if lid < 0:
			continue
		var ob: int = _lscore_b[lid]
		var ow: int = _lscore_w[lid]
		_undo.push_back(lid)
		_undo.push_back(ob)
		_undo.push_back(ow)
		_score_line(lid)
		_lscore_b[lid] = _tmp_sb
		_lscore_w[lid] = _tmp_sw
		_tot_b += _tmp_sb - ob
		_tot_w += _tmp_sw - ow
	return _makes_five(idx, color)


## 撤销 idx 处的一手（评分对称，无需传入颜色）
func _unmake_move(idx: int) -> void:
	_grid[idx] = EMPTY
	_stone_count -= 1
	for k in _near_offsets:
		_near[idx + k] -= 1
	var cell_base: int = idx * DIR_COUNT
	# 注意：PackedInt32Array 没有 pop_back()（Array 才有）。
	# 这里按索引从栈顶向下读三条记录，循环结束后一次性截断。
	var top: int = _undo.size()
	for d in range(DIR_COUNT - 1, -1, -1):
		var lid: int = _line_of_cell[cell_base + d]
		if lid < 0:
			continue
		top -= 3
		var stored_lid: int = _undo[top]
		var ob: int = _undo[top + 1]
		var ow: int = _undo[top + 2]
		_tot_b += ob - _lscore_b[stored_lid]
		_tot_w += ow - _lscore_w[stored_lid]
		_lscore_b[stored_lid] = ob
		_lscore_w[stored_lid] = ow
	_undo.resize(top)


## 重算某条线上黑/白双方的棋型分，结果写入 _tmp_sb / _tmp_sw
func _score_line(lid: int) -> void:
	var cells: PackedInt32Array = _line_cells[lid]
	var total: int = cells.size()
	var sb: int = 0
	var sw: int = 0
	var i: int = 0
	while i < total:
		var v: int = _grid[cells[i]]
		if v == EMPTY:
			i += 1
			continue
		# 连续段长度（允许跨一个空位，用于识别 XX_XX / X_XX 这类跳型）
		var count: int = 1
		var j: int = i + 1
		while j < total and _grid[cells[j]] == v:
			count += 1
			j += 1
		var has_gap: bool = false
		if j + 1 < total and _grid[cells[j]] == EMPTY and _grid[cells[j + 1]] == v:
			has_gap = true
			j += 1
			while j < total and _grid[cells[j]] == v:
				count += 1
				j += 1
		var open_a: bool = i > 0 and _grid[cells[i - 1]] == EMPTY
		var open_b: bool = j < total and _grid[cells[j]] == EMPTY
		var s: int = _pattern_score(count, open_a, open_b, has_gap)
		if v == BLACK:
			sb += s
		else:
			sw += s
		i = j          # j 恒大于 i，循环必定前进
	_tmp_sb = sb
	_tmp_sw = sw


## 按当前 _grid 全量重建线分数（每次载入棋盘时调用一次）
func _rebuild_scores() -> void:
	var count: int = _line_cells.size()
	_lscore_b.resize(count)
	_lscore_w.resize(count)
	_tot_b = 0
	_tot_w = 0
	for lid in count:
		_score_line(lid)
		_lscore_b[lid] = _tmp_sb
		_lscore_w[lid] = _tmp_sw
		_tot_b += _tmp_sb
		_tot_w += _tmp_sw
	_undo.clear()


# =============================================================================
# 棋盘载入与静态表构建
# =============================================================================

## 把调用方的棋盘拷贝到内部带哨兵边界的一维数组；返回 false 表示输入非法
func _load_board(board: Array) -> bool:
	if board == null or board.is_empty():
		return false
	var n: int = board.size()
	for r in n:
		var row: Variant = board[r]
		var t: int = typeof(row)
		if t != TYPE_ARRAY and t != TYPE_PACKED_INT32_ARRAY:
			return false
		if row.size() != n:
			return false
	_n = n
	_build_tables()          # 会同步更新 _w / _steps / _near_offsets / 线表
	_grid = PackedInt32Array()
	_grid.resize(_w * _w)
	# 只有哨兵边界是 WALL，棋盘内部必须是 EMPTY ——
	# 否则所有空点都会被当成非空，候选列表恒为空。
	_grid.fill(EMPTY)
	for i in _w:
		for k in PAD:
			_grid[i * _w + k] = WALL                  # 左边
			_grid[i * _w + (_w - 1 - k)] = WALL       # 右边
			_grid[k * _w + i] = WALL                  # 上边
			_grid[(_w - 1 - k) * _w + i] = WALL       # 下边
	_near = PackedInt32Array()
	_near.resize(_w * _w)
	_near.fill(0)
	_stone_count = 0
	for r in n:
		var row: Variant = board[r]
		var base: int = (r + PAD) * _w + PAD
		for c in n:
			var v: int = int(row[c])
			if v != BLACK and v != WHITE:
				continue
			_grid[base + c] = v
			_stone_count += 1
	# 邻域计数：每颗棋子给周围 5x5 的格子 +1
	for r in n:
		var base: int = (r + PAD) * _w + PAD
		for c in n:
			var idx: int = base + c
			if _grid[idx] == EMPTY:
				continue
			for k in _near_offsets:
				_near[idx + k] += 1
	_rebuild_scores()
	_ensure_zobrist()
	return true


## 构建与棋盘尺寸相关的静态表（尺寸不变时复用）
func _build_tables() -> void:
	if _tables_n == _n:
		return
	_tables_n = _n
	_w = _n + PAD * 2
	_steps = PackedInt32Array([_w, 1, _w + 1, _w - 1])
	var offsets: PackedInt32Array = PackedInt32Array()
	for dr in range(-NEIGHBOR_RANGE, NEIGHBOR_RANGE + 1):
		for dc in range(-NEIGHBOR_RANGE, NEIGHBOR_RANGE + 1):
			if dr == 0 and dc == 0:
				continue
			offsets.push_back(dr * _w + dc)
	_near_offsets = offsets

	# 把棋盘拆成“线”：4 个方向的极大连续线段，长度 >= 5 才参与评分
	var drs: PackedInt32Array = PackedInt32Array([1, 0, 1, 1])
	var dcs: PackedInt32Array = PackedInt32Array([0, 1, 1, -1])
	_line_cells = []
	_line_of_cell = PackedInt32Array()
	_line_of_cell.resize(_w * _w * DIR_COUNT)
	_line_of_cell.fill(-1)
	for d in DIR_COUNT:
		var dr: int = drs[d]
		var dc: int = dcs[d]
		for r in _n:
			for c in _n:
				var pr: int = r - dr
				var pc: int = c - dc
				if pr >= 0 and pr < _n and pc >= 0 and pc < _n:
					continue      # 不是线段起点
				var cells: PackedInt32Array = PackedInt32Array()
				var rr: int = r
				var cc: int = c
				while rr >= 0 and rr < _n and cc >= 0 and cc < _n:
					cells.push_back((rr + PAD) * _w + (cc + PAD))
					rr += dr
					cc += dc
				if cells.size() >= 5:
					var lid: int = _line_cells.size()
					for ci in cells:
						_line_of_cell[ci * DIR_COUNT + d] = lid
					_line_cells.append(cells)


## Zobrist 随机数表（固定种子，保证同一局面哈希稳定）
func _ensure_zobrist() -> void:
	if _zob_size == _w:
		return
	_zob_size = _w
	var cells: int = _w * _w
	_zob_b = PackedInt64Array()
	_zob_w = PackedInt64Array()
	_zob_b.resize(cells)
	_zob_w.resize(cells)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 0x1234567890ABCDEF
	for i in cells:
		var a: int = rng.randi()
		var b: int = rng.randi()
		_zob_b[i] = (a << 32) | b
		a = rng.randi()
		b = rng.randi()
		_zob_w[i] = (a << 32) | b
	var s1: int = rng.randi()
	var s2: int = rng.randi()
	_zob_side = (s1 << 32) | s2


## 根结点整盘哈希（含行棋方）
func _root_hash(to_move: int) -> int:
	var key: int = 0
	for r in _n:
		var base: int = (r + PAD) * _w + PAD
		for c in _n:
			var idx: int = base + c
			var v: int = _grid[idx]
			if v == BLACK:
				key ^= _zob_b[idx]
			elif v == WHITE:
				key ^= _zob_w[idx]
	if to_move == WHITE:
		key ^= _zob_side
	return key


# =============================================================================
# 小工具
# =============================================================================

func _other(color: int) -> int:
	if color == BLACK:
		return WHITE
	return BLACK


## idx 处（已落 color 子）是否达成连珠（_win_count 子及以上，超长连同样算胜）
func _makes_five(idx: int, color: int) -> bool:
	for d in DIR_COUNT:
		var step: int = _steps[d]
		var count: int = 1
		var i: int = idx + step
		while _grid[i] == color:
			count += 1
			i += step
		i = idx - step
		while _grid[i] == color:
			count += 1
			i -= step
		if count >= _win_count:
			return true
	return false


## 把某个着法提到候选列表最前面（用于迭代加深的下一轮）
func _promote(moves: PackedInt32Array, m: int) -> PackedInt32Array:
	if moves.is_empty() or moves[0] == m:
		return moves
	var out: PackedInt32Array = PackedInt32Array()
	out.push_back(m)
	for v in moves:
		if v != m:
			out.push_back(v)
	return out


@warning_ignore("integer_division")
func _idx_to_pos(idx: int) -> Vector2i:
	var c: int = idx % _w - PAD
	var r: int = idx / _w - PAD
	return Vector2i(r, c)
