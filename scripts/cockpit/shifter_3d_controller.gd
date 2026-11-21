class_name Shifter3DController
extends Node3D

signal hover_info_changed(text: String)

const COLLISION_LAYER_COCKPIT: int = 2

var repo: GameRepository
var engine: CombatEngine

var gate_model: Node3D
var lever_pivot: Node3D
var knob_area: Area3D
var neutral_bar_mat: StandardMaterial3D

var slot_visuals: Dictionary = {}

var is_dragging_lever: bool = false
var preview_gear: int = 1
var hovered_gear_slot: int = -99

var armed_grind_gear: int = -99
var armed_grind_timer: float = 0.0

var current_lever_xz: Vector2 = Vector2.ZERO
var current_lever_rot: Vector3 = Vector3.ZERO

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine

	var sh_cfg: Dictionary = repo.cockpit.get("shifter", {}) as Dictionary
	position = JsonConfigLoader.to_vec3(sh_cfg.get("assembly_pos", []), Vector3(0.555, 0.688, -0.350))
	rotation_degrees = JsonConfigLoader.to_vec3(sh_cfg.get("assembly_rot_deg", []), Vector3(38.0, -25.0, 0.0))

	_build_h_gate_hardware(sh_cfg)
	_build_lever(sh_cfg)
	_build_h_slot_indicators_and_colliders(sh_cfg)

	engine.state_changed.connect(_on_engine_state_changed)
	engine.gear_shifted.connect(_on_gear_shifted)
	_snap_to_gear(engine.current_gear)
	_refresh_visuals()

func _build_h_gate_hardware(sh_cfg: Dictionary) -> void:
	var g_scale: Vector3 = JsonConfigLoader.to_vec3(sh_cfg.get("gate_scale", []), Vector3(1.52, 1.30, 1.44))

	var collar: MeshInstance3D = MeshInstance3D.new()
	var cbox: BoxMesh = BoxMesh.new()
	cbox.size = Vector3(0.23 * g_scale.x, 0.05, 0.28 * g_scale.z)
	collar.mesh = cbox
	collar.position = Vector3(0.0, -0.052, 0.0)
	var cmat: StandardMaterial3D = StandardMaterial3D.new()
	cmat.albedo_color = repo.get_palette_color("bezel_metal", Color(0.13, 0.15, 0.18))
	cmat.metallic = 0.55
	cmat.roughness = 0.45
	collar.material_override = cmat
	add_child(collar)

	var gate_scene: PackedScene = repo.load_model_scene("gearbox_gate")
	if gate_scene != null:
		gate_model = gate_scene.instantiate() as Node3D
		gate_model.scale = g_scale
		add_child(gate_model)

	var n_bar: MeshInstance3D = MeshInstance3D.new()
	var n_mesh: BoxMesh = BoxMesh.new()
	n_mesh.size = Vector3(0.195, 0.005, 0.014)
	n_bar.mesh = n_mesh
	n_bar.position = Vector3(0.0, 0.011, 0.0)
	neutral_bar_mat = StandardMaterial3D.new()
	neutral_bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	neutral_bar_mat.albedo_color = repo.get_palette_color("bezel_metal").lightened(0.14)
	n_bar.material_override = neutral_bar_mat
	add_child(n_bar)

func _build_lever(sh_cfg: Dictionary) -> void:
	lever_pivot = Node3D.new()
	var l_scl: Vector3 = JsonConfigLoader.to_vec3(sh_cfg.get("lever_scale", []), Vector3(0.84, 0.56, 0.84))
	lever_pivot.scale = l_scl
	add_child(lever_pivot)

	var lever_scene: PackedScene = repo.load_model_scene("shift_lever")
	if lever_scene != null:
		lever_pivot.add_child(lever_scene.instantiate())

	knob_area = Area3D.new()
	knob_area.collision_layer = COLLISION_LAYER_COCKPIT
	knob_area.collision_mask = 0
	knob_area.position = Vector3(0.0, 0.185, 0.0)
	knob_area.set_meta("interact_type", "shift_knob")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = float(sh_cfg.get("knob_collider_radius", 0.058))
	cs.shape = sph
	knob_area.add_child(cs)
	lever_pivot.add_child(knob_area)

func _build_h_slot_indicators_and_colliders(sh_cfg: Dictionary) -> void:
	slot_visuals.clear()
	var slots_cfg: Dictionary = sh_cfg.get("slots", {}) as Dictionary

	for gd: Dictionary in repo.ordered_gears:
		var g_idx: int = int(gd.get("index", 0))
		var key: String = str(g_idx)
		if not slots_cfg.has(key):
			continue
		var scfg: Dictionary = slots_cfg[key] as Dictionary
		var pad_xz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("pad_xz", []), Vector2.ZERO)
		var lbl_xz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("label_xz", []), pad_xz)
		var st_xz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("status_xz", []), lbl_xz)

		var pad_mesh: MeshInstance3D = MeshInstance3D.new()
		var pbox: BoxMesh = BoxMesh.new()
		pbox.size = Vector3(0.022, 0.007, 0.032)
		pad_mesh.mesh = pbox
		pad_mesh.position = Vector3(pad_xz.x, 0.015, pad_xz.y)
		var pmat: StandardMaterial3D = StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pad_mesh.material_override = pmat
		add_child(pad_mesh)

		var gear_lbl: Label3D = Label3D.new()
		gear_lbl.text = str(gd.get("short_name", key))
		DiegeticScreenFactory.style_label_3d(gear_lbl, repo, "display", 54, 14, 0.00044, repo.get_palette_color("mfd_text"))
		gear_lbl.position = Vector3(lbl_xz.x, 0.028, lbl_xz.y)
		gear_lbl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		add_child(gear_lbl)

		var status_lbl: Label3D = Label3D.new()
		DiegeticScreenFactory.style_label_3d(status_lbl, repo, "display", 40, 13, 0.00034, repo.get_palette_color("slot_free"))
		status_lbl.position = Vector3(st_xz.x, 0.028, st_xz.y)
		status_lbl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		add_child(status_lbl)

		var slot_area: Area3D = Area3D.new()
		slot_area.collision_layer = COLLISION_LAYER_COCKPIT
		slot_area.collision_mask = 0
		var min_z: float = minf(pad_xz.y, lbl_xz.y)
		var max_z: float = maxf(pad_xz.y, lbl_xz.y)
		slot_area.position = Vector3(pad_xz.x, 0.018, (min_z + max_z) * 0.5)
		slot_area.set_meta("interact_type", "gear_slot")
		slot_area.set_meta("gear_index", g_idx)
		var cs: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(0.052, 0.036, (max_z - min_z) + 0.044)
		cs.shape = box
		slot_area.add_child(cs)
		add_child(slot_area)

		slot_visuals[g_idx] = {
			"pad_mat": pmat,
			"gear_lbl": gear_lbl,
			"status_lbl": status_lbl
		}

func set_hovered_slot(gear_slot: int) -> void:
	if hovered_gear_slot == gear_slot:
		return
	hovered_gear_slot = gear_slot
	if not is_dragging_lever and engine != null:
		engine.set_preview_gear(gear_slot if gear_slot != engine.current_gear else -99)
	_refresh_visuals()

func request_safe_shift(target_gear: int) -> bool:
	if engine.mode != CombatEngine.MODE_COMBAT:
		return false
	if target_gear == engine.current_gear:
		return false

	var eval: Dictionary = engine.preview_manual_shift(target_gear)
	if not bool(eval.get("allowed", false)):
		armed_grind_gear = -99
		return engine.request_manual_shift(target_gear)

	if int(eval.get("extra_grind_steps", 0)) > 0 and armed_grind_gear != target_gear:
		var sh_cfg: Dictionary = repo.cockpit.get("shifter", {}) as Dictionary
		armed_grind_gear = target_gear
		armed_grind_timer = float(sh_cfg.get("grind_confirm_timeout_sec", 3.5))
		engine.sfx_requested.emit("switch_click", 0.85)
		var g_name: String = engine.transmission.gear_short_name(target_gear)
		hover_info_changed.emit(repo.get_ui_text("screens", "shifter_confirm_grind") % [
			g_name,
			int(eval.get("hp_cost", 0)),
			int(eval.get("heat_cost", 0))
		])
		_refresh_visuals()
		return false

	armed_grind_gear = -99
	armed_grind_timer = 0.0
	return engine.request_manual_shift(target_gear)

func request_safe_step(delta_step: int) -> bool:
	var clean_step: int = clampi(delta_step, -1, 1)
	if clean_step == 0:
		return false
	var candidate: int = clampi(engine.current_gear + clean_step, engine.transmission.min_gear(), engine.transmission.max_gear())
	if candidate == engine.current_gear:
		return false
	armed_grind_gear = -99
	armed_grind_timer = 0.0
	return engine.request_manual_shift(candidate)

func begin_knob_drag() -> void:
	if engine.mode != CombatEngine.MODE_COMBAT:
		return
	is_dragging_lever = true
	preview_gear = engine.current_gear
	engine.set_preview_gear(preview_gear)
	_emit_drag_feedback()
	_refresh_visuals()

func update_knob_drag_ray(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if not is_dragging_lever:
		return
	var plane_normal: Vector3 = global_transform.basis.y.normalized()
	var plane_point: Vector3 = global_transform.origin + plane_normal * 0.045
	var gate_plane: Plane = Plane(plane_normal, plane_point)
	var hit_world: Variant = gate_plane.intersects_ray(ray_origin, ray_dir)
	if hit_world == null:
		return

	var local_pt: Vector3 = to_local(hit_world as Vector3)
	var next_gear: int = _resolve_gear_from_local_xz(local_pt.x, local_pt.z)
	if next_gear != preview_gear:
		preview_gear = next_gear
		engine.set_preview_gear(preview_gear)
		engine.sfx_requested.emit("switch_click", 0.45)
		_emit_drag_feedback()
		_refresh_visuals()

func _resolve_gear_from_local_xz(lx: float, lz: float) -> int:
	var sh_cfg: Dictionary = repo.cockpit.get("shifter", {}) as Dictionary
	var n_band: float = float(sh_cfg.get("neutral_band_half_z", 0.032))
	var splits: Array = sh_cfg.get("column_split_x", [-0.056, 0.0, 0.056]) as Array
	var sx0: float = float(splits[0]) if splits.size() > 0 else -0.056
	var sx1: float = float(splits[1]) if splits.size() > 1 else 0.0
	var sx2: float = float(splits[2]) if splits.size() > 2 else 0.056

	if absf(lz) <= n_band:
		return 0

	var is_top: bool = (lz < 0.0)
	if lx < sx0:
		return -1 if is_top else 0
	if lx < sx1:
		return 1 if is_top else 2
	if lx < sx2:
		return 3 if is_top else 4
	return 5 if is_top else 6

func cancel_knob_drag() -> void:
	if not is_dragging_lever:
		return
	is_dragging_lever = false
	preview_gear = engine.current_gear
	if engine != null:
		engine.set_preview_gear(-99)
	_refresh_visuals()

func end_knob_drag() -> void:
	if not is_dragging_lever:
		return
	is_dragging_lever = false
	if engine != null:
		engine.set_preview_gear(-99)
	if preview_gear != engine.current_gear:
		armed_grind_gear = -99
		engine.request_manual_shift(preview_gear)
	_refresh_visuals()

func _format_shift_prediction(target_gear: int) -> String:
	if engine == null or engine.mode != CombatEngine.MODE_COMBAT or target_gear == engine.current_gear:
		return ""
	var tags: PackedStringArray = PackedStringArray()
	if target_gear >= 1 and not engine.rev_match_used_this_turn and engine.transmission.is_optimal(target_gear, engine.rpm_units):
		var rev_blk: int = int(repo.gameplay().get("rev_match_block_bonus", 3))
		for rid: String in engine.owned_relics:
			rev_blk += int(repo.get_relic(rid).get("rev_match_extra_block", 0))
		tags.append(repo.get_ui_text("screens", "shifter_pred_rev_match_fmt") % rev_blk)
	if engine.transmission.is_stall_risk(target_gear, engine.rpm_units):
		tags.append(repo.get_ui_text("screens", "shifter_pred_stall"))
	elif engine.transmission.is_redline(target_gear, engine.rpm_units):
		tags.append(repo.get_ui_text("screens", "shifter_pred_redline"))
	if not engine.hand.is_empty():
		var ready_cnt: int = 0
		for i: int in range(engine.hand.size()):
			if bool(engine.can_play_card(i, false, target_gear).get("playable", false)):
				ready_cnt += 1
		tags.append(repo.get_ui_text("screens", "shifter_pred_cards_fmt") % [ready_cnt, engine.hand.size()])
	return ("  •  " + " • ".join(tags)) if not tags.is_empty() else ""

func _emit_drag_feedback() -> void:
	if preview_gear == engine.current_gear:
		var cur_name: String = engine.transmission.gear_short_name(engine.current_gear)
		hover_info_changed.emit(repo.get_ui_text("screens", "shifter_drag_idle_fmt") % cur_name)
		return

	var eval: Dictionary = engine.preview_manual_shift(preview_gear)
	var g_name: String = engine.transmission.gear_short_name(preview_gear)
	var pred_suffix: String = _format_shift_prediction(preview_gear)
	if not bool(eval.get("allowed", false)):
		hover_info_changed.emit(repo.get_ui_text("screens", "shifter_drag_blocked_fmt") % [g_name, str(eval.get("reason", ""))])
	elif int(eval.get("extra_grind_steps", 0)) > 0:
		hover_info_changed.emit((repo.get_ui_text("screens", "shifter_drag_grind_fmt") % [
			g_name,
			int(eval.get("hp_cost", 0)),
			int(eval.get("heat_cost", 0)),
			engine.transmission.gear_short_name(engine.current_gear)
		]) + pred_suffix)
	else:
		hover_info_changed.emit((repo.get_ui_text("screens", "shifter_drag_free_fmt") % g_name) + pred_suffix)

func describe_slot_hover(gear_index: int) -> String:
	var g_dict: Dictionary = repo.get_gear(gear_index)
	var g_name: String = str(g_dict.get("short_name", str(gear_index)))
	var role: String = str(g_dict.get("role", ""))
	var desc: String = str(g_dict.get("description", ""))
	if gear_index == engine.current_gear:
		return repo.get_ui_text("screens", "shifter_slot_engaged_fmt") % [g_name, role, desc]
	var eval: Dictionary = engine.preview_manual_shift(gear_index)
	if not bool(eval.get("allowed", false)):
		return repo.get_ui_text("screens", "shifter_slot_locked_fmt") % [g_name, role, str(eval.get("reason", repo.get_ui_text("screens", "shifter_tag_locked")))]
	var pred_suffix: String = _format_shift_prediction(gear_index)
	if int(eval.get("extra_grind_steps", 0)) > 0:
		if armed_grind_gear == gear_index:
			return (repo.get_ui_text("screens", "shifter_confirm_grind") % [g_name, int(eval.get("hp_cost", 0)), int(eval.get("heat_cost", 0))]) + pred_suffix
		return (repo.get_ui_text("screens", "shifter_slot_grind_fmt") % [
			g_name,
			int(eval.get("hp_cost", 0)),
			int(eval.get("heat_cost", 0)),
			desc
		]) + pred_suffix
	return (repo.get_ui_text("screens", "shifter_slot_free_fmt") % [g_name, desc]) + pred_suffix

func _on_engine_state_changed() -> void:
	if armed_grind_gear == engine.current_gear:
		armed_grind_gear = -99
	_refresh_visuals()

func _on_gear_shifted(_old_gear: int, _new_gear: int, _was_grind: bool) -> void:
	armed_grind_gear = -99
	armed_grind_timer = 0.0
	_refresh_visuals()

func _pose_for_gear(gear_index: int) -> Dictionary:
	var sh_cfg: Dictionary = repo.cockpit.get("shifter", {}) as Dictionary
	var slots_cfg: Dictionary = sh_cfg.get("slots", {}) as Dictionary
	var scfg: Dictionary = slots_cfg.get(str(gear_index), {}) as Dictionary
	var l_xz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("lever_xz", []), Vector2.ZERO)

	var max_pitch: float = float(sh_cfg.get("lever_pitch_deg", 15.0))
	var max_roll: float = float(sh_cfg.get("lever_roll_deg", 10.0))
	var pitch_x: float = clampf(l_xz.y / 0.084, -1.0, 1.0) * max_pitch
	var roll_z: float = -clampf(l_xz.x / 0.086, -1.0, 1.0) * max_roll
	return {"xz": l_xz, "rot": Vector3(pitch_x, 0.0, roll_z)}

