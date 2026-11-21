class_name RoadFork3DController
extends Node3D

signal lane_hovered_changed(lane_index: int)
signal steering_feedback_updated(wheel_deg: float, camera_yaw_deg: float, chassis_roll_deg: float, chassis_squat_y: float, compass_deg: float, progress: float)

const STATE_HIDDEN: int = 0
const STATE_APPROACHING: int = 1
const STATE_WAITING_CHOICE: int = 2
const STATE_DRIVING_BRANCH: int = 3

var repo: GameRepository
var engine: CombatEngine

var fork_holder: Node3D
var fork_model: Node3D
var sign_canvases: Array[_ForkGantrySignCanvas] = []
var lane_areas: Array[Area3D] = []
var left_beacon_mats: Array[StandardMaterial3D] = []
var right_beacon_mats: Array[StandardMaterial3D] = []
var trajectory_holder: Node3D
var trajectory_dashes_left: Array[MeshInstance3D] = []
var trajectory_dashes_right: Array[MeshInstance3D] = []
var trajectory_mats_left: Array[StandardMaterial3D] = []
var trajectory_mats_right: Array[StandardMaterial3D] = []

var fork_state: int = STATE_HIDDEN
var state_timer: float = 0.0
var current_approach_z: float = 0.0
var drive_start_z: float = 0.0
var hovered_lane_index: int = -1
var chosen_lane_index: int = -1
var time_accum: float = 0.0

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	if repository == null or combat_engine == null:
		push_error("RoadFork3DController.initialize received null dependencies")
		return
	repo = repository
	engine = combat_engine

	fork_holder = Node3D.new()
	fork_holder.name = "ForkHolder"
	add_child(fork_holder)

	_build_fork_geometry()
	_build_trajectory_indicators()
	_build_gantry_signs_and_colliders()

	engine.route_choices_offered.connect(_on_route_choices_offered)
	engine.route_transition_started.connect(_on_route_transition_started)
	engine.state_changed.connect(_on_engine_state_changed)

	_set_fork_hidden()

func is_fork_visible() -> bool:
	return fork_state != STATE_HIDDEN

func should_suppress_straight_tunnel() -> bool:
	if fork_state == STATE_HIDDEN:
		return false
	if fork_state == STATE_APPROACHING:
		var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
		var dur: float = maxf(0.1, float(fcfg.get("approach_duration_s", 0.88)))
		var thresh: float = float(fcfg.get("tunnel_hide_progress_threshold", 0.02))
		return (state_timer / dur) >= thresh
	return true

func set_hovered_lane(lane_idx: int) -> void:
	var sanitized: int = lane_idx if (lane_idx == 0 or lane_idx == 1) else -1
	if fork_state != STATE_APPROACHING and fork_state != STATE_WAITING_CHOICE:
		sanitized = -1
	if hovered_lane_index == sanitized:
		return
	hovered_lane_index = sanitized
	lane_hovered_changed.emit(hovered_lane_index)
	_refresh_gantry_signs()

func describe_lane_hover(lane_idx: int) -> String:
	if repo == null or engine == null:
		return ""
	if lane_idx < 0 or lane_idx >= engine.route_options.size():
		return ""
	var opt: Dictionary = engine.route_options[lane_idx]
	var dir_lbl: String = repo.get_ui_text("fork", "left_dir" if lane_idx == 0 else "right_dir")
	var title_lbl: String = str(opt.get("title", ""))
	var bonus_lbl: String = format_option_bonus(opt)
	var next_lbl: String = format_option_next_nodes(opt)
	if not next_lbl.is_empty():
		bonus_lbl += " • " + repo.get_ui_text("fork", "next_prefix") + " " + next_lbl
	var hostiles_lbl: String = format_option_hostiles(opt)
	return repo.get_ui_text("fork", "hover_lane") % [
		dir_lbl,
		lane_idx + 1,
		title_lbl,
		hostiles_lbl,
		bonus_lbl
	]

func trigger_lane_choice(lane_idx: int) -> bool:
	if engine == null or engine.mode != CombatEngine.MODE_ROUTE_CHOICE:
		return false
	if lane_idx < 0 or lane_idx >= engine.route_options.size():
		return false
	return engine.begin_route_transition(lane_idx)

