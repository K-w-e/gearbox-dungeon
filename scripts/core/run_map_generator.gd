class_name RunMapGenerator
extends RefCounted

const NO_REPEAT_TYPES: Array[String] = ["elite", "rest", "workshop", "upgrade"]

static func generate_run_dag(repo: GameRepository, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if repo == null or rng == null or repo.encounters.is_empty():
		push_error("RunMapGenerator.generate_run_dag received invalid repository or empty encounters")
		return result

	var map_cfg: Dictionary = repo.gameplay().get("run_map", {}) as Dictionary
	var raw_templates: Array = map_cfg.get("tier_templates", []) as Array
	var def_left_scrap: int = int(map_cfg.get("default_left_bonus_scrap", 0))
	var def_right_heal: int = int(map_cfg.get("default_right_bonus_heal", 0))

	var tier_templates: Array[Dictionary] = []
	for entry: Variant in raw_templates:
		if typeof(entry) == TYPE_DICTIONARY:
			tier_templates.append(entry as Dictionary)
	if tier_templates.is_empty():
		push_error("RunMapGenerator missing tier_templates in config.json")
		return result

	var num_stages: int = tier_templates.size()
	var layer_counts: Array[int] = []
	for s: int in range(num_stages):
		var tmpl: Dictionary = tier_templates[s]
		var min_c: int = maxi(1, int(tmpl.get("count", 1)))
		var max_c: int = maxi(min_c, int(tmpl.get("max_count", min_c)))
		var picked_c: int = rng.randi_range(min_c, max_c)
		if s > 0:
			picked_c = mini(picked_c, layer_counts[s - 1] * 2)
		layer_counts.append(maxi(1, picked_c))

	var layer_edges: Array[Array] = []
	for s: int in range(num_stages):
		var next_c: int = layer_counts[s + 1] if (s + 1 < num_stages) else 0
		layer_edges.append(_build_planar_layer_edges(layer_counts[s], next_c, rng))

	var layer_types: Array[Array] = []
	for s: int in range(num_stages):
		layer_types.append(_pick_tier_node_types(tier_templates[s], layer_counts[s], rng))

	_enforce_sts_constraints(tier_templates, layer_types, layer_edges, rng)
	var coords: Dictionary = _compute_organic_positions(layer_counts, layer_edges, rng)
	var lanes_by_stage: Array = coords.get("lanes", []) as Array
	var y_jit_by_stage: Array = coords.get("y_jitters", []) as Array

	var event_bag: Array[String] = _build_shuffled_event_bag(repo, rng)

	for s: int in range(num_stages):
		var tmpl: Dictionary = tier_templates[s]
		var count: int = layer_counts[s]
		var enc_stage: int = maxi(1, int(tmpl.get("encounter_stage", s + 1)))
		var chosen_types: Array = layer_types[s]
		var stage_lanes: Array = lanes_by_stage[s] as Array
		var stage_yjits: Array = y_jit_by_stage[s] as Array
		var stage_edges: Array = layer_edges[s]

		var base_combat_enc: Dictionary = repo.encounter_for_stage(enc_stage)
		var combat_variants: Array = base_combat_enc.get("variants", []) as Array
		var shuffled_var_indices: Array[int] = _shuffled_indices(combat_variants.size(), rng)
		var var_cursor: int = 0
		var flip_bonus_parity: bool = (rng.randi_range(0, 1) == 1)

		for b: int in range(count):
			var node_id: String = "s%d_b%d" % [s, b]
			var lane_norm: float = float(stage_lanes[b])
			var y_jitter: float = float(stage_yjits[b])
			var ntype: String = str(chosen_types[b]) if b < chosen_types.size() else "combat"

			var var_dict: Dictionary = {}
			if (ntype == "combat" or ntype == "elite" or ntype == "boss") and not combat_variants.is_empty():
				var v_idx: int = shuffled_var_indices[var_cursor % shuffled_var_indices.size()]
				var_cursor += 1
				if typeof(combat_variants[v_idx]) == TYPE_DICTIONARY:
					var_dict = (combat_variants[v_idx] as Dictionary).duplicate(true)

			if ntype == "event" and event_bag.is_empty():
				event_bag = _build_shuffled_event_bag(repo, rng)
			var assigned_event_id: String = event_bag.pop_back() if (ntype == "event" and not event_bag.is_empty()) else ""

			var bonus_slot: int = (count - 1 - b) if flip_bonus_parity else b
			var node_dict: Dictionary = _build_typed_node(
				repo,
				node_id,
				s,
				b,
				count,
				lane_norm,
				y_jitter,
				ntype,
				enc_stage,
				var_dict,
				assigned_event_id,
				def_left_scrap,
				def_right_heal,
				bonus_slot
			)

			var next_ids: Array[String] = []
			if s + 1 < num_stages:
				var targets: Array = stage_edges[b] as Array
				for tgt_v: Variant in targets:
					next_ids.append("s%d_b%d" % [s + 1, int(tgt_v)])
			node_dict["next_ids"] = next_ids
			result.append(node_dict)

	return result

static func build_tutorial_dag(tutorial_enc: Dictionary) -> Array[Dictionary]:
	if tutorial_enc.is_empty():
		return []
	var empty_next: Array[String] = []
	return [{
		"id": "tutorial_0",
		"stage_index": 0,
		"branch_index": 0,
		"branch_count": 1,
		"lane_norm": 0.0,
		"y_jitter": 0.0,
		"type": str(tutorial_enc.get("type", "combat")),
		"event_id": "",
		"is_elite": false,
		"is_boss": false,
		"title": str(tutorial_enc.get("title", "")),
		"revealed_title": str(tutorial_enc.get("title", "")),
		"bonus_scrap": 0,
		"bonus_heal": 0,
		"encounter": tutorial_enc.duplicate(true),
		"next_ids": empty_next
	}]

static func find_node(nodes: Array[Dictionary], node_id: String) -> Dictionary:
	if node_id.is_empty():
		return {}
	for entry: Dictionary in nodes:
		if str(entry.get("id", "")) == node_id:
			return entry
	return {}

static func compute_reachable_ids(nodes: Array[Dictionary], from_id: String) -> Array[String]:
	var reachable: Array[String] = []
	if from_id.is_empty() or nodes.is_empty():
		return reachable
	var queue: Array[String] = [from_id]
	while not queue.is_empty():
		var cur_id: String = queue.pop_front()
		if reachable.has(cur_id):
			continue
		reachable.append(cur_id)
		var cur_node: Dictionary = find_node(nodes, cur_id)
		if cur_node.is_empty():
			continue
		var outgoing: Array = cur_node.get("next_ids", []) as Array
		for nxt_val: Variant in outgoing:
			var nxt_id: String = str(nxt_val)
			if not nxt_id.is_empty() and not reachable.has(nxt_id):
				queue.append(nxt_id)
	return reachable

static func compute_ancestor_ids(nodes: Array[Dictionary], target_id: String) -> Array[String]:
	var ancestors: Array[String] = []
	if target_id.is_empty() or nodes.is_empty():
		return ancestors
	var parents_by_id: Dictionary = {}
	for nd: Dictionary in nodes:
		var uid: String = str(nd.get("id", ""))
		for nxt_v: Variant in (nd.get("next_ids", []) as Array):
			var vid: String = str(nxt_v)
			if not parents_by_id.has(vid):
				parents_by_id[vid] = []
			(parents_by_id[vid] as Array).append(uid)
	var queue: Array[String] = [target_id]
	while not queue.is_empty():
		var cur_id: String = queue.pop_front()
		if ancestors.has(cur_id):
			continue
		ancestors.append(cur_id)
		for p_val: Variant in (parents_by_id.get(cur_id, []) as Array):
			var pid: String = str(p_val)
			if not pid.is_empty() and not ancestors.has(pid):
				queue.append(pid)
	return ancestors

static func semantic_node_kind(node_or_enc: Dictionary) -> String:
	if bool(node_or_enc.get("is_boss", false)) or str(node_or_enc.get("type", "")) == "boss":
		return "boss"
	if bool(node_or_enc.get("is_elite", false)) or str(node_or_enc.get("type", "")) == "elite":
		return "elite"
	var ntype: String = str(node_or_enc.get("type", "combat"))
	if ntype == "workshop" or ntype == "rest" or ntype == "upgrade" or ntype == "event":
		return ntype
	return "combat"

static func short_node_tag(nd: Dictionary) -> String:
	match semantic_node_kind(nd):
		"boss": return "BOSS"
		"elite": return "ELITE"
		"workshop": return "SHOP"
		"rest": return "REST"
		"upgrade": return "FORGE"
		"event": return "EVENT"
		_: return "FIGHT"

static func node_palette_key(node_or_enc: Dictionary) -> String:
	return "node_" + semantic_node_kind(node_or_enc)

static func display_title_for_node(repo: GameRepository, node_dict: Dictionary, is_visited_or_current: bool) -> String:
	if str(node_dict.get("type", "")) == "event" and not is_visited_or_current:
		return repo.get_ui_text("navigator", "unknown_event_title")
	var rev: String = str(node_dict.get("revealed_title", ""))
	if not rev.is_empty():
		return rev
	return str(node_dict.get("title", ""))

# Outerplanar monotonic walk (0,0)->(N-1,M-1) + non-crossing 2-way fork enrichment:
# guarantees 1 <= out_degree <= 2, in_degree >= 1, and 0 edge crossings.
static func _build_planar_layer_edges(cur_count: int, next_count: int, rng: RandomNumberGenerator) -> Array[Array]:
	var adj: Array[Array] = []
	for _i: int in range(cur_count):
		adj.append([])
	if cur_count <= 0 or next_count <= 0:
		return adj
	if next_count == 1:
		for i: int in range(cur_count):
			adj[i].append(0)
		return adj
	if cur_count == 1:
		for j: int in range(mini(2, next_count)):
			adj[0].append(j)
		return adj

	var i: int = 0
	var j: int = 0
	adj[0].append(0)

	while i < cur_count - 1 or j < next_count - 1:
		var valid_moves: Array[Vector2i] = []
		var weights: Array[float] = []
		var rem_after_step_i: int = cur_count - 2 - i

		if j + 1 <= next_count - 1 and adj[i].size() < 2:
			valid_moves.append(Vector2i(0, 1))
			weights.append(2.6)
		if i + 1 <= cur_count - 1 and (j + 1 + 2 * rem_after_step_i) >= (next_count - 1):
			valid_moves.append(Vector2i(1, 0))
			weights.append(1.15)
		if i + 1 <= cur_count - 1 and j + 1 <= next_count - 1 and (j + 2 + 2 * rem_after_step_i) >= (next_count - 1):
			valid_moves.append(Vector2i(1, 1))
			weights.append(1.65)

		var chosen: Vector2i = valid_moves[0]
		if valid_moves.size() > 1:
			var total_w: float = 0.0
			for w: float in weights:
				total_w += w
			var roll: float = rng.randf() * total_w
			var accum: float = 0.0
			for m_idx: int in range(valid_moves.size()):
				accum += weights[m_idx]
				if roll <= accum:
					chosen = valid_moves[m_idx]
					break

		i += chosen.x
		j += chosen.y
		if not adj[i].has(j):
			adj[i].append(j)

	var order: Array[int] = _shuffled_indices(cur_count, rng)
	for u: int in order:
		if adj[u].size() >= 2:
			continue
		var only_j: int = int(adj[u][0])
		var left_max: int = int(adj[u - 1].back()) if u > 0 else 0
		var right_min: int = int(adj[u + 1][0]) if (u + 1 < cur_count) else (next_count - 1)
		var cands: Array[int] = []
		if only_j - 1 >= left_max:
			cands.append(only_j - 1)
		if only_j + 1 <= right_min:
			cands.append(only_j + 1)
		if not cands.is_empty() and rng.randf() <= 0.82:
			var extra_j: int = cands[rng.randi_range(0, cands.size() - 1)]
			adj[u].append(extra_j)
			adj[u].sort()

	return adj

static func _enforce_sts_constraints(
	tier_templates: Array[Dictionary],
	layer_types: Array[Array],
	layer_edges: Array[Array],
	rng: RandomNumberGenerator
) -> void:
	var num_stages: int = layer_types.size()
	for _pass: int in range(2):
		for s: int in range(num_stages - 1):
			var cur_types: Array = layer_types[s]
			var nxt_types: Array = layer_types[s + 1]
			var edges_s: Array = layer_edges[s]
			for u: int in range(cur_types.size()):
				var t_u: String = str(cur_types[u])
				if not NO_REPEAT_TYPES.has(t_u):
					continue
				for v_val: Variant in (edges_s[u] as Array):
					var v: int = int(v_val)
					var t_v: String = str(nxt_types[v])
					if t_u != t_v:
						continue
					if _try_swap_stage_type(layer_types, layer_edges, s + 1, v, rng):
						continue
					if _try_swap_stage_type(layer_types, layer_edges, s, u, rng):
						t_u = str(cur_types[u])
						continue
					if _can_downgrade_type(tier_templates[s + 1], nxt_types, t_v):
						nxt_types[v] = _fallback_type_for_tier(tier_templates[s + 1], t_v)
					else:
						cur_types[u] = _fallback_type_for_tier(tier_templates[s], t_u)
						t_u = str(cur_types[u])

	# Sibling diversity pass: avoid offering two identical node types on a 2-way fork when a clean swap exists.
	for s: int in range(num_stages - 1):
		var nxt_types: Array = layer_types[s + 1]
		var edges_s: Array = layer_edges[s]
		for u: int in range(edges_s.size()):
			var outs: Array = edges_s[u] as Array
			if outs.size() < 2:
				continue
			var v0: int = int(outs[0])
			var v1: int = int(outs[1])
			if str(nxt_types[v0]) != str(nxt_types[v1]):
				continue
			_try_swap_for_sibling_diversity(layer_types, layer_edges, s + 1, v1, str(nxt_types[v0]), rng)

static func _has_repeat_violation_at(layer_types: Array[Array], layer_edges: Array[Array], stage_idx: int, branch_idx: int) -> bool:
	var t_cur: String = str(layer_types[stage_idx][branch_idx])
	if not NO_REPEAT_TYPES.has(t_cur):
		return false
	if stage_idx > 0:
		var prev_edges: Array = layer_edges[stage_idx - 1]
		var prev_types: Array = layer_types[stage_idx - 1]
		for pu: int in range(prev_edges.size()):
			if (prev_edges[pu] as Array).has(branch_idx) and str(prev_types[pu]) == t_cur:
				return true
	if stage_idx + 1 < layer_types.size():
		var nxt_types: Array = layer_types[stage_idx + 1]
		for nv_val: Variant in (layer_edges[stage_idx][branch_idx] as Array):
			if str(nxt_types[int(nv_val)]) == t_cur:
				return true
	return false

static func _try_swap_stage_type(layer_types: Array[Array], layer_edges: Array[Array], stage_idx: int, branch_idx: int, rng: RandomNumberGenerator) -> bool:
	var row: Array = layer_types[stage_idx]
	var orig: String = str(row[branch_idx])
	for w: int in _shuffled_indices(row.size(), rng):
		if w == branch_idx or str(row[w]) == orig:
			continue
		var tmp: String = str(row[w])
		row[w] = orig
		row[branch_idx] = tmp
		if not _has_repeat_violation_at(layer_types, layer_edges, stage_idx, branch_idx) and not _has_repeat_violation_at(layer_types, layer_edges, stage_idx, w):
			return true
		row[branch_idx] = orig
		row[w] = tmp
	return false

static func _try_swap_for_sibling_diversity(
	layer_types: Array[Array],
	layer_edges: Array[Array],
	stage_idx: int,
	branch_idx: int,
	avoid_type: String,
	rng: RandomNumberGenerator
) -> bool:
	var row: Array = layer_types[stage_idx]
	var orig: String = str(row[branch_idx])
	for w: int in _shuffled_indices(row.size(), rng):
		if w == branch_idx or str(row[w]) == avoid_type:
			continue
		var tmp: String = str(row[w])
		row[w] = orig
		row[branch_idx] = tmp
		if not _has_repeat_violation_at(layer_types, layer_edges, stage_idx, branch_idx) and not _has_repeat_violation_at(layer_types, layer_edges, stage_idx, w):
			return true
		row[branch_idx] = orig
		row[w] = tmp
	return false

static func _can_downgrade_type(tmpl: Dictionary, row: Array, ntype: String) -> bool:
	var guar_need: int = 0
	for gv: Variant in (tmpl.get("guaranteed", []) as Array):
		if str(gv) == ntype:
			guar_need += 1
	if guar_need <= 0:
		return true
	var have: int = 0
	for rv: Variant in row:
		if str(rv) == ntype:
			have += 1
	return have > guar_need

static func _fallback_type_for_tier(tmpl: Dictionary, avoid_type: String) -> String:
	for pv: Variant in (tmpl.get("pool", []) as Array):
		var ps: String = str(pv)
		if ps != avoid_type and not NO_REPEAT_TYPES.has(ps):
			return ps
	return "event" if avoid_type == "combat" else "combat"

static func _compute_organic_positions(layer_counts: Array[int], layer_edges: Array[Array], rng: RandomNumberGenerator) -> Dictionary:
	var num_stages: int = layer_counts.size()
	var lanes: Array[Array] = []
	var y_jitters: Array[Array] = []

	for s: int in range(num_stages):
		var c: int = layer_counts[s]
		var is_terminal: bool = (s == 0 or s == num_stages - 1)
		var row_x: Array[float] = []
		var row_y: Array[float] = []
		for b: int in range(c):
			var base_x: float = _compute_lane_norm(b, c)
			var jit_x: float = 0.0 if (is_terminal or c <= 1) else rng.randf_range(-0.09, 0.09)
			var jit_y: float = 0.0 if is_terminal else rng.randf_range(-0.13, 0.13)
			row_x.append(clampf(base_x + jit_x, -0.84, 0.84))
			row_y.append(jit_y)
		_enforce_row_spacing(row_x)
		lanes.append(row_x)
		y_jitters.append(row_y)

	for _iter: int in range(3):
		for s: int in range(1, num_stages - 1):
			var c: int = layer_counts[s]
			if c <= 1:
				continue
			var row_x: Array = lanes[s]
			for b: int in range(c):
				var sum_x: float = 0.0
				var w_cnt: float = 0.0
				for pu: int in range(layer_counts[s - 1]):
					if (layer_edges[s - 1][pu] as Array).has(b):
						sum_x += float(lanes[s - 1][pu])
						w_cnt += 1.0
				for nv_val: Variant in (layer_edges[s][b] as Array):
					sum_x += float(lanes[s + 1][int(nv_val)])
					w_cnt += 1.0
				if w_cnt > 0.0:
					row_x[b] = lerpf(float(row_x[b]), sum_x / w_cnt, 0.34)
			_enforce_row_spacing(row_x)

	return {"lanes": lanes, "y_jitters": y_jitters}

static func _enforce_row_spacing(row_x: Array) -> void:
	var n: int = row_x.size()
	if n <= 1:
		if n == 1:
			row_x[0] = 0.0
		return
	var min_gap: float = 0.56 if n == 2 else (0.48 if n == 3 else 0.42)
	for i: int in range(1, n):
		if float(row_x[i]) - float(row_x[i - 1]) < min_gap:
			row_x[i] = float(row_x[i - 1]) + min_gap
	var mid_shift: float = (float(row_x[0]) + float(row_x[n - 1])) * 0.5
	for i: int in range(n):
		row_x[i] = float(row_x[i]) - mid_shift * 0.45
	if float(row_x[n - 1]) > 0.85:
		var over_r: float = float(row_x[n - 1]) - 0.85
		for i: int in range(n):
			row_x[i] = float(row_x[i]) - over_r
	if float(row_x[0]) < -0.85:
		var over_l: float = -0.85 - float(row_x[0])
		for i: int in range(n):
			row_x[i] = float(row_x[i]) + over_l
	for i: int in range(n):
		row_x[i] = clampf(float(row_x[i]), -0.86, 0.86)

static func _pick_tier_node_types(tmpl: Dictionary, count: int, rng: RandomNumberGenerator) -> Array[String]:
	var chosen: Array[String] = []
	var guar_raw: Array = tmpl.get("guaranteed", []) as Array
	for g_val: Variant in guar_raw:
		if chosen.size() >= count:
			break
		chosen.append(str(g_val))

	var pool_raw: Array = tmpl.get("pool", ["combat"]) as Array
	var remaining: Array[String] = []
	for p_val: Variant in pool_raw:
		var p_str: String = str(p_val)
		if not chosen.has(p_str):
			remaining.append(p_str)
	_shuffle_string_array(remaining, rng)

	for rem_type: String in remaining:
		if chosen.size() >= count:
			break
		chosen.append(rem_type)

	while chosen.size() < count and not pool_raw.is_empty():
		chosen.append(str(pool_raw[rng.randi_range(0, pool_raw.size() - 1)]))

	if count > 1:
		_shuffle_string_array(chosen, rng)
	return chosen

static func _build_typed_node(
	repo: GameRepository,
	node_id: String,
	stage_idx: int,
	branch_idx: int,
	branch_count: int,
	lane_norm: float,
	y_jitter: float,
	node_type: String,
	enc_stage: int,
	var_dict: Dictionary,
	event_id: String,
	def_left_scrap: int,
	def_right_heal: int,
	bonus_slot: int
) -> Dictionary:
	var next_placeholder: Array[String] = []
	var is_elite: bool = (node_type == "elite")
	var is_boss: bool = (node_type == "boss")
	var resolved_enc: Dictionary = {}
	var shown_title: String = ""
	var revealed_title: String = ""
	var b_scrap: int = 0
	var b_heal: int = 0

	match node_type:
		"workshop":
			var w_base: Dictionary = repo.encounter_for_stage(4)
			resolved_enc = w_base.duplicate(true)
			resolved_enc["type"] = "workshop"
			resolved_enc["is_elite"] = false
			resolved_enc["is_boss"] = false
			shown_title = str(resolved_enc.get("title", ""))
			revealed_title = shown_title
		"rest":
			var r_site: Dictionary = repo.rest_site()
			shown_title = str(r_site.get("title", ""))
			revealed_title = shown_title
			resolved_enc = {
				"stage": stage_idx + 1,
				"title": shown_title,
				"type": "rest",
				"site_id": str(r_site.get("id", "rest_shelter")),
				"model_key": str(r_site.get("model_key", "node_rest_shelter")),
				"is_elite": false,
				"is_boss": false,
				"reward_scrap": 0,
				"enemies": []
			}
		"upgrade":
			var u_site: Dictionary = repo.upgrade_site()
			shown_title = str(u_site.get("title", ""))
			revealed_title = shown_title
			resolved_enc = {
				"stage": stage_idx + 1,
				"title": shown_title,
				"type": "upgrade",
				"site_id": str(u_site.get("id", "upgrade_forge")),
				"model_key": str(u_site.get("model_key", "node_upgrade_forge")),
				"is_elite": false,
				"is_boss": false,
				"reward_scrap": 0,
				"enemies": []
			}
		"event":
			var ev_data: Dictionary = repo.get_random_event(event_id)
			var resolved_ev_id: String = str(ev_data.get("id", event_id))
			revealed_title = str(ev_data.get("title", ""))
			shown_title = repo.get_ui_text("navigator", "unknown_event_title")
			resolved_enc = {
				"stage": stage_idx + 1,
				"title": shown_title,
				"revealed_title": revealed_title,
				"type": "event",
				"event_id": resolved_ev_id,
				"model_key": str(ev_data.get("model_key", "node_event_ruined_road")),
				"is_elite": false,
				"is_boss": false,
				"reward_scrap": 0,
				"enemies": []
			}
		"boss":
			var boss_enc: Dictionary = repo.encounter_for_stage(7)
			resolved_enc = _build_node_encounter(boss_enc, var_dict, bonus_slot, branch_count, 0, 0)
			resolved_enc["type"] = "combat"
			resolved_enc["is_boss"] = true
			resolved_enc["is_elite"] = false
			shown_title = str(resolved_enc.get("title", ""))
			revealed_title = shown_title
		"elite":
			var elite_stage: int = maxi(5, mini(6, enc_stage))
			var elite_base: Dictionary = repo.encounter_for_stage(elite_stage)
			resolved_enc = _build_node_encounter(elite_base, var_dict, bonus_slot, branch_count, 0, 0)
			resolved_enc["type"] = "combat"
			resolved_enc["is_elite"] = true
			resolved_enc["is_boss"] = false
			shown_title = str(resolved_enc.get("title", ""))
			revealed_title = shown_title
			b_scrap = int(resolved_enc.get("bonus_scrap", 0))
			b_heal = int(resolved_enc.get("bonus_heal", 0))
		_:
			var c_stage: int = clampi(enc_stage, 1, 3)
			var c_base: Dictionary = repo.encounter_for_stage(c_stage)
			resolved_enc = _build_node_encounter(c_base, var_dict, bonus_slot, branch_count, def_left_scrap, def_right_heal)
			resolved_enc["type"] = "combat"
			resolved_enc["is_elite"] = false
			resolved_enc["is_boss"] = false
			shown_title = str(resolved_enc.get("title", ""))
			revealed_title = shown_title
			b_scrap = int(resolved_enc.get("bonus_scrap", 0))
			b_heal = int(resolved_enc.get("bonus_heal", 0))

	return {
		"id": node_id,
		"stage_index": stage_idx,
		"branch_index": branch_idx,
		"branch_count": branch_count,
		"lane_norm": lane_norm,
		"y_jitter": y_jitter,
		"type": "combat" if (node_type == "elite" or node_type == "boss") else node_type,
		"event_id": str(resolved_enc.get("event_id", "")),
		"is_elite": is_elite,
		"is_boss": is_boss,
		"title": shown_title,
		"revealed_title": revealed_title,
		"bonus_scrap": b_scrap,
		"bonus_heal": b_heal,
		"encounter": resolved_enc,
		"next_ids": next_placeholder
	}

static func _compute_lane_norm(branch_idx: int, branch_count: int) -> float:
	if branch_count <= 1:
		return 0.0
	if branch_count == 2:
		return -0.48 if branch_idx == 0 else 0.48
	var t: float = float(branch_idx) / float(branch_count - 1)
	return lerpf(-0.78, 0.78, t)

static func _build_node_encounter(
	base_enc: Dictionary,
	var_dict: Dictionary,
	bonus_slot: int,
	branch_count: int,
	def_left_scrap: int,
	def_right_heal: int
) -> Dictionary:
	var merged: Dictionary = base_enc.duplicate(true)
	merged.erase("variants")
	if not var_dict.is_empty():
		merged["title"] = str(var_dict.get("title", base_enc.get("title", "")))
		merged["enemies"] = (var_dict.get("enemies", base_enc.get("enemies", [])) as Array).duplicate(true)

	var b_scrap: int = int(var_dict.get("bonus_scrap", merged.get("bonus_scrap", 0)))
	var b_heal: int = int(var_dict.get("bonus_heal", merged.get("bonus_heal", 0)))
	if branch_count >= 2 and b_scrap == 0 and b_heal == 0 and (def_left_scrap > 0 or def_right_heal > 0):
		if bonus_slot % 2 == 0:
			b_scrap = def_left_scrap
		else:
			b_heal = def_right_heal
	merged["bonus_scrap"] = b_scrap
	merged["bonus_heal"] = b_heal
	return merged

static func _build_shuffled_event_bag(repo: GameRepository, rng: RandomNumberGenerator) -> Array[String]:
	var bag: Array[String] = []
	for ev_dict: Dictionary in repo.all_random_events:
		var eid: String = str(ev_dict.get("id", ""))
		if not eid.is_empty():
			bag.append(eid)
	_shuffle_string_array(bag, rng)
	return bag

static func _shuffle_string_array(arr: Array[String], rng: RandomNumberGenerator) -> void:
	for i: int in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: String = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

static func _shuffled_indices(count: int, rng: RandomNumberGenerator) -> Array[int]:
	var arr: Array[int] = []
	for i: int in range(count):
		arr.append(i)
	for i: int in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: int = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr
