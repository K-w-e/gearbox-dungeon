class_name Navigator3DController
extends Node3D

signal fork_option_clicked(option_index: int)
signal fork_option_hovered(option_index: int)

const LEGEND_KINDS: Array[String] = ["combat", "elite", "event", "upgrade", "rest", "workshop"]
const LEGEND_LABELS: Array[String] = ["FIGHT", "ELITE", "EVENT", "FORGE", "REST", "SHOP"]

var repo: GameRepository
var engine: CombatEngine

var nav_model: Node3D
var compass_needle: Node3D
var encoder_knob: Node3D
var signal_tip_mat: StandardMaterial3D

var screen_mesh: MeshInstance3D
var screen_area: Area3D
var nav_canvas: _NavigatorCanvas
var graph_clip: Control
var graph_canvas: _NavigatorGraphCanvas

var vp_size: Vector2 = Vector2.ZERO
var world_size: Vector2 = Vector2.ZERO

var is_zoomed: bool = false
var hovered_node_id: String = ""
var inspected_node_id: String = ""
var hovered_zoom_btn: bool = false
var hovered_legend_kind: String = ""
var pinned_legend_kind: String = ""
var hovered_scroll_part: String = ""
var external_hovered_fork_idx: int = -1
var transition_progress: float = 0.0
var target_compass_deg: float = 0.0
var current_compass_deg: float = 0.0
var target_knob_deg: float = 0.0
var current_knob_deg: float = 0.0
var scroll_stage_center: float = 1.8
var target_scroll_stage: float = 1.8
var last_tracked_stage: int = -1
var time_accum: float = 0.0
var redraw_accum: float = 0.0

var node_hotspots: Array[Dictionary] = []
var legend_rects: Array[Dictionary] = []
var zoom_btn_rect: Rect2 = Rect2()
var scroll_up_rect: Rect2 = Rect2()
var scroll_down_rect: Rect2 = Rect2()
var scroll_track_rect: Rect2 = Rect2()

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	if repository == null or combat_engine == null:
		push_error("Navigator3DController.initialize received null dependencies")
		return
	repo = repository
	engine = combat_engine

	var ncfg: Dictionary = repo.cockpit.get("navigator_3d", {}) as Dictionary
	position = JsonConfigLoader.to_vec3(ncfg.get("pos", []), Vector3.ZERO)
	rotation_degrees = JsonConfigLoader.to_vec3(ncfg.get("rot_deg", []), Vector3.ZERO)
	scale = JsonConfigLoader.to_vec3(ncfg.get("scale", []), Vector3.ONE)

	var model_scene: PackedScene = repo.load_model_scene("cockpit_navigator")
	if model_scene != null:
		nav_model = model_scene.instantiate() as Node3D
		add_child(nav_model)
		compass_needle = nav_model.find_child("NavCompassNeedle", true, false) as Node3D
		encoder_knob = nav_model.find_child("NavEncoderKnob", true, false) as Node3D
		var tip_mesh: MeshInstance3D = nav_model.find_child("NavSignalTip", true, false) as MeshInstance3D
		if tip_mesh != null:
			signal_tip_mat = StandardMaterial3D.new()
			signal_tip_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			signal_tip_mat.albedo_color = repo.get_palette_color("nav_visited")
			tip_mesh.material_override = signal_tip_mat

	vp_size = JsonConfigLoader.to_vec2(ncfg.get("viewport_size", []), Vector2(640.0, 736.0))
	world_size = JsonConfigLoader.to_vec2(ncfg.get("screen_size_m", []), Vector2(0.22, 0.252))
	var scr_off: Vector3 = JsonConfigLoader.to_vec3(ncfg.get("screen_offset", []), Vector3.ZERO)

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		self,
		Vector2i(int(vp_size.x), int(vp_size.y)),
		world_size,
		scr_off,
		Vector3.ZERO,
		false,
		false
	)
	screen_mesh = scr.get("mesh") as MeshInstance3D
	var scr_root: Control = scr.get("root") as Control

	nav_canvas = _NavigatorCanvas.new()
	nav_canvas.nav = self
	nav_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scr_root.add_child(nav_canvas)

	graph_clip = Control.new()
	graph_clip.clip_contents = true
	graph_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav_canvas.add_child(graph_clip)

	graph_canvas = _NavigatorGraphCanvas.new()
	graph_canvas.nav = self
	graph_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	graph_clip.add_child(graph_canvas)

	var col_layer: int = maxi(1, int(ncfg.get("collision_layer", 2)))
	var col_depth: float = maxf(0.008, float(ncfg.get("collider_depth", 0.024)))
	screen_area = Area3D.new()
	screen_area.collision_layer = col_layer
	screen_area.collision_mask = 0
	screen_area.position = scr_off + Vector3(0.0, 0.0, col_depth * 0.35)
	screen_area.set_meta("interact_type", "navigator_screen")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(world_size.x * 1.08, world_size.y * 1.08, col_depth)
	cs.shape = box
	screen_area.add_child(cs)
	add_child(screen_area)

	engine.state_changed.connect(_on_engine_state_changed)
	_on_engine_state_changed()

func max_map_stage() -> int:
	var m: int = 1
	if engine != null:
		for nd: Dictionary in engine.run_map_nodes:
			m = maxi(m, int(nd.get("stage_index", 0)))
	return m

func current_node_stage() -> int:
	if engine == null:
		return 0
	var cur_nd: Dictionary = RunMapGenerator.find_node(engine.run_map_nodes, engine.current_map_node_id)
	if not cur_nd.is_empty():
		return int(cur_nd.get("stage_index", engine.stage_index))
	return engine.stage_index

func scroll_bounds(zoomed_mode: bool) -> Vector2:
	var max_s: float = float(max_map_stage())
	if max_s <= 3.0:
		return Vector2(max_s * 0.5, max_s * 0.5)
	var half_span: float = 2.55 if zoomed_mode else 2.05
	var lo: float = minf(half_span - 0.65, max_s * 0.5)
	var hi: float = maxf(lo, max_s - half_span + 0.55)
	return Vector2(lo, hi)

func snap_scroll_to_current_stage() -> void:
	if engine == null:
		return
	var b: Vector2 = scroll_bounds(is_zoomed)
	var cur_s: float = float(current_node_stage())
	var lead: float = 1.85 if is_zoomed else 1.45
	target_scroll_stage = clampf(cur_s + lead, b.x, b.y)
	scroll_stage_center = target_scroll_stage

func scroll_map(stage_delta: float) -> void:
	if engine == null or engine.run_map_nodes.is_empty():
		return
	var b: Vector2 = scroll_bounds(is_zoomed)
	var next_t: float = clampf(target_scroll_stage + stage_delta, b.x, b.y)
	if absf(next_t - target_scroll_stage) <= 0.001:
		return
	target_scroll_stage = next_t
	target_knob_deg += stage_delta * 14.0
	refresh_display()

func active_legend_filter() -> String:
	if not hovered_legend_kind.is_empty():
		return hovered_legend_kind
	return pinned_legend_kind

func toggle_zoom() -> void:
	if engine != null and engine.mode == CombatEngine.MODE_TITLE:
		return
	set_zoomed(not is_zoomed)

func set_zoomed(zoomed: bool) -> void:
	if is_zoomed == zoomed:
		return
	is_zoomed = zoomed
	if not is_zoomed:
		hovered_legend_kind = ""
		pinned_legend_kind = ""
		hovered_scroll_part = ""
		inspected_node_id = ""
	snap_scroll_to_current_stage()
	var ncfg: Dictionary = repo.cockpit.get("navigator_3d", {}) as Dictionary
	var step_deg: float = float(ncfg.get("knob_step_deg", 45.0))
	target_knob_deg += step_deg if is_zoomed else -step_deg
	if engine != null:
		engine.sfx_requested.emit("hydraulic_servo", 0.65)
	refresh_display()

func set_compass_heading_deg(heading_deg: float) -> void:
	target_compass_deg = heading_deg

func set_route_transition_progress(progress: float) -> void:
	transition_progress = clampf(progress, 0.0, 1.0)
	refresh_display()

func set_external_hovered_fork_option(option_idx: int) -> void:
	if external_hovered_fork_idx == option_idx:
		return
	external_hovered_fork_idx = option_idx
	refresh_display()

func clear_hover() -> void:
	var had_hover: bool = (
		not hovered_node_id.is_empty()
		or hovered_zoom_btn
		or not hovered_legend_kind.is_empty()
		or not hovered_scroll_part.is_empty()
	)
	hovered_node_id = ""
	hovered_zoom_btn = false
	hovered_legend_kind = ""
	hovered_scroll_part = ""
	if had_hover:
		fork_option_hovered.emit(-1)
		refresh_display()

func world_pos_to_viewport(world_hit: Vector3) -> Vector2:
	if screen_mesh == null:
		return Vector2(-1.0, -1.0)
	var local: Vector3 = screen_mesh.to_local(world_hit)
	var u: float = (local.x / maxf(0.01, world_size.x)) + 0.5
	var v: float = 0.5 - (local.y / maxf(0.01, world_size.y))
	return Vector2(u * vp_size.x, v * vp_size.y)

func count_reachable_of_kind(kind: String) -> int:
	if engine == null:
		return 0
	var reachable: Array[String] = RunMapGenerator.compute_reachable_ids(engine.run_map_nodes, engine.current_map_node_id)
	var cnt: int = 0
	for nd: Dictionary in engine.run_map_nodes:
		var nid: String = str(nd.get("id", ""))
		if nid == engine.current_map_node_id or not reachable.has(nid):
			continue
		if RunMapGenerator.semantic_node_kind(nd) == kind:
			cnt += 1
	return cnt

func describe_route_via_fork(target_id: String) -> String:
	if engine == null or repo == null or target_id.is_empty() or target_id == engine.current_map_node_id:
		return ""
	var cur_nd: Dictionary = RunMapGenerator.find_node(engine.run_map_nodes, engine.current_map_node_id)
	var outs: Array = cur_nd.get("next_ids", []) as Array
	if outs.size() < 2:
		return ""
	var anc: Array[String] = RunMapGenerator.compute_ancestor_ids(engine.run_map_nodes, target_id)
	var via_l: bool = anc.has(str(outs[0]))
	var via_r: bool = anc.has(str(outs[1]))
	if via_l and via_r:
		return repo.get_ui_text("navigator", "route_via_both")
	if via_l:
		return repo.get_ui_text("navigator", "route_via_left")
	if via_r:
		return repo.get_ui_text("navigator", "route_via_right")
	return ""

func update_hover_world_pos(world_hit: Vector3) -> String:
	if repo == null or engine == null:
		return ""
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	var ncfg: Dictionary = repo.cockpit.get("navigator_3d", {}) as Dictionary
	var hit_rad: float = maxf(16.0, float(ncfg.get("node_hit_radius", 28.0)))

	var next_zoom_hover: bool = zoom_btn_rect.has_point(pt)
	var next_legend: String = ""
	var next_scroll: String = ""
	var next_node_id: String = ""
	var hovered_fork_idx: int = -1

	if is_zoomed and not next_zoom_hover:
		for lg: Dictionary in legend_rects:
			if (lg.get("rect", Rect2()) as Rect2).has_point(pt):
				next_legend = str(lg.get("kind", ""))
				break
		if next_legend.is_empty():
			if scroll_up_rect.has_point(pt):
				next_scroll = "up"
			elif scroll_down_rect.has_point(pt):
				next_scroll = "down"
			elif scroll_track_rect.has_point(pt):
				next_scroll = "track"

	if not next_zoom_hover and next_legend.is_empty() and next_scroll.is_empty():
		var best_dist: float = hit_rad
		for hs: Dictionary in node_hotspots:
			var center: Vector2 = hs.get("pos", Vector2.ZERO) as Vector2
			var d: float = center.distance_to(pt)
			if d <= best_dist:
				best_dist = d
				next_node_id = str(hs.get("id", ""))
				hovered_fork_idx = int(hs.get("fork_index", -1))

	if (
		next_node_id != hovered_node_id
		or next_zoom_hover != hovered_zoom_btn
		or next_legend != hovered_legend_kind
		or next_scroll != hovered_scroll_part
	):
		hovered_node_id = next_node_id
		hovered_zoom_btn = next_zoom_hover
		hovered_legend_kind = next_legend
		hovered_scroll_part = next_scroll
		fork_option_hovered.emit(hovered_fork_idx)
		refresh_display()

	if not hovered_legend_kind.is_empty():
		var idx_k: int = LEGEND_KINDS.find(hovered_legend_kind)
		var lbl_k: String = LEGEND_LABELS[idx_k] if idx_k >= 0 else hovered_legend_kind.to_upper()
		return repo.get_ui_text("navigator", "hover_legend_fmt") % [lbl_k, count_reachable_of_kind(hovered_legend_kind)]

	if not hovered_node_id.is_empty():
		var nd: Dictionary = RunMapGenerator.find_node(engine.run_map_nodes, hovered_node_id)
		if not nd.is_empty():
			var is_vis: bool = engine.visited_map_node_ids.has(hovered_node_id) or (hovered_node_id == engine.current_map_node_id)
			var shown_title: String = RunMapGenerator.display_title_for_node(repo, nd, is_vis)
			var bonus_txt: String = format_node_bonus(nd)
			if hovered_fork_idx >= 0 and engine.mode == CombatEngine.MODE_ROUTE_CHOICE:
				return repo.get_ui_text("navigator", "hover_fork_node") % [
					hovered_fork_idx + 1,
					shown_title,
					bonus_txt
				]
			var via_str: String = describe_route_via_fork(hovered_node_id)
			var status_lbl: String = describe_node_status(hovered_node_id)
			if not via_str.is_empty():
				status_lbl += " • " + via_str
			return repo.get_ui_text("navigator", "hover_node_info") % [
				status_lbl,
				shown_title,
				bonus_txt
			]

	return repo.get_ui_text("navigator", "hover_default")

func click_world_pos(world_hit: Vector3) -> bool:
	if repo == null or engine == null:
		return false
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	update_hover_world_pos(world_hit)

	if hovered_zoom_btn:
		toggle_zoom()
		return true

	if not hovered_node_id.is_empty() and engine.mode == CombatEngine.MODE_ROUTE_CHOICE:
		var fork_ids: Array[String] = engine.active_fork_node_ids()
		var f_idx: int = fork_ids.find(hovered_node_id)
		if f_idx >= 0:
			fork_option_clicked.emit(f_idx)
			return true

	if not is_zoomed:
		set_zoomed(true)
		return true

	if not hovered_legend_kind.is_empty():
		pinned_legend_kind = "" if pinned_legend_kind == hovered_legend_kind else hovered_legend_kind
		engine.sfx_requested.emit("switch_click", 0.65)
		refresh_display()
		return true

	if hovered_scroll_part == "up":
		scroll_map(1.8)
		engine.sfx_requested.emit("switch_click", 0.6)
		return true
	if hovered_scroll_part == "down":
		scroll_map(-1.8)
		engine.sfx_requested.emit("switch_click", 0.6)
		return true
	if hovered_scroll_part == "track" and scroll_track_rect.size.y > 8.0:
		var ratio_top: float = clampf((pt.y - scroll_track_rect.position.y) / scroll_track_rect.size.y, 0.0, 1.0)
		var b: Vector2 = scroll_bounds(true)
		target_scroll_stage = lerpf(b.y, b.x, ratio_top)
		engine.sfx_requested.emit("switch_click", 0.55)
		refresh_display()
		return true

	if not hovered_node_id.is_empty():
		inspected_node_id = "" if inspected_node_id == hovered_node_id else hovered_node_id
		engine.sfx_requested.emit("switch_click", 0.55)
		refresh_display()
		return true

	return true

func describe_node_status(node_id: String) -> String:
	if engine == null or repo == null:
		return ""
	if node_id == engine.current_map_node_id:
		return repo.get_ui_text("navigator", "status_current")
	if engine.visited_map_node_ids.has(node_id):
		return repo.get_ui_text("navigator", "status_cleared")
	var fork_ids: Array[String] = engine.active_fork_node_ids()
	if fork_ids.has(node_id) and (engine.mode == CombatEngine.MODE_ROUTE_CHOICE or engine.mode == CombatEngine.MODE_ROUTE_TRANSITION):
		return repo.get_ui_text("navigator", "status_fork")
	var reachable: Array[String] = RunMapGenerator.compute_reachable_ids(engine.run_map_nodes, engine.current_map_node_id)
	if reachable.has(node_id):
		return repo.get_ui_text("navigator", "status_reachable")
	return repo.get_ui_text("navigator", "status_bypassed")

func format_node_bonus(node_dict: Dictionary) -> String:
	if repo == null:
		return ""
	var ntype: String = str(node_dict.get("type", "combat"))
	if ntype == "workshop":
		return repo.get_ui_text("navigator", "tag_workshop")
	if ntype == "rest":
		return repo.get_ui_text("navigator", "tag_rest")
	if ntype == "upgrade":
		return repo.get_ui_text("navigator", "tag_upgrade")
	if ntype == "event":
		return repo.get_ui_text("navigator", "tag_event")
	if bool(node_dict.get("is_boss", false)):
		return repo.get_ui_text("navigator", "tag_boss")
	var parts: Array[String] = []
	if bool(node_dict.get("is_elite", false)):
		parts.append(repo.get_ui_text("navigator", "tag_elite"))
	var b_scrap: int = int(node_dict.get("bonus_scrap", 0))
	var b_heal: int = int(node_dict.get("bonus_heal", 0))
	if b_scrap > 0:
		parts.append(repo.get_ui_text("fork", "bonus_scrap_fmt") % b_scrap)
	if b_heal > 0:
		parts.append(repo.get_ui_text("fork", "bonus_heal_fmt") % b_heal)
	if parts.is_empty():
		return repo.get_ui_text("navigator", "tag_combat")
	return " • ".join(parts)

func refresh_display() -> void:
	if nav_canvas != null:
		nav_canvas.rebuild_layout_and_hotspots()
		if graph_canvas != null:
			graph_canvas.queue_redraw()
		DiegeticScreenFactory.request_redraw(nav_canvas)

func _on_engine_state_changed() -> void:
	if engine != null:
		var modal_open: bool = (
			engine.mode == CombatEngine.MODE_TITLE
			or engine.mode == CombatEngine.MODE_REWARD
			or engine.mode == CombatEngine.MODE_WORKSHOP
			or not engine.site_selecting_deck_action.is_empty()
		)
		if modal_open:
			is_zoomed = false
			hovered_legend_kind = ""
			pinned_legend_kind = ""
		if engine.mode != CombatEngine.MODE_ROUTE_TRANSITION:
			transition_progress = 0.0
		var cur_stg: int = current_node_stage()
		if cur_stg != last_tracked_stage or engine.run_map_nodes.size() <= 1:
			last_tracked_stage = cur_stg
			inspected_node_id = ""
			snap_scroll_to_current_stage()
	refresh_display()

func _process(delta: float) -> void:
	if repo == null or engine == null:
		return
	time_accum += delta
	var ncfg: Dictionary = repo.cockpit.get("navigator_3d", {}) as Dictionary

	var z_smooth: float = clampf(delta * float(ncfg.get("zoom_smoothing", 11.5)), 0.0, 1.0)
	var dst_pos: Vector3 = JsonConfigLoader.to_vec3(ncfg.get("zoom_pos" if is_zoomed else "pos", []), position)
	var dst_rot: Vector3 = JsonConfigLoader.to_vec3(ncfg.get("zoom_rot_deg" if is_zoomed else "rot_deg", []), rotation_degrees)
	var dst_scl: Vector3 = JsonConfigLoader.to_vec3(ncfg.get("zoom_scale" if is_zoomed else "scale", []), scale)
	position = position.lerp(dst_pos, z_smooth)
	rotation_degrees = rotation_degrees.lerp(dst_rot, z_smooth)
	scale = scale.lerp(dst_scl, z_smooth)

	var b: Vector2 = scroll_bounds(is_zoomed)
	target_scroll_stage = clampf(target_scroll_stage, b.x, b.y)
	var scroll_diff: float = absf(scroll_stage_center - target_scroll_stage)
	if scroll_diff > 0.002:
		scroll_stage_center = lerpf(scroll_stage_center, target_scroll_stage, clampf(delta * 13.0, 0.0, 1.0))
	else:
		scroll_stage_center = target_scroll_stage

	if compass_needle != null:
		var c_smooth: float = clampf(delta * float(ncfg.get("compass_smoothing", 6.5)), 0.0, 1.0)
		var jitter: float = sin(time_accum * 9.5) * (1.2 + float(engine.rpm_units) * 0.35)
		current_compass_deg = lerpf(current_compass_deg, target_compass_deg + jitter, c_smooth)
		compass_needle.rotation_degrees.y = current_compass_deg

	if encoder_knob != null:
		var k_smooth: float = clampf(delta * float(ncfg.get("knob_smoothing", 12.0)), 0.0, 1.0)
		current_knob_deg = lerpf(current_knob_deg, target_knob_deg, k_smooth)
		encoder_knob.rotation_degrees.x = current_knob_deg

	if signal_tip_mat != null:
		var pulse_spd: float = float(ncfg.get("signal_pulse_speed", 3.8))
		var pulse: float = 0.55 + 0.45 * (0.5 + 0.5 * sin(time_accum * pulse_spd))
		var tip_key: String = "fork_left_glow" if engine.mode == CombatEngine.MODE_ROUTE_CHOICE else ("node_event" if engine.is_site_mode() else "nav_visited")
		var base_c: Color = repo.get_palette_color(tip_key)
		signal_tip_mat.albedo_color = base_c * pulse

	redraw_accum += delta
	var needs_fast_redraw: bool = scroll_diff > 0.003
	if nav_canvas != null and (needs_fast_redraw or redraw_accum >= 0.085) and engine.mode != CombatEngine.MODE_TITLE:
		redraw_accum = 0.0
		if needs_fast_redraw:
			nav_canvas.rebuild_layout_and_hotspots()
		if graph_canvas != null:
			graph_canvas.queue_redraw()
		DiegeticScreenFactory.request_redraw(nav_canvas)


class _NavigatorCanvas extends Control:
	var nav: Navigator3DController
	var local_pos_by_id: Dictionary = {}
	var clip_rect: Rect2 = Rect2()
	var row_step_px: float = 96.0

	static func _short_node_tag(nd: Dictionary) -> String:
		return RunMapGenerator.short_node_tag(nd)

	static func draw_map_node_icon(canvas: Control, c: Vector2, r: float, nd: Dictionary, col: Color, font: Font) -> void:
		var kind: String = RunMapGenerator.semantic_node_kind(nd)
		match kind:
			"workshop":
				CardEmblemCanvas._s_draw_gear_wheel(canvas, c, r * 0.68, col, 7)
				canvas.draw_circle(c, r * 0.28, Color(0.03, 0.035, 0.04, 0.92))
				if font != null and r >= 13.0:
					var s_px: int = maxi(10, roundi(r * 0.72))
					canvas.draw_string_outline(font, Vector2(c.x - r, c.y + float(s_px) * 0.35), "$", HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, s_px, 2, Color.BLACK)
					canvas.draw_string(font, Vector2(c.x - r, c.y + float(s_px) * 0.35), "$", HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, s_px, col.lightened(0.45))
			"rest":
				var flame_outer: PackedVector2Array = PackedVector2Array([
					c + Vector2(0.0, -r * 0.66),
					c + Vector2(r * 0.42, -r * 0.14),
					c + Vector2(r * 0.34, r * 0.32),
					c + Vector2(0.0, r * 0.44),
					c + Vector2(-r * 0.34, r * 0.32),
					c + Vector2(-r * 0.42, -r * 0.14)
				])
				canvas.draw_colored_polygon(flame_outer, col)
				var flame_inner: PackedVector2Array = PackedVector2Array([
					c + Vector2(0.0, -r * 0.28),
					c + Vector2(r * 0.18, r * 0.04),
					c + Vector2(0.0, r * 0.30),
					c + Vector2(-r * 0.18, r * 0.04)
				])
				canvas.draw_colored_polygon(flame_inner, col.lightened(0.48))
				canvas.draw_line(c + Vector2(-r * 0.48, r * 0.54), c + Vector2(r * 0.48, r * 0.54), col.lightened(0.18), maxf(2.0, r * 0.16))
			"upgrade":
				var anvil_top: PackedVector2Array = PackedVector2Array([
					c + Vector2(-r * 0.58, -r * 0.10),
					c + Vector2(r * 0.56, -r * 0.10),
					c + Vector2(r * 0.30, r * 0.18),
					c + Vector2(-r * 0.30, r * 0.18)
				])
				canvas.draw_colored_polygon(anvil_top, col)
				canvas.draw_rect(Rect2(c + Vector2(-r * 0.42, r * 0.24), Vector2(r * 0.84, r * 0.24)), col, true)
				canvas.draw_line(c + Vector2(-r * 0.28, -r * 0.56), c + Vector2(r * 0.14, -r * 0.22), col.lightened(0.32), maxf(2.0, r * 0.15))
				canvas.draw_rect(Rect2(c + Vector2(r * 0.02, -r * 0.42), Vector2(r * 0.30, r * 0.18)), col.lightened(0.38), true)
			"event":
				var d_pts: PackedVector2Array = PackedVector2Array([
					c + Vector2(0.0, -r * 0.64),
					c + Vector2(r * 0.64, 0.0),
					c + Vector2(0.0, r * 0.64),
					c + Vector2(-r * 0.64, 0.0),
					c + Vector2(0.0, -r * 0.64)
				])
				canvas.draw_polyline(d_pts, Color(col.r, col.g, col.b, 0.72), maxf(1.6, r * 0.11), true)
				if font != null:
					var q_size: int = maxi(12, roundi(r * 1.05))
					canvas.draw_string_outline(font, Vector2(c.x - r, c.y + float(q_size) * 0.36), "?", HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, q_size, 3, Color.BLACK)
					canvas.draw_string(font, Vector2(c.x - r, c.y + float(q_size) * 0.36), "?", HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, q_size, col.lightened(0.42))
			"boss":
				var crown: PackedVector2Array = PackedVector2Array([
					c + Vector2(-r * 0.62, r * 0.36),
					c + Vector2(-r * 0.68, -r * 0.34),
					c + Vector2(-r * 0.28, -r * 0.06),
					c + Vector2(0.0, -r * 0.64),
					c + Vector2(r * 0.28, -r * 0.06),
					c + Vector2(r * 0.68, -r * 0.34),
					c + Vector2(r * 0.62, r * 0.36)
				])
				canvas.draw_colored_polygon(crown, Color(col.r, col.g, col.b, 0.42))
				crown.append(crown[0])
				canvas.draw_polyline(crown, col.lightened(0.22), maxf(2.0, r * 0.13), true)
				canvas.draw_circle(c + Vector2(-r * 0.22, r * 0.10), maxf(1.8, r * 0.12), col.lightened(0.5))
				canvas.draw_circle(c + Vector2(r * 0.22, r * 0.10), maxf(1.8, r * 0.12), col.lightened(0.5))
			"elite":
				var horns: PackedVector2Array = PackedVector2Array([
					c + Vector2(0.0, -r * 0.70),
					c + Vector2(r * 0.26, -r * 0.28),
					c + Vector2(r * 0.68, -r * 0.46),
					c + Vector2(r * 0.46, r * 0.14),
					c + Vector2(0.0, r * 0.66),
					c + Vector2(-r * 0.46, r * 0.14),
					c + Vector2(-r * 0.68, -r * 0.46),
					c + Vector2(-r * 0.26, -r * 0.28)
				])
				canvas.draw_colored_polygon(horns, Color(col.r, col.g, col.b, 0.38))
				horns.append(horns[0])
				canvas.draw_polyline(horns, col.lightened(0.18), maxf(1.9, r * 0.13), true)
				canvas.draw_circle(c + Vector2(0.0, r * 0.04), maxf(2.0, r * 0.19), col.lightened(0.46))
			_:
				var blade_w: float = maxf(2.0, r * 0.16)
				var d: float = r * 0.48
				canvas.draw_line(c + Vector2(-d, -d), c + Vector2(d, d), col, blade_w)
				canvas.draw_line(c + Vector2(-d, d), c + Vector2(d, -d), col, blade_w)
				canvas.draw_arc(c, r * 0.28, 0.0, TAU, 14, col.lightened(0.28), maxf(1.6, r * 0.11), true)

	func rebuild_layout_and_hotspots() -> void:
		local_pos_by_id.clear()
		if nav == null or nav.repo == null or nav.engine == null:
			return
		nav.node_hotspots.clear()
		nav.legend_rects.clear()

		var sz: Vector2 = nav.vp_size
		nav.zoom_btn_rect = Rect2(sz.x - 166.0, 9.0, 152.0, 36.0)

		if nav.is_zoomed:
			var leg_x0: float = 12.0
			var leg_w: float = (sz.x - 24.0 - 5.0 * 6.0) / 6.0
			for li: int in range(Navigator3DController.LEGEND_KINDS.size()):
				nav.legend_rects.append({
					"kind": Navigator3DController.LEGEND_KINDS[li],
					"label": Navigator3DController.LEGEND_LABELS[li],
					"rect": Rect2(leg_x0 + float(li) * (leg_w + 6.0), 52.0, leg_w, 34.0)
				})
			clip_rect = Rect2(12.0, 92.0, sz.x - 46.0, sz.y - 92.0 - 118.0)
			var sb_x: float = sz.x - 30.0
			nav.scroll_up_rect = Rect2(sb_x, clip_rect.position.y, 20.0, 26.0)
			nav.scroll_down_rect = Rect2(sb_x, clip_rect.end.y - 26.0, 20.0, 26.0)
			nav.scroll_track_rect = Rect2(sb_x, clip_rect.position.y + 30.0, 20.0, maxf(24.0, clip_rect.size.y - 60.0))
			row_step_px = clip_rect.size.y / 5.35
		else:
			clip_rect = Rect2(12.0, 52.0, sz.x - 24.0, sz.y - 52.0 - 74.0)
			nav.scroll_up_rect = Rect2()
			nav.scroll_down_rect = Rect2()
			nav.scroll_track_rect = Rect2()
			row_step_px = clip_rect.size.y / 4.45

		if nav.graph_clip != null:
			nav.graph_clip.position = clip_rect.position
			nav.graph_clip.size = clip_rect.size
			nav.graph_clip.custom_minimum_size = clip_rect.size
		if nav.graph_canvas != null:
			nav.graph_canvas.position = Vector2.ZERO
			nav.graph_canvas.size = clip_rect.size

		var nodes: Array[Dictionary] = nav.engine.run_map_nodes
		if nodes.is_empty():
			return

		var margin_x: float = 64.0 if nav.is_zoomed else 58.0
		var half_span_x: float = maxf(48.0, clip_rect.size.x * 0.5 - margin_x)
		var center_x: float = clip_rect.size.x * 0.5 + 10.0
		var center_y: float = clip_rect.size.y * 0.5 + 12.0
		var fork_ids: Array[String] = nav.engine.active_fork_node_ids()

		for nd: Dictionary in nodes:
			var nid: String = str(nd.get("id", ""))
			var stg: float = float(int(nd.get("stage_index", 0))) + float(nd.get("y_jitter", 0.0))
			var lane_n: float = float(nd.get("lane_norm", 0.0))
			var lx: float = center_x + lane_n * half_span_x
			var ly: float = center_y - (stg - nav.scroll_stage_center) * row_step_px
			var lpt: Vector2 = Vector2(lx, ly)
			local_pos_by_id[nid] = lpt
			if ly >= 8.0 and ly <= clip_rect.size.y - 8.0:
				nav.node_hotspots.append({
					"id": nid,
					"pos": clip_rect.position + lpt,
					"fork_index": fork_ids.find(nid)
				})

	func stage_to_local_y(stage_idx: int) -> float:
		var center_y: float = clip_rect.size.y * 0.5 + 12.0
		return center_y - (float(stage_idx) - nav.scroll_stage_center) * row_step_px

	func _draw() -> void:
		if nav == null or nav.repo == null or nav.engine == null:
			return
		if local_pos_by_id.is_empty():
			rebuild_layout_and_hotspots()

		var rep: GameRepository = nav.repo
		var eng: CombatEngine = nav.engine
		var sz: Vector2 = nav.vp_size
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")
		var brd_col: Color = rep.get_palette_color("mfd_border")

		DiegeticScreenFactory.draw_industrial_plate(
			self,
			Rect2(2.0, 2.0, sz.x - 4.0, sz.y - 4.0),
			rep,
			brd_col,
			10.0,
			2.6,
			true,
			46.0,
			false
		)

		DiegeticScreenFactory.draw_chamfer_rect(
			self,
			Rect2(clip_rect.position.x - 2.0, clip_rect.position.y - 2.0, clip_rect.size.x + 4.0, clip_rect.size.y + 4.0),
			6.0,
			Color(0.02, 0.026, 0.032, 0.86),
			Color(brd_col.r, brd_col.g, brd_col.b, 0.45),
			1.6
		)

		var hdr_txt: String = rep.get_ui_text("navigator", "header_title")
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(18.0, 34.0),
			hdr_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 196.0,
			22,
			txt_col,
			out_col,
			3,
			14
		)

		var z_lbl: String = rep.get_ui_text("navigator", "zoom_close_badge" if nav.is_zoomed else "zoom_badge")
		var z_col: Color = rep.get_palette_color("selected_glow" if (nav.hovered_zoom_btn or nav.is_zoomed) else "mfd_border")
		DiegeticScreenFactory.draw_chamfer_rect(
			self,
			nav.zoom_btn_rect,
			6.0,
			Color(z_col.r * 0.20, z_col.g * 0.16, z_col.b * 0.08, 0.96),
			z_col,
			2.0
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(nav.zoom_btn_rect.position.x + 6.0, nav.zoom_btn_rect.position.y + 25.0),
			z_lbl,
			HORIZONTAL_ALIGNMENT_CENTER,
			nav.zoom_btn_rect.size.x - 12.0,
			18,
			txt_col if nav.hovered_zoom_btn else z_col.lightened(0.2),
			out_col,
			3,
			12
		)

		if nav.is_zoomed:
			_draw_legend_strip(f_disp, out_col, txt_col, panel_bg, rep)
			_draw_scrollbar(f_disp, out_col, txt_col, panel_bg, brd_col, rep)
			_draw_zoomed_footer_intel(f_disp, f_body, out_col, txt_col, panel_bg, sz, clip_rect.end.y + 8.0, rep, eng)
		else:
			_draw_docked_footer_bar(f_disp, out_col, txt_col, panel_bg, sz, clip_rect.end.y + 8.0, rep, eng)

	func _draw_legend_strip(f_disp: Font, out_col: Color, txt_col: Color, panel_bg: Color, rep: GameRepository) -> void:
		var act_filter: String = nav.active_legend_filter()
		for lg: Dictionary in nav.legend_rects:
			var kind: String = str(lg.get("kind", ""))
			var lbl: String = str(lg.get("label", ""))
			var r: Rect2 = lg.get("rect", Rect2()) as Rect2
			var col: Color = rep.get_palette_color("node_" + kind)
			var is_hi: bool = (act_filter == kind)
			var is_pinned: bool = (nav.pinned_legend_kind == kind)
			var bg: Color = Color(col.r * 0.28, col.g * 0.22, col.b * 0.12, 0.96) if is_hi else Color(panel_bg.r, panel_bg.g, panel_bg.b, 0.92)
			var brd: Color = txt_col if is_pinned else (col.lightened(0.22) if is_hi else col * 0.68)
			DiegeticScreenFactory.draw_chamfer_rect(self, r, 5.0, bg, brd, 2.2 if (is_hi or is_pinned) else 1.4)
			var ic: Vector2 = Vector2(r.position.x + 15.0, r.position.y + r.size.y * 0.5)
			var fake_nd: Dictionary = {
				"type": "combat" if kind == "elite" else kind,
				"is_elite": kind == "elite",
				"is_boss": false
			}
			draw_map_node_icon(self, ic, 10.5, fake_nd, txt_col if is_hi else col.lightened(0.2), f_disp)
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(r.position.x + 28.0, r.position.y + 22.0),
				lbl,
				HORIZONTAL_ALIGNMENT_LEFT,
				r.size.x - 32.0,
				13,
				txt_col if is_hi else col.lightened(0.24),
				out_col,
				2,
				9
			)

	func _draw_scrollbar(f_disp: Font, out_col: Color, txt_col: Color, panel_bg: Color, brd_col: Color, rep: GameRepository) -> void:
		var sel_col: Color = rep.get_palette_color("selected_glow")
		var up_hi: bool = (nav.hovered_scroll_part == "up")
		var dn_hi: bool = (nav.hovered_scroll_part == "down")
		DiegeticScreenFactory.draw_chamfer_rect(self, nav.scroll_up_rect, 4.0, panel_bg, sel_col if up_hi else brd_col, 1.6)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(nav.scroll_up_rect.position.x, nav.scroll_up_rect.position.y + 18.0), "^", HORIZONTAL_ALIGNMENT_CENTER, nav.scroll_up_rect.size.x, 16, txt_col if up_hi else brd_col.lightened(0.25), out_col, 2, 11)

		DiegeticScreenFactory.draw_chamfer_rect(self, nav.scroll_down_rect, 4.0, panel_bg, sel_col if dn_hi else brd_col, 1.6)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(nav.scroll_down_rect.position.x, nav.scroll_down_rect.position.y + 18.0), "v", HORIZONTAL_ALIGNMENT_CENTER, nav.scroll_down_rect.size.x, 14, txt_col if dn_hi else brd_col.lightened(0.25), out_col, 2, 10)

		var tr: Rect2 = nav.scroll_track_rect
		DiegeticScreenFactory.draw_chamfer_rect(self, tr, 4.0, Color(0.02, 0.025, 0.03, 0.9), brd_col * 0.55, 1.3)
		var b: Vector2 = nav.scroll_bounds(true)
		var span: float = maxf(0.01, b.y - b.x)
		var norm_top: float = clampf((b.y - nav.scroll_stage_center) / span, 0.0, 1.0)
		var thumb_h: float = clampf(tr.size.y * 0.34, 28.0, tr.size.y)
		var thumb_y: float = tr.position.y + norm_top * (tr.size.y - thumb_h)
		var thumb_r: Rect2 = Rect2(tr.position.x + 2.0, thumb_y, tr.size.x - 4.0, thumb_h)
		var tr_hi: bool = (nav.hovered_scroll_part == "track")
		DiegeticScreenFactory.draw_chamfer_rect(self, thumb_r, 3.0, sel_col * (0.85 if tr_hi else 0.55), sel_col, 1.6)

	func _draw_docked_footer_bar(f_disp: Font, out_col: Color, txt_col: Color, panel_bg: Color, sz: Vector2, footer_top: float, rep: GameRepository, eng: CombatEngine) -> void:
		var box_r: Rect2 = Rect2(10.0, footer_top, sz.x - 20.0, sz.y - footer_top - 10.0)
		var is_fork: bool = (eng.mode == CombatEngine.MODE_ROUTE_CHOICE)
		var brd: Color = rep.get_palette_color("fork_left_glow" if is_fork else "mfd_border")
		DiegeticScreenFactory.draw_chamfer_rect(self, box_r, 8.0, panel_bg, brd, 2.2)
		var total_sectors: int = nav.max_map_stage() + 1
		var msg: String = rep.get_ui_text("navigator", "docked_fork_hint") if is_fork else (rep.get_ui_text("navigator", "docked_stage_fmt") % [eng.stage_index + 1, total_sectors])
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(box_r.position.x + 12.0, box_r.position.y + 39.0),
			msg,
			HORIZONTAL_ALIGNMENT_CENTER,
			box_r.size.x - 24.0,
			24,
			txt_col if is_fork else rep.get_palette_color("mfd_accent"),
			out_col,
			3,
			14
		)

	func _draw_zoomed_footer_intel(f_disp: Font, f_body: Font, out_col: Color, txt_col: Color, panel_bg: Color, sz: Vector2, footer_top: float, rep: GameRepository, eng: CombatEngine) -> void:
		var box_r: Rect2 = Rect2(10.0, footer_top, sz.x - 20.0, sz.y - footer_top - 10.0)
		var brd: Color = rep.get_palette_color("mfd_border")
		DiegeticScreenFactory.draw_chamfer_rect(self, box_r, 8.0, panel_bg, brd, 2.0)

		var target_id: String = nav.hovered_node_id
		if target_id.is_empty() and nav.external_hovered_fork_idx >= 0:
			var f_ids: Array[String] = eng.active_fork_node_ids()
			if nav.external_hovered_fork_idx < f_ids.size():
				target_id = f_ids[nav.external_hovered_fork_idx]
		if target_id.is_empty() and not nav.inspected_node_id.is_empty():
			target_id = nav.inspected_node_id
		if target_id.is_empty():
			target_id = eng.current_map_node_id

		var nd: Dictionary = RunMapGenerator.find_node(eng.run_map_nodes, target_id)
		if nd.is_empty():
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(20.0, footer_top + 60.0), rep.get_ui_text("navigator", "header_title"), HORIZONTAL_ALIGNMENT_CENTER, box_r.size.x - 24.0, 20, txt_col, out_col, 3, 14)
			return

		var is_vis_or_cur: bool = eng.visited_map_node_ids.has(target_id) or (target_id == eng.current_map_node_id)
		var status_str: String = nav.describe_node_status(target_id)
		var via_str: String = nav.describe_route_via_fork(target_id)
		if not via_str.is_empty():
			status_str += " • " + via_str
		var title_str: String = RunMapGenerator.display_title_for_node(rep, nd, is_vis_or_cur).to_upper()
		var bonus_str: String = nav.format_node_bonus(nd)
		var node_col: Color = rep.get_palette_color(RunMapGenerator.node_palette_key(nd))

		var next_tags: Array[String] = []
		for nxt_v: Variant in (nd.get("next_ids", []) as Array):
			var nxt_nd: Dictionary = RunMapGenerator.find_node(eng.run_map_nodes, str(nxt_v))
			if not nxt_nd.is_empty():
				var tg: String = RunMapGenerator.short_node_tag(nxt_nd)
				if not next_tags.has(tg):
					next_tags.append(tg)
		if not next_tags.is_empty():
			bonus_str += "  •  " + rep.get_ui_text("fork", "next_prefix") + " " + " / ".join(next_tags)

		var detail_str: String = ""
		var ntype: String = str(nd.get("type", "combat"))
		if ntype == "event" and not is_vis_or_cur:
			detail_str = rep.get_ui_text("navigator", "unknown_event_desc")
		elif ntype == "rest":
			detail_str = str(rep.rest_site().get("subtitle", ""))
		elif ntype == "upgrade":
			detail_str = str(rep.upgrade_site().get("subtitle", ""))
		else:
			var enemies_arr: Array = (nd.get("encounter", {}) as Dictionary).get("enemies", []) as Array
			if not enemies_arr.is_empty():
				var names: Array[String] = []
				for sp: Variant in enemies_arr:
					if typeof(sp) == TYPE_DICTIONARY:
						var eid: String = str((sp as Dictionary).get("enemy_id", ""))
						var etmpl: Dictionary = rep.get_enemy(eid)
						names.append(str(etmpl.get("name", eid)))
				detail_str = rep.get_ui_text("fork", "threats_prefix") + ", ".join(names)

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(20.0, footer_top + 28.0),
			"[%s] %s" % [status_str, title_str],
			HORIZONTAL_ALIGNMENT_LEFT,
			box_r.size.x - 28.0,
			19,
			rep.get_palette_color("mfd_accent"),
			out_col,
			3,
			12
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(20.0, footer_top + 56.0),
			bonus_str,
			HORIZONTAL_ALIGNMENT_LEFT,
			box_r.size.x - 28.0,
			18,
			node_col.lightened(0.24),
			out_col,
			2,
			11
		)
		if not detail_str.is_empty():
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_body,
				Vector2(20.0, footer_top + 83.0),
				detail_str,
				HORIZONTAL_ALIGNMENT_LEFT,
				box_r.size.x - 28.0,
				16,
				txt_col,
				out_col,
				2,
				11
			)