func get_lane_accent_color(lane_idx: int) -> Color:
	if repo == null or engine == null:
		return Color.WHITE
	var opts: Array[Dictionary] = engine.route_options
	if lane_idx >= 0 and lane_idx < opts.size():
		return repo.get_palette_color(RunMapGenerator.node_palette_key(opts[lane_idx]))
	if not engine.pending_route_option.is_empty() and chosen_lane_index == lane_idx:
		return repo.get_palette_color(RunMapGenerator.node_palette_key(engine.pending_route_option))
	return repo.get_palette_color("fork_left_glow" if lane_idx == 0 else "fork_right_glow")

func format_option_bonus(opt: Dictionary) -> String:
	var ntype: String = str(opt.get("type", "combat"))
	if ntype == "workshop":
		return repo.get_ui_text("fork", "bonus_workshop")
	if ntype == "rest":
		return repo.get_ui_text("fork", "bonus_rest")
	if ntype == "upgrade":
		return repo.get_ui_text("fork", "bonus_upgrade")
	if ntype == "event":
		return repo.get_ui_text("fork", "bonus_event")
	if bool(opt.get("is_elite", false)):
		return repo.get_ui_text("fork", "bonus_elite")
	var b_scrap: int = int(opt.get("bonus_scrap", 0))
	var b_heal: int = int(opt.get("bonus_heal", 0))
	var parts: Array[String] = []
	if b_scrap > 0:
		parts.append(repo.get_ui_text("fork", "bonus_scrap_fmt") % b_scrap)
	if b_heal > 0:
		parts.append(repo.get_ui_text("fork", "bonus_heal_fmt") % b_heal)
	if parts.is_empty():
		return repo.get_ui_text("fork", "bonus_standard")
	return " • ".join(parts)

func format_option_next_nodes(opt: Dictionary) -> String:
	if engine == null:
		return ""
	var nid: String = str(opt.get("map_node_id", ""))
	if nid.is_empty():
		return ""
	var nd: Dictionary = RunMapGenerator.find_node(engine.run_map_nodes, nid)
	var tags: Array[String] = []
	for nxt_v: Variant in (nd.get("next_ids", []) as Array):
		var nxt_nd: Dictionary = RunMapGenerator.find_node(engine.run_map_nodes, str(nxt_v))
		if not nxt_nd.is_empty():
			var tg: String = RunMapGenerator.short_node_tag(nxt_nd)
			if not tags.has(tg):
				tags.append(tg)
	return " / ".join(tags)

func format_option_hostiles(opt: Dictionary) -> String:
	var ntype: String = str(opt.get("type", "combat"))
	if ntype == "workshop":
		return repo.get_ui_text("navigator", "tag_workshop")
	if ntype == "rest":
		return repo.get_ui_text("navigator", "tag_rest")
	if ntype == "upgrade":
		return repo.get_ui_text("navigator", "tag_upgrade")
	if ntype == "event":
		return repo.get_ui_text("navigator", "tag_event")
	var spawns: Array = opt.get("enemies", []) as Array
	var names: Array[String] = []
	for sp_val: Variant in spawns:
		if typeof(sp_val) != TYPE_DICTIONARY:
			continue
		var eid: String = str((sp_val as Dictionary).get("enemy_id", ""))
		var tmpl: Dictionary = repo.get_enemy(eid)
		names.append(str(tmpl.get("name", eid)))
	if names.is_empty():
		return repo.get_ui_text("navigator", "tag_combat")
	return ", ".join(names)

func _build_fork_geometry() -> void:
	var fork_scene: PackedScene = repo.load_model_scene("dungeon_fork")
	if fork_scene != null:
		fork_model = fork_scene.instantiate() as Node3D
		fork_holder.add_child(fork_model)
		_bind_beacon_materials(fork_model)

	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var seg_scene: PackedScene = repo.load_model_scene("dungeon_segment")
	if seg_scene == null:
		return

	var ext_count: int = maxi(0, int(fcfg.get("extension_segment_count", 2)))
	var ext_start: float = float(fcfg.get("extension_start_dist", 31.8))
	var seg_len: float = maxf(2.0, float(dcfg.get("segment_length", 6.0)))
	var ang_deg: float = float(fcfg.get("branch_angle_deg", 27.0))
	var ang_rad: float = deg_to_rad(ang_deg)
	var p2: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("bezier_p2", []), Vector3(1.65, 0.0, -8.5))

	if fork_model != null:
		for cap_name: String in ["LeftAbyssCap", "RightAbyssCap"]:
			var cap_node: Node = fork_model.find_child(cap_name, true, false)
			if cap_node != null and ext_count > 0:
				cap_node.queue_free()

	for side_i: int in range(2):
		var side_sign: float = -1.0 if side_i == 0 else 1.0
		var branch_yaw_deg: float = -side_sign * ang_deg
		var dir_vec: Vector3 = Vector3(side_sign * sin(ang_rad), 0.0, -cos(ang_rad))
		var origin_vec: Vector3 = Vector3(side_sign * p2.x, 0.0, p2.z)
		for k: int in range(ext_count):
			var dist: float = ext_start + float(k) * seg_len
			var seg_inst: Node3D = seg_scene.instantiate() as Node3D
			seg_inst.position = origin_vec + dir_vec * dist
			seg_inst.rotation_degrees = Vector3(0.0, branch_yaw_deg, 0.0)
			fork_holder.add_child(seg_inst)

func _bind_beacon_materials(root_model: Node3D) -> void:
	left_beacon_mats.clear()
	right_beacon_mats.clear()
	var left_col: Color = repo.get_palette_color("fork_left_glow")
	var right_col: Color = repo.get_palette_color("fork_right_glow")

	for child: Node in root_model.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = child as MeshInstance3D
		if mi == null:
			continue
		var nm: String = mi.name
		if nm.begins_with("LeftBeacon") or nm.begins_with("LeftBranchLamp"):
			var lmat: StandardMaterial3D = StandardMaterial3D.new()
			lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			lmat.albedo_color = left_col
			mi.material_override = lmat
			left_beacon_mats.append(lmat)
		elif nm.begins_with("RightBeacon") or nm.begins_with("RightBranchLamp"):
			var rmat: StandardMaterial3D = StandardMaterial3D.new()
			rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			rmat.albedo_color = right_col
			mi.material_override = rmat
			right_beacon_mats.append(rmat)

func _build_trajectory_indicators() -> void:
	trajectory_dashes_left.clear()
	trajectory_dashes_right.clear()
	trajectory_mats_left.clear()
	trajectory_mats_right.clear()
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	if not bool(fcfg.get("trajectory_enabled", true)):
		return

	trajectory_holder = Node3D.new()
	trajectory_holder.name = "HoloTrajectories"
	fork_holder.add_child(trajectory_holder)

	var count: int = maxi(4, int(fcfg.get("trajectory_dash_count", 16)))
	var dash_w: float = float(fcfg.get("trajectory_dash_width_m", 0.34))
	var dash_l: float = float(fcfg.get("trajectory_dash_length_m", 0.62))
	var y_off: float = float(fcfg.get("trajectory_y_offset", 0.035))
	var p2_cfg: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("bezier_p2", []), Vector3(1.65, 0.0, -8.5))
	var p3_cfg: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("bezier_p3", []), Vector3(6.2, 0.0, -17.43))
	var p0: Vector3 = Vector3.ZERO
	var p1: Vector3 = Vector3(0.0, 0.0, float(fcfg.get("bezier_p1_z", -5.2)))

	for side_i: int in range(2):
		var side_sign: float = -1.0 if side_i == 0 else 1.0
		var p2: Vector3 = Vector3(side_sign * p2_cfg.x, 0.0, p2_cfg.z)
		var p3: Vector3 = Vector3(side_sign * p3_cfg.x, 0.0, p3_cfg.z)
		var base_col: Color = get_lane_accent_color(side_i)

		for k: int in range(count):
			var t: float = float(k + 0.5) / float(count)
			var pos: Vector3 = _cubic_bezier(p0, p1, p2, p3, t) + Vector3(0.0, y_off, 0.0)
			var tang: Vector3 = _cubic_bezier_tangent(p0, p1, p2, p3, t)
			var yaw_rad: float = atan2(-tang.x, -tang.z)

			var mi: MeshInstance3D = MeshInstance3D.new()
			var qm: QuadMesh = QuadMesh.new()
			qm.size = Vector2(dash_w, dash_l)
			qm.orientation = PlaneMesh.FACE_Y
			mi.mesh = qm
			mi.position = pos
			mi.rotation = Vector3(0.0, yaw_rad, 0.0)

			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(base_col.r, base_col.g, base_col.b, 0.0)
			mi.material_override = mat
			mi.visible = false
			trajectory_holder.add_child(mi)

			if side_i == 0:
				trajectory_dashes_left.append(mi)
				trajectory_mats_left.append(mat)
			else:
				trajectory_dashes_right.append(mi)
				trajectory_mats_right.append(mat)