func _snap_to_gear(gear_index: int) -> void:
	var pose: Dictionary = _pose_for_gear(gear_index)
	current_lever_xz = pose["xz"] as Vector2
	current_lever_rot = pose["rot"] as Vector3
	if lever_pivot != null:
		lever_pivot.position = Vector3(current_lever_xz.x, 0.012, current_lever_xz.y)
		lever_pivot.rotation_degrees = current_lever_rot

func _refresh_visuals() -> void:
	if repo == null or engine == null:
		return
	var c_active: Color = repo.get_palette_color("slot_active")
	var c_free: Color = repo.get_palette_color("slot_free")
	var c_grind: Color = repo.get_palette_color("slot_grind")
	var c_locked: Color = repo.get_palette_color("slot_locked")
	var c_sel: Color = repo.get_palette_color("selected_glow")

	var c_txt: Color = repo.get_palette_color("mfd_text")
	if neutral_bar_mat != null:
		var n_hi: bool = (engine.current_gear == 0) or (is_dragging_lever and preview_gear == 0) or (hovered_gear_slot == 0)
		neutral_bar_mat.albedo_color = c_active if engine.current_gear == 0 else (c_free if n_hi else repo.get_palette_color("bezel_metal").lightened(0.14))

	for g_key: Variant in slot_visuals.keys():
		var g_idx: int = int(g_key)
		var refs: Dictionary = slot_visuals[g_idx] as Dictionary
		var pmat: StandardMaterial3D = refs["pad_mat"] as StandardMaterial3D
		var g_lbl: Label3D = refs["gear_lbl"] as Label3D
		var s_lbl: Label3D = refs["status_lbl"] as Label3D

		var is_cur: bool = (g_idx == engine.current_gear)
		var is_prev: bool = is_dragging_lever and (g_idx == preview_gear)
		var is_hov: bool = (g_idx == hovered_gear_slot)
		var is_armed: bool = (g_idx == armed_grind_gear)

		if is_cur:
			pmat.albedo_color = c_active
			g_lbl.modulate = c_active
			s_lbl.text = repo.get_ui_text("screens", "shifter_tag_active")
			s_lbl.modulate = c_active
		else:
			var eval: Dictionary = engine.preview_manual_shift(g_idx)
			var col: Color = c_free
			var st_txt: String = repo.get_ui_text("screens", "shifter_tag_free")
			if not bool(eval.get("allowed", false)):
				col = c_locked
				st_txt = repo.get_ui_text("screens", "shifter_tag_locked")
			elif int(eval.get("extra_grind_steps", 0)) > 0:
				col = c_sel if is_armed else c_grind
				st_txt = repo.get_ui_text("screens", "shifter_tag_confirm") if is_armed else (repo.get_ui_text("screens", "shifter_tag_grind_fmt") % int(eval.get("hp_cost", 0)))

			var bright: bool = is_prev or is_hov or is_armed
			pmat.albedo_color = c_txt if is_prev else (col if bright else col * 0.52)
			g_lbl.modulate = c_txt if (is_prev or is_hov) else col.lightened(0.18)
			s_lbl.text = st_txt
			s_lbl.modulate = c_txt if is_prev else col

func _process(delta: float) -> void:
	if repo == null or lever_pivot == null:
		return
	if armed_grind_timer > 0.0:
		armed_grind_timer = maxf(0.0, armed_grind_timer - delta)
		if armed_grind_timer <= 0.0 and armed_grind_gear != -99:
			armed_grind_gear = -99
			_refresh_visuals()

	var sh_cfg: Dictionary = repo.cockpit.get("shifter", {}) as Dictionary
	var speed: float = float(sh_cfg.get("lever_tween_speed", 16.0))
	var target_gear_for_pose: int = preview_gear if is_dragging_lever else engine.current_gear
	var pose: Dictionary = _pose_for_gear(target_gear_for_pose)

	var t: float = clampf(delta * speed, 0.0, 1.0)
	current_lever_xz = current_lever_xz.lerp(pose["xz"] as Vector2, t)
	current_lever_rot = current_lever_rot.lerp(pose["rot"] as Vector3, t)
	lever_pivot.position = Vector3(current_lever_xz.x, 0.012, current_lever_xz.y)
	lever_pivot.rotation_degrees = current_lever_rot