class _NavigatorGraphCanvas extends Control:
	var nav: Navigator3DController

	func _draw() -> void:
		if nav == null or nav.repo == null or nav.engine == null or nav.nav_canvas == null:
			return
		var rep: GameRepository = nav.repo
		var eng: CombatEngine = nav.engine
		var host: _NavigatorCanvas = nav.nav_canvas
		var pos_map: Dictionary = host.local_pos_by_id
		var sz: Vector2 = size
		if sz.x <= 8.0 or sz.y <= 8.0:
			return

		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")
		var brd_col: Color = rep.get_palette_color("mfd_border")
		var muted_col: Color = rep.get_palette_color("mfd_muted")
		var ncfg: Dictionary = rep.cockpit.get("navigator_3d", {}) as Dictionary

		var grid_col: Color = Color(brd_col.r, brd_col.g, brd_col.b, 0.08)
		var gx: float = 48.0
		while gx < sz.x - 10.0:
			draw_line(Vector2(gx, 0.0), Vector2(gx, sz.y), grid_col, 1.0)
			gx += 48.0

		var sweep_spd: float = float(ncfg.get("radar_sweep_speed", 0.42))
		var sweep_t: float = fposmod(nav.time_accum * sweep_spd, 1.0)
		var sweep_y: float = lerpf(sz.y, 0.0, sweep_t)
		draw_line(Vector2(0.0, sweep_y), Vector2(sz.x, sweep_y), Color(brd_col.r, brd_col.g, brd_col.b, 0.22), 2.0)

		var nodes: Array[Dictionary] = eng.run_map_nodes
		if nodes.is_empty():
			return

		var max_stage: int = nav.max_map_stage()
		var cur_row_idx: int = nav.current_node_stage()
		for s_i: int in range(max_stage + 1):
			var sy: float = host.stage_to_local_y(s_i)
			if sy < -24.0 or sy > sz.y + 24.0:
				continue
			var is_cur_row: bool = (s_i == cur_row_idx)
			var band_col: Color = Color(brd_col.r, brd_col.g, brd_col.b, 0.22 if is_cur_row else 0.07)
			draw_line(Vector2(44.0, sy), Vector2(sz.x - 8.0, sy), band_col, 1.6 if is_cur_row else 1.0)
			var s_lbl: String = "BOSS" if s_i == max_stage else ("S%d" % (s_i + 1))
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(6.0, sy + 5.0),
				s_lbl,
				HORIZONTAL_ALIGNMENT_LEFT,
				36.0,
				13,
				rep.get_palette_color("selected_glow") if is_cur_row else muted_col * 0.80,
				out_col,
				2,
				9
			)

		var reachable: Array[String] = RunMapGenerator.compute_reachable_ids(nodes, eng.current_map_node_id)
		var fork_ids: Array[String] = eng.active_fork_node_ids()
		var fork_active: bool = (eng.mode == CombatEngine.MODE_ROUTE_CHOICE or eng.mode == CombatEngine.MODE_ROUTE_TRANSITION)
		var pulse: float = 0.65 + 0.35 * sin(nav.time_accum * 6.0)

		var preview_target_id: String = nav.hovered_node_id
		if preview_target_id.is_empty() and nav.external_hovered_fork_idx >= 0 and nav.external_hovered_fork_idx < fork_ids.size():
			preview_target_id = fork_ids[nav.external_hovered_fork_idx]
		if preview_target_id.is_empty() and not nav.inspected_node_id.is_empty():
			preview_target_id = nav.inspected_node_id

		var route_ancestors: Array[String] = []
		var route_descendants: Array[String] = []
		if not preview_target_id.is_empty() and reachable.has(preview_target_id):
			route_ancestors = RunMapGenerator.compute_ancestor_ids(nodes, preview_target_id)
			route_descendants = RunMapGenerator.compute_reachable_ids(nodes, preview_target_id)

		var col_visited: Color = rep.get_palette_color("nav_visited")
		var col_cur: Color = rep.get_palette_color("nav_current")
		var col_reach: Color = rep.get_palette_color("nav_reachable")
		var col_lock: Color = rep.get_palette_color("nav_locked")
		var col_route_hi: Color = rep.get_palette_color("selected_glow").lightened(0.22)
		var act_filter: String = nav.active_legend_filter()

		for nd: Dictionary in nodes:
			var uid: String = str(nd.get("id", ""))
			if not pos_map.has(uid):
				continue
			var p0: Vector2 = pos_map[uid] as Vector2
			for nxt_val: Variant in (nd.get("next_ids", []) as Array):
				var vid: String = str(nxt_val)
				if not pos_map.has(vid):
					continue
				var p1: Vector2 = pos_map[vid] as Vector2
				if minf(p0.y, p1.y) > sz.y + 40.0 or maxf(p0.y, p1.y) < -40.0:
					continue

				var curve_pts: PackedVector2Array = _sample_s_curve(p0, p1, 14)
				var both_visited: bool = eng.visited_map_node_ids.has(uid) and eng.visited_map_node_ids.has(vid)
				var is_fork_edge: bool = fork_active and uid == eng.current_map_node_id and fork_ids.has(vid)
				var is_reach_edge: bool = reachable.has(uid) and reachable.has(vid)
				var is_preview_path: bool = is_reach_edge and (
					(route_ancestors.has(uid) and route_ancestors.has(vid))
					or (uid == preview_target_id and route_descendants.has(vid))
				)

				if both_visited:
					draw_polyline(curve_pts, Color(0.02, 0.03, 0.04, 0.88), 7.2, true)
					draw_polyline(curve_pts, col_visited.lightened(0.16), 3.8, true)
				elif is_fork_edge:
					var f_idx: int = fork_ids.find(vid)
					var dst_nd: Dictionary = RunMapGenerator.find_node(nodes, vid)
					var f_col: Color = rep.get_palette_color(RunMapGenerator.node_palette_key(dst_nd))
					var is_hi: bool = (nav.hovered_node_id == vid) or (nav.external_hovered_fork_idx == f_idx) or is_preview_path
					var w_edge: float = 6.0 if is_hi else 4.4
					draw_polyline(curve_pts, Color(0.02, 0.03, 0.04, 0.92), w_edge + 2.8, true)
					draw_polyline(curve_pts, Color(f_col.r, f_col.g, f_col.b, 0.98 if is_hi else pulse), w_edge, true)
					_draw_curve_flow_chevrons(p0, p1, f_col.lightened(0.32), nav.time_accum)
				elif is_preview_path:
					draw_polyline(curve_pts, Color(0.02, 0.03, 0.04, 0.88), 6.2, true)
					draw_polyline(curve_pts, Color(col_route_hi.r, col_route_hi.g, col_route_hi.b, 0.94), 3.4, true)
				elif is_reach_edge:
					var r_alpha: float = 0.28 if (not act_filter.is_empty()) else 0.78
					_draw_dashed_curve(curve_pts, Color(col_reach.r, col_reach.g, col_reach.b, r_alpha), 2.5)
				else:
					draw_polyline(curve_pts, Color(col_lock.r, col_lock.g, col_lock.b, 0.20), 1.4, true)

		var base_r: float = float(ncfg.get("node_radius", 16.0)) * (1.16 if nav.is_zoomed else 1.08)
		for nd: Dictionary in nodes:
			var nid: String = str(nd.get("id", ""))
			if not pos_map.has(nid):
				continue
			var c: Vector2 = pos_map[nid] as Vector2
			if c.y < -38.0 or c.y > sz.y + 38.0:
				continue

			var kind: String = RunMapGenerator.semantic_node_kind(nd)
			var is_cur: bool = (nid == eng.current_map_node_id)
			var is_vis: bool = eng.visited_map_node_ids.has(nid)
			var f_idx: int = fork_ids.find(nid) if fork_active else -1
			var is_reach: bool = reachable.has(nid)
			var is_hov: bool = (nid == nav.hovered_node_id) or (f_idx >= 0 and nav.external_hovered_fork_idx == f_idx) or (nid == nav.inspected_node_id)
			var is_on_preview: bool = route_ancestors.has(nid) and is_reach
			var matches_filter: bool = act_filter.is_empty() or (kind == act_filter)

			var type_col: Color = rep.get_palette_color(RunMapGenerator.node_palette_key(nd))
			var ncol: Color = col_lock
			var fill_col: Color = panel_bg
			if is_cur:
				ncol = col_cur
				fill_col = panel_bg.lerp(col_cur, 0.24)
			elif f_idx >= 0:
				ncol = type_col.lightened(0.20)
				fill_col = panel_bg.lerp(type_col, 0.20)
			elif is_vis:
				ncol = col_visited * 0.86
				fill_col = panel_bg.lerp(col_visited, 0.14)
			elif is_reach:
				ncol = type_col
				fill_col = panel_bg.lerp(type_col, 0.12)
			else:
				ncol = type_col * 0.30
				ncol.a = 0.45
				fill_col = Color(panel_bg.r, panel_bg.g, panel_bg.b, 0.48)

			if not act_filter.is_empty() and not matches_filter and not is_cur:
				ncol = Color(ncol.r * 0.45, ncol.g * 0.45, ncol.b * 0.45, 0.32)
				fill_col = Color(fill_col.r, fill_col.g, fill_col.b, 0.35)

			var size_mul: float = 1.48 if kind == "boss" else (1.14 if kind == "elite" else 1.0)
			if is_hov:
				size_mul *= 1.18
			elif is_cur or f_idx >= 0 or (not act_filter.is_empty() and matches_filter and is_reach):
				size_mul *= 1.10
			var r: float = base_r * size_mul

			if is_cur or f_idx >= 0 or is_hov or is_on_preview or (not act_filter.is_empty() and matches_filter and is_reach):
				var halo_col: Color = col_route_hi if (is_on_preview and not is_cur and f_idx < 0) else ncol
				draw_arc(c, r + 5.0, 0.0, TAU, 28, Color(halo_col.r, halo_col.g, halo_col.b, 0.94 if is_hov else pulse * 0.82), 2.4, true)

			_draw_node_frame(c, r, kind, fill_col, ncol, 3.0 if (is_cur or f_idx >= 0 or is_hov) else 2.1)
			_NavigatorCanvas.draw_map_node_icon(self, c, r * 0.94, nd, txt_col if (is_cur or is_hov) else ncol.lightened(0.18), f_disp)

			if kind == "combat" and is_reach and not is_vis and (act_filter.is_empty() or matches_filter):
				var b_sc: int = int(nd.get("bonus_scrap", 0))
				var b_hl: int = int(nd.get("bonus_heal", 0))
				if b_sc > 0 or b_hl > 0:
					var pip_c: Vector2 = c + Vector2(r * 0.72, -r * 0.68)
					var pip_col: Color = rep.get_palette_color("selected_glow" if b_sc > 0 else "node_rest")
					draw_circle(pip_c, 6.2, panel_bg)
					draw_arc(pip_c, 6.2, 0.0, TAU, 12, pip_col, 1.7, true)
					var pip_sym: String = "$" if b_sc > 0 else "+"
					DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(pip_c.x - 6.0, pip_c.y + 4.5), pip_sym, HORIZONTAL_ALIGNMENT_CENTER, 12.0, 11, pip_col.lightened(0.3), out_col, 2, 9)

			if is_vis and not is_cur:
				var chk_c: Vector2 = c + Vector2(r * 0.70, -r * 0.70)
				draw_circle(chk_c, 6.5, panel_bg)
				draw_arc(chk_c, 6.5, 0.0, TAU, 14, col_visited.lightened(0.25), 1.8, true)
				draw_polyline(PackedVector2Array([
					chk_c + Vector2(-3.0, 0.2),
					chk_c + Vector2(-0.6, 2.8),
					chk_c + Vector2(3.4, -2.6)
				]), col_visited.lightened(0.35), 2.0, true)

			var show_tag: bool = (
				kind == "boss"
				or ((f_idx >= 0 or is_hov or is_cur or (not act_filter.is_empty() and matches_filter)) and (is_reach or is_cur or is_vis))
			)
			if show_tag:
				var tag_str: String = _NavigatorCanvas._short_node_tag(nd)
				if kind == "boss" and nav.is_zoomed:
					tag_str = str(nd.get("title", "CORE BOSS")).to_upper()
				var tag_w: float = 240.0 if (kind == "boss" and nav.is_zoomed) else 84.0
				DiegeticScreenFactory.draw_fitted_text(
					self,
					f_body,
					Vector2(c.x - tag_w * 0.5, c.y + r + 15.0),
					tag_str,
					HORIZONTAL_ALIGNMENT_CENTER,
					tag_w,
					13,
					txt_col if (is_hov or f_idx >= 0 or kind == "boss") else ncol.lightened(0.28),
					out_col,
					2,
					9
				)

			if f_idx >= 0 and eng.mode == CombatEngine.MODE_ROUTE_CHOICE:
				var key_rect: Rect2 = Rect2(c.x + (-(r + 32.0) if f_idx == 0 else (r + 8.0)), c.y - 13.0, 26.0, 26.0)
				DiegeticScreenFactory.draw_chamfer_rect(self, key_rect, 4.0, panel_bg, ncol, 2.2)
				DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(key_rect.position.x, key_rect.position.y + 18.0), str(f_idx + 1), HORIZONTAL_ALIGNMENT_CENTER, key_rect.size.x, 16, txt_col, out_col, 2, 11)

		if pos_map.has(eng.current_map_node_id):
			var car_pt: Vector2 = pos_map[eng.current_map_node_id] as Vector2
			if eng.mode == CombatEngine.MODE_ROUTE_TRANSITION and pos_map.has(eng.pending_route_node_id):
				var dst_pt: Vector2 = pos_map[eng.pending_route_node_id] as Vector2
				car_pt = _eval_s_curve(car_pt, dst_pt, nav.transition_progress)
			if car_pt.y >= -24.0 and car_pt.y <= sz.y + 24.0:
				_draw_vehicle_chevron(car_pt + Vector2(0.0, -base_r - 12.0), col_cur, txt_col)

	func _draw_node_frame(c: Vector2, r: float, kind: String, fill_col: Color, brd_col: Color, bw: float) -> void:
		if kind == "boss":
			var oct: PackedVector2Array = PackedVector2Array()
			for k: int in range(8):
				var a: float = deg_to_rad(45.0 * float(k) + 22.5)
				oct.append(c + Vector2(cos(a), sin(a)) * r)
			draw_colored_polygon(oct, fill_col)
			oct.append(oct[0])
			draw_polyline(oct, brd_col, bw + 0.6, true)
			draw_arc(c, r * 0.80, 0.0, TAU, 24, Color(brd_col.r, brd_col.g, brd_col.b, 0.55), 1.6, true)
			return
		if kind == "elite":
			var sh: PackedVector2Array = PackedVector2Array([
				c + Vector2(0.0, -r * 1.08),
				c + Vector2(r * 0.96, -r * 0.32),
				c + Vector2(r * 0.72, r * 0.76),
				c + Vector2(0.0, r * 1.06),
				c + Vector2(-r * 0.72, r * 0.76),
				c + Vector2(-r * 0.96, -r * 0.32)
			])
			draw_colored_polygon(sh, fill_col)
			sh.append(sh[0])
			draw_polyline(sh, brd_col, bw, true)
			return
		if kind == "workshop" or kind == "rest" or kind == "upgrade":
			var hex: PackedVector2Array = PackedVector2Array()
			for k: int in range(6):
				var a: float = deg_to_rad(60.0 * float(k) - 30.0)
				hex.append(c + Vector2(cos(a), sin(a)) * (r * 1.04))
			draw_colored_polygon(hex, fill_col)
			hex.append(hex[0])
			draw_polyline(hex, brd_col, bw, true)
			return
		draw_circle(c, r, fill_col)
		draw_arc(c, r, 0.0, TAU, 24, brd_col, bw, true)

	static func _eval_s_curve(p0: Vector2, p1: Vector2, t: float) -> Vector2:
		var dy: float = p1.y - p0.y
		var cp0: Vector2 = p0 + Vector2(0.0, dy * 0.45)
		var cp1: Vector2 = p1 - Vector2(0.0, dy * 0.45)
		var omt: float = 1.0 - t
		return (omt * omt * omt) * p0 + (3.0 * omt * omt * t) * cp0 + (3.0 * omt * t * t) * cp1 + (t * t * t) * p1

	static func _sample_s_curve(p0: Vector2, p1: Vector2, steps: int) -> PackedVector2Array:
		var pts: PackedVector2Array = PackedVector2Array()
		for i: int in range(steps + 1):
			pts.append(_eval_s_curve(p0, p1, float(i) / float(steps)))
		return pts

	func _draw_dashed_curve(pts: PackedVector2Array, col: Color, width: float) -> void:
		for i: int in range(0, pts.size() - 1, 2):
			draw_line(pts[i], pts[i + 1], col, width, true)

	func _draw_curve_flow_chevrons(p0: Vector2, p1: Vector2, col: Color, t_acc: float) -> void:
		var phase: float = fposmod(t_acc * 0.95, 1.0)
		for k: int in range(2):
			var u: float = fposmod(phase + float(k) * 0.5, 1.0)
			if u < 0.16 or u > 0.84:
				continue
			var pos: Vector2 = _eval_s_curve(p0, p1, u)
			var ahead: Vector2 = _eval_s_curve(p0, p1, minf(1.0, u + 0.05))
			var dir: Vector2 = (ahead - pos).normalized()
			if dir.length_squared() < 0.1:
				continue
			var perp: Vector2 = Vector2(-dir.y, dir.x)
			draw_polyline(PackedVector2Array([
				pos - dir * 5.0 + perp * 4.8,
				pos + dir * 2.5,
				pos - dir * 5.0 - perp * 4.8
			]), Color(col.r, col.g, col.b, 0.90), 2.2, true)

	func _draw_vehicle_chevron(c: Vector2, col: Color, rim_col: Color) -> void:
		var pts: PackedVector2Array = PackedVector2Array([
			c + Vector2(0.0, -10.0),
			c + Vector2(9.5, 7.5),
			c + Vector2(0.0, 3.0),
			c + Vector2(-9.5, 7.5)
		])
		draw_colored_polygon(pts, col)
		pts.append(pts[0])
		draw_polyline(pts, rim_col, 1.7, true)