func _build_gantry_signs_and_colliders() -> void:
	sign_canvases.clear()
	lane_areas.clear()
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	var col_layer: int = maxi(1, int(fcfg.get("collision_layer", 32)))
	var sign_sz: Vector2 = JsonConfigLoader.to_vec2(fcfg.get("sign_size_m", []), Vector2(2.14, 0.96))
	var sign_vp: Vector2 = JsonConfigLoader.to_vec2(fcfg.get("sign_viewport", []), Vector2(600.0, 270.0))
	var sign_depth: float = maxf(0.04, float(fcfg.get("sign_collider_depth", 0.22)))
	var lane_box_sz: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("lane_collider_size", []), Vector3(3.2, 2.7, 7.5))

	var b_pad: float = float(fcfg.get("sign_bezel_pad_m", 0.045))
	var b_depth: float = float(fcfg.get("sign_bezel_depth_m", 0.075))
	var beam_y: float = float(fcfg.get("gantry_beam_y", 2.42))
	var pillar_x: float = float(fcfg.get("gantry_pillar_x", 2.66))
	var gantry_z: float = float(fcfg.get("gantry_z", -4.44))
	var bezel_col: Color = repo.get_palette_color("bezel_metal")
	var trim_col: Color = repo.get_palette_color("bezel_trim")

	DiegeticScreenFactory.create_metal_strut(
		fork_holder,
		Vector3(pillar_x * 2.0 + 0.28, 0.16, 0.18),
		Vector3(0.0, beam_y, gantry_z),
		Vector3.ZERO,
		bezel_col
	)
	DiegeticScreenFactory.create_metal_strut(
		fork_holder,
		Vector3(pillar_x * 2.0 + 0.30, 0.04, 0.20),
		Vector3(0.0, beam_y + 0.09, gantry_z),
		Vector3.ZERO,
		trim_col.darkened(0.35)
	)
	for side_s: float in [-1.0, 1.0]:
		DiegeticScreenFactory.create_metal_strut(
			fork_holder,
			Vector3(0.18, beam_y + 0.16, 0.20),
			Vector3(side_s * pillar_x, (beam_y + 0.16) * 0.5, gantry_z),
			Vector3.ZERO,
			bezel_col
		)

	var pos_keys: Array[String] = ["left_sign_pos", "right_sign_pos"]
	var rot_keys: Array[String] = ["left_sign_rot_deg", "right_sign_rot_deg"]
	var lane_pos_keys: Array[String] = ["left_lane_collider_pos", "right_lane_collider_pos"]
	var lane_rot_keys: Array[String] = ["left_lane_collider_rot_deg", "right_lane_collider_rot_deg"]

	for idx: int in range(2):
		var s_pos: Vector3 = JsonConfigLoader.to_vec3(fcfg.get(pos_keys[idx], []), Vector3.ZERO)
		var s_rot: Vector3 = JsonConfigLoader.to_vec3(fcfg.get(rot_keys[idx], []), Vector3.ZERO)

		var sign_anchor: Node3D = Node3D.new()
		sign_anchor.position = s_pos
		sign_anchor.rotation_degrees = s_rot
		fork_holder.add_child(sign_anchor)

		DiegeticScreenFactory.create_metal_bezel(
			sign_anchor,
			sign_sz,
			b_pad,
			b_depth,
			Vector3(0.0, 0.0, -b_depth * 0.54),
			Vector3.ZERO,
			bezel_col
		)
		var hanger_h: float = maxf(0.12, beam_y - (s_pos.y + sign_sz.y * 0.45))
		for hx_s: float in [-0.55, 0.55]:
			DiegeticScreenFactory.create_metal_strut(
				fork_holder,
				Vector3(0.07, hanger_h + 0.12, 0.08),
				Vector3(s_pos.x + hx_s, beam_y - hanger_h * 0.5, gantry_z),
				Vector3.ZERO,
				bezel_col
			)

		var scr: Dictionary = DiegeticScreenFactory.create_screen(
			sign_anchor,
			Vector2i(int(sign_vp.x), int(sign_vp.y)),
			sign_sz,
			Vector3.ZERO,
			Vector3.ZERO,
			false,
			false
		)
		var canvas: _ForkGantrySignCanvas = _ForkGantrySignCanvas.new()
		canvas.fork_ctrl = self
		canvas.lane_idx = idx
		canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		(scr.get("root") as Control).add_child(canvas)
		sign_canvases.append(canvas)

		var sign_area: Area3D = Area3D.new()
		sign_area.collision_layer = col_layer
		sign_area.collision_mask = 0
		sign_area.set_meta("interact_type", "road_fork_lane")
		sign_area.set_meta("lane_index", idx)
		var sign_cs: CollisionShape3D = CollisionShape3D.new()
		var sign_box: BoxShape3D = BoxShape3D.new()
		sign_box.size = Vector3(sign_sz.x * 1.08, sign_sz.y * 1.12, sign_depth)
		sign_cs.shape = sign_box
		sign_area.add_child(sign_cs)
		sign_anchor.add_child(sign_area)
		lane_areas.append(sign_area)

		var road_area: Area3D = Area3D.new()
		road_area.collision_layer = col_layer
		road_area.collision_mask = 0
		road_area.position = JsonConfigLoader.to_vec3(fcfg.get(lane_pos_keys[idx], []), Vector3.ZERO)
		road_area.rotation_degrees = JsonConfigLoader.to_vec3(fcfg.get(lane_rot_keys[idx], []), Vector3.ZERO)
		road_area.set_meta("interact_type", "road_fork_lane")
		road_area.set_meta("lane_index", idx)
		var road_cs: CollisionShape3D = CollisionShape3D.new()
		var road_box: BoxShape3D = BoxShape3D.new()
		road_box.size = lane_box_sz
		road_cs.shape = road_box
		road_area.add_child(road_cs)
		fork_holder.add_child(road_area)
		lane_areas.append(road_area)

func _set_areas_pickable(enabled: bool) -> void:
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	var active_layer: int = maxi(1, int(fcfg.get("collision_layer", 32))) if enabled else 0
	for area: Area3D in lane_areas:
		if area != null and is_instance_valid(area):
			area.collision_layer = active_layer

func _set_fork_hidden() -> void:
	fork_state = STATE_HIDDEN
	visible = false
	hovered_lane_index = -1
	chosen_lane_index = -1
	_set_areas_pickable(false)
	for canvas: _ForkGantrySignCanvas in sign_canvases:
		DiegeticScreenFactory.set_screen_enabled(canvas, false)
	steering_feedback_updated.emit(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
	if trajectory_holder != null:
		trajectory_holder.visible = false

func _on_route_choices_offered(_options: Array) -> void:
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	var road_y: float = float(fcfg.get("road_y", -0.08))
	current_approach_z = float(fcfg.get("approach_start_z", -22.0))
	fork_state = STATE_APPROACHING
	state_timer = 0.0
	if engine != null:
		engine.sfx_requested.emit("air_brake", 0.62)
	hovered_lane_index = -1
	chosen_lane_index = -1
	visible = true
	if trajectory_holder != null:
		trajectory_holder.visible = true
	fork_holder.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, road_y, current_approach_z))
	_set_areas_pickable(true)
	_refresh_gantry_signs()

func _on_route_transition_started(option_index: int, _chosen_option: Dictionary) -> void:
	chosen_lane_index = option_index
	drive_start_z = current_approach_z if fork_state == STATE_APPROACHING else 0.0
	fork_state = STATE_DRIVING_BRANCH
	state_timer = 0.0
	visible = true
	_set_areas_pickable(false)
	_refresh_gantry_signs()

func _on_engine_state_changed() -> void:
	if engine == null:
		return
	if engine.mode == CombatEngine.MODE_ROUTE_CHOICE:
		if fork_state == STATE_HIDDEN:
			_on_route_choices_offered(engine.route_options)
		else:
			_refresh_gantry_signs()
	elif engine.mode == CombatEngine.MODE_ROUTE_TRANSITION:
		if fork_state != STATE_DRIVING_BRANCH:
			_on_route_transition_started(maxi(0, engine.pending_route_option_index), engine.pending_route_option)
	else:
		if fork_state != STATE_HIDDEN:
			_set_fork_hidden()

func _refresh_gantry_signs() -> void:
	var active: bool = (fork_state != STATE_HIDDEN)
	for canvas: _ForkGantrySignCanvas in sign_canvases:
		if canvas != null and is_instance_valid(canvas):
			DiegeticScreenFactory.set_screen_enabled(canvas, active)
			if active:
				DiegeticScreenFactory.request_redraw(canvas)

func _process(delta: float) -> void:
	if repo == null or engine == null or fork_state == STATE_HIDDEN:
		return
	time_accum += delta
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	var road_y: float = float(fcfg.get("road_y", -0.08))

	_animate_beacons()
	_animate_trajectory_indicators()

	if fork_state == STATE_APPROACHING:
		var app_dur: float = maxf(0.1, float(fcfg.get("approach_duration_s", 0.88)))
		var start_z: float = float(fcfg.get("approach_start_z", -22.0))
		var stop_z: float = float(fcfg.get("stop_z", 0.0))
		state_timer += delta
		var t_app: float = clampf(state_timer / app_dur, 0.0, 1.0)
		var eased_app: float = 1.0 - pow(1.0 - t_app, 3.0)
		current_approach_z = lerpf(start_z, stop_z, eased_app)
		fork_holder.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, road_y, current_approach_z))
		_emit_hover_preview_feedback(fcfg)
		if t_app >= 1.0:
			current_approach_z = stop_z
			fork_state = STATE_WAITING_CHOICE
		return

	if fork_state == STATE_WAITING_CHOICE:
		_emit_hover_preview_feedback(fcfg)
		return

	if fork_state == STATE_DRIVING_BRANCH:
		var drive_dur: float = maxf(0.25, float(fcfg.get("drive_duration_s", 1.68)))
		state_timer += delta
		var u_raw: float = clampf(state_timer / drive_dur, 0.0, 1.0)
		var u: float = u_raw * u_raw * (3.0 - 2.0 * u_raw)

		var side_sign: float = -1.0 if chosen_lane_index == 0 else 1.0
		var p2_cfg: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("bezier_p2", []), Vector3(1.65, 0.0, -8.5))
		var p3_cfg: Vector3 = JsonConfigLoader.to_vec3(fcfg.get("bezier_p3", []), Vector3(6.2, 0.0, -17.43))

		var p0: Vector3 = Vector3(0.0, 0.0, -drive_start_z)
		var p1: Vector3 = Vector3(0.0, 0.0, float(fcfg.get("bezier_p1_z", -5.2)))
		var p2: Vector3 = Vector3(side_sign * p2_cfg.x, 0.0, p2_cfg.z)
		var p3: Vector3 = Vector3(side_sign * p3_cfg.x, 0.0, p3_cfg.z)

		var car_pos: Vector3 = _cubic_bezier(p0, p1, p2, p3, u)
		var tangent: Vector3 = _cubic_bezier_tangent(p0, p1, p2, p3, u)
		var car_yaw_rad: float = atan2(-tangent.x, -tangent.z)

		var car_xform: Transform3D = Transform3D(Basis(Vector3.UP, car_yaw_rad), car_pos)
		var inv_xform: Transform3D = car_xform.affine_inverse()
		inv_xform.origin.y = road_y
		fork_holder.transform = inv_xform

		var turn_bell: float = sin(pow(u_raw, 0.78) * PI)
		var steer_max: float = float(fcfg.get("steer_wheel_turn_deg", 82.0))
		var cam_apex: float = float(fcfg.get("camera_apex_yaw_deg", 11.5))
		var bank_roll: float = float(fcfg.get("chassis_bank_roll_deg", 3.4))
		var squat_y: float = float(fcfg.get("chassis_turn_squat_y", -0.035))

		var wheel_deg: float = -side_sign * steer_max * turn_bell
		var cam_yaw_deg: float = -side_sign * cam_apex * turn_bell
		var roll_deg: float = side_sign * bank_roll * turn_bell
		var cur_squat: float = squat_y * turn_bell
		var compass_deg: float = rad_to_deg(car_yaw_rad)

		steering_feedback_updated.emit(wheel_deg, cam_yaw_deg, roll_deg, cur_squat, compass_deg, u_raw)

		if u_raw >= 1.0:
			_set_fork_hidden()
			engine.complete_route_transition()

func _emit_hover_preview_feedback(fcfg: Dictionary) -> void:
	if hovered_lane_index < 0:
		steering_feedback_updated.emit(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
		return
	var side_sign: float = -1.0 if hovered_lane_index == 0 else 1.0
	var preview_deg: float = float(fcfg.get("steer_hover_preview_deg", 18.0))
	var cam_preview: float = float(fcfg.get("camera_apex_yaw_deg", 11.5)) * 0.28
	steering_feedback_updated.emit(-side_sign * preview_deg, -side_sign * cam_preview, 0.0, 0.0, -side_sign * 8.0, 0.0)

func _animate_beacons() -> void:
	var left_base: Color = get_lane_accent_color(0)
	var right_base: Color = get_lane_accent_color(1)
	var pulse: float = 0.65 + 0.35 * sin(time_accum * 6.5)

	var l_gain: float = 1.35 if (hovered_lane_index == 0 or chosen_lane_index == 0) else (0.35 if chosen_lane_index == 1 else pulse)
	var r_gain: float = 1.35 if (hovered_lane_index == 1 or chosen_lane_index == 1) else (0.35 if chosen_lane_index == 0 else pulse)

	for m: StandardMaterial3D in left_beacon_mats:
		if m != null:
			m.albedo_color = left_base * l_gain
	for m: StandardMaterial3D in right_beacon_mats:
		if m != null:
			m.albedo_color = right_base * r_gain

func _animate_trajectory_indicators() -> void:
	if trajectory_holder == null:
		return
	var fcfg: Dictionary = repo.cockpit.get("road_fork", {}) as Dictionary
	if not bool(fcfg.get("trajectory_enabled", true)):
		return

	var active_lane: int = -1
	if fork_state == STATE_DRIVING_BRANCH:
		active_lane = chosen_lane_index
	elif fork_state == STATE_APPROACHING or fork_state == STATE_WAITING_CHOICE:
		active_lane = hovered_lane_index

	var stream_speed: float = float(fcfg.get("trajectory_stream_speed", 1.6))
	var stream_freq: float = float(fcfg.get("trajectory_stream_freq", 3.0))
	var base_alpha: float = float(fcfg.get("trajectory_base_alpha", 0.88))

	for side_i: int in range(2):
		var dashes: Array[MeshInstance3D] = trajectory_dashes_left if side_i == 0 else trajectory_dashes_right
		var mats: Array[StandardMaterial3D] = trajectory_mats_left if side_i == 0 else trajectory_mats_right
		var is_active: bool = (side_i == active_lane)
		var accent: Color = get_lane_accent_color(side_i)

		var total: int = dashes.size()
		for k: int in range(total):
			var mi: MeshInstance3D = dashes[k]
			var mat: StandardMaterial3D = mats[k]
			if mi == null or not is_instance_valid(mi) or mat == null:
				continue
			if not is_active:
				mi.visible = false
				continue
			mi.visible = true
			var t: float = float(k + 0.5) / float(total)
			var wave: float = sin((t * stream_freq - time_accum * stream_speed) * TAU) * 0.5 + 0.5
			var cur_alpha: float = base_alpha * lerpf(0.35, 1.0, wave)
			mat.albedo_color = Color(accent.r, accent.g, accent.b, cur_alpha)

static func _cubic_bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var omt: float = 1.0 - t
	var omt2: float = omt * omt
	var t2: float = t * t
	return (omt2 * omt) * p0 + (3.0 * omt2 * t) * p1 + (3.0 * omt * t2) * p2 + (t2 * t) * p3

static func _cubic_bezier_tangent(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var omt: float = 1.0 - t
	var deriv: Vector3 = (3.0 * omt * omt) * (p1 - p0) + (6.0 * omt * t) * (p2 - p1) + (3.0 * t * t) * (p3 - p2)
	if deriv.length_squared() < 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return deriv.normalized()


class _ForkGantrySignCanvas extends Control:
	var fork_ctrl: RoadFork3DController
	var lane_idx: int = 0

	func _draw() -> void:
		if fork_ctrl == null or fork_ctrl.repo == null or fork_ctrl.engine == null:
			return
		var rep: GameRepository = fork_ctrl.repo
		var eng: CombatEngine = fork_ctrl.engine
		var sz: Vector2 = size
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")

		var opts: Array[Dictionary] = eng.route_options
		if opts.is_empty() and not eng.pending_route_option.is_empty() and fork_ctrl.chosen_lane_index == lane_idx:
			opts = [eng.pending_route_option, eng.pending_route_option]

		var accent: Color = fork_ctrl.get_lane_accent_color(lane_idx)
		var is_hovered: bool = (fork_ctrl.hovered_lane_index == lane_idx) or (fork_ctrl.chosen_lane_index == lane_idx)
		var is_dimmed: bool = (fork_ctrl.chosen_lane_index >= 0 and fork_ctrl.chosen_lane_index != lane_idx)
		var dim_mul: float = 0.45 if is_dimmed else 1.0
		var brd_col: Color = txt_col if is_hovered else (accent * (0.42 if is_dimmed else 0.96))

		DiegeticScreenFactory.draw_industrial_plate(
			self,
			Rect2(4.0, 4.0, sz.x - 8.0, sz.y - 8.0),
			rep,
			brd_col,
			14.0,
			4.2 if is_hovered else 2.8,
			true,
			58.0,
			is_hovered
		)

		var key_str: String = rep.get_ui_text("fork", "left_key" if lane_idx == 0 else "right_key")
		var shield_x: float = 18.0 if lane_idx == 0 else (sz.x - 68.0)
		var key_shield: Rect2 = Rect2(shield_x, 12.0, 50.0, 44.0)
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")
		DiegeticScreenFactory.draw_chamfer_rect(self, key_shield, 7.0, panel_bg, brd_col, 2.4)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(key_shield.position.x, key_shield.position.y + 32.0),
			key_str,
			HORIZONTAL_ALIGNMENT_CENTER,
			key_shield.size.x,
			28,
			(txt_col if is_hovered else accent.lightened(0.24)) * dim_mul,
			out_col,
			3,
			18
		)

		var lane_tag: String = rep.get_ui_text("fork", "left_lane_tag" if lane_idx == 0 else "right_lane_tag")
		var hdr_x: float = 80.0 if lane_idx == 0 else 22.0
		var hdr_w: float = sz.x - 102.0
		var hdr_align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT if lane_idx == 0 else HORIZONTAL_ALIGNMENT_RIGHT
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(hdr_x, 44.0),
			lane_tag,
			hdr_align,
			hdr_w,
			27,
			(txt_col if is_hovered else accent.lightened(0.22)) * dim_mul,
			out_col,
			3,
			18
		)

		if lane_idx >= opts.size():
			return

		var opt: Dictionary = opts[lane_idx]
		var ntype: String = str(opt.get("type", "combat"))
		var prefix_key: String = "threats_prefix" if ntype == "combat" else "site_prefix"
		var title_txt: String = str(opt.get("title", rep.get_ui_text("fork", "fallback_lane_title"))).to_upper()
		var sub_txt: String = rep.get_ui_text("fork", prefix_key) + fork_ctrl.format_option_hostiles(opt)
		var bonus_txt: String = fork_ctrl.format_option_bonus(opt)
		var next_txt: String = fork_ctrl.format_option_next_nodes(opt)
		if not next_txt.is_empty():
			bonus_txt += "  •  " + rep.get_ui_text("fork", "next_prefix") + " " + next_txt

		var badge_c: Vector2 = Vector2(58.0, 128.0)
		draw_circle(badge_c, 34.0, panel_bg)
		draw_arc(badge_c, 34.0, 0.0, TAU, 24, accent * dim_mul, 3.0, true)
		Navigator3DController._NavigatorCanvas.draw_map_node_icon(self, badge_c, 30.0, opt, accent * dim_mul, f_disp)

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(108.0, 114.0),
			title_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 128.0,
			30,
			txt_col * dim_mul,
			out_col,
			4,
			18
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(108.0, 156.0),
			sub_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 128.0,
			22,
			rep.get_palette_color("mfd_muted").lightened(0.22) * dim_mul,
			out_col,
			3,
			14
		)

		var pill_rect: Rect2 = Rect2(24.0, 196.0, sz.x - 48.0, 54.0)
		var fill_col: Color = Color(accent.r * 0.22, accent.g * 0.18, accent.b * 0.12, 0.95)
		DiegeticScreenFactory.draw_chamfer_rect(
			self,
			pill_rect,
			8.0,
			fill_col,
			accent * dim_mul,
			2.4
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(pill_rect.position.x + 14.0, pill_rect.position.y + 36.0),
			bonus_txt,
			HORIZONTAL_ALIGNMENT_CENTER,
			pill_rect.size.x - 28.0,
			24,
			(txt_col if is_hovered else accent.lightened(0.26)) * dim_mul,
			out_col,
			3,
			15
		)
