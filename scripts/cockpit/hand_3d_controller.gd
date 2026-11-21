class_name Hand3DController
extends Node3D

const COLLISION_LAYER_CARDS: int = 4

var repo: GameRepository
var engine: CombatEngine

var slot_pool: Array[Dictionary] = []
var card_nodes: Array[Dictionary] = []
var discard_fx_slot: Dictionary = {}
var shared_bar_mesh: BoxMesh
var shared_shadow_mesh: QuadMesh

var last_turn_seen: int = -1
var last_interaction_pos: Vector3 = Vector3(0.0, 0.08, 0.06)
var hovered_hand_index: int = -1
var selected_hand_index: int = -1
var dragged_hand_index: int = -1
var drag_visual_delta_px: Vector2 = Vector2.ZERO

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine
	var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
	position = JsonConfigLoader.to_vec3(hcfg.get("anchor_pos", []), Vector3(-0.185, 0.692, -0.295))
	_init_shared_meshes_and_pool(hcfg)
	_init_recyclable_discard_slot(hcfg)
	engine.state_changed.connect(_rebuild_hand)
	engine.preview_gear_changed.connect(_on_preview_gear_changed)
	engine.card_played_fx.connect(_on_card_played_fx)
	_rebuild_hand()

func _init_shared_meshes_and_pool(hcfg: Dictionary) -> void:
	var w_sz: Vector2 = JsonConfigLoader.to_vec2(hcfg.get("card_screen_size_m", []), Vector2(0.152, 0.218))
	shared_bar_mesh = BoxMesh.new()
	shared_bar_mesh.size = Vector3(w_sz.x + 0.008, 0.009, 0.010)

	shared_shadow_mesh = QuadMesh.new()
	shared_shadow_mesh.size = JsonConfigLoader.to_vec2(hcfg.get("card_shadow_size_m", []), Vector2(0.165, 0.225))
	shared_shadow_mesh.orientation = PlaneMesh.FACE_Y

	var max_slots: int = maxi(6, int(repo.gameplay().get("max_hand_size", 10)))
	var frame_scene: PackedScene = repo.load_model_scene("card_frame_3d")
	slot_pool.clear()
	for _i: int in range(max_slots):
		var entry: Dictionary = _create_card_slot_entry(hcfg, frame_scene)
		_set_slot_active(entry, false)
		slot_pool.append(entry)

func _set_slot_active(entry: Dictionary, active: bool) -> void:
	var holder: Node3D = entry.get("root") as Node3D
	if holder != null and is_instance_valid(holder):
		holder.visible = active
	var shadow_m: MeshInstance3D = entry.get("shadow") as MeshInstance3D
	if shadow_m != null and is_instance_valid(shadow_m):
		shadow_m.visible = active
	var area: Area3D = entry.get("area") as Area3D
	if area != null and is_instance_valid(area):
		area.collision_layer = COLLISION_LAYER_CARDS if active else 0
	var c_canvas: CardEmblemCanvas = entry.get("card_canvas") as CardEmblemCanvas
	if c_canvas != null and is_instance_valid(c_canvas):
		DiegeticScreenFactory.set_screen_enabled(c_canvas, active)

func set_hovered_index(index: int) -> void:
	if hovered_hand_index == index:
		return
	hovered_hand_index = index
	_refresh_card_footers()

func set_selected_index(index: int) -> void:
	if index >= 0 and index < card_nodes.size():
		var h: Node3D = card_nodes[index].get("root") as Node3D
		if h != null and is_instance_valid(h):
			last_interaction_pos = h.position
	if selected_hand_index == index:
		return
	selected_hand_index = index
	_refresh_card_footers()

func clear_selection() -> void:
	if selected_hand_index == -1 and dragged_hand_index == -1:
		return
	selected_hand_index = -1
	dragged_hand_index = -1
	drag_visual_delta_px = Vector2.ZERO
	_refresh_card_footers()

func set_drag_state(index: int, delta_px: Vector2) -> void:
	if index >= 0 and index < card_nodes.size():
		var h: Node3D = card_nodes[index].get("root") as Node3D
		if h != null and is_instance_valid(h):
			last_interaction_pos = h.position
	dragged_hand_index = index
	drag_visual_delta_px = delta_px

func get_card_screen_pos(hand_index: int, cam: Camera3D) -> Vector2:
	if cam == null or hand_index < 0 or hand_index >= card_nodes.size():
		return Vector2.ZERO
	var holder: Node3D = card_nodes[hand_index].get("root") as Node3D
	if holder == null or not is_instance_valid(holder):
		return Vector2.ZERO
	return cam.unproject_position(holder.global_position + Vector3(0.0, 0.06, 0.0))

func describe_card_hover(hand_index: int) -> String:
	if hand_index < 0 or hand_index >= engine.hand.size():
		return ""
	var card: Dictionary = repo.get_card(engine.hand[hand_index])
	var check: Dictionary = engine.can_play_card(hand_index)
	var gears_txt: String = engine.transmission.format_allowed_gears(card.get("allowed_gears", []) as Array)
	var name_txt: String = str(card.get("name", ""))
	var summary: String = CardEffectFormatter.format_inline_summary(repo, engine, card)
	if bool(check.get("playable", false)):
		return repo.get_ui_text("combat", "card_hover_ready_fmt") % [name_txt.to_upper(), gears_txt, summary]
	return repo.get_ui_text("combat", "card_hover_blocked_fmt") % [str(check.get("reason", "")), name_txt.to_upper(), summary]

func _on_preview_gear_changed(_gear_idx: int) -> void:
	_refresh_hand_in_place()

func _clear_all_card_nodes() -> void:
	for entry: Dictionary in slot_pool:
		entry["card_id"] = ""
		_set_slot_active(entry, false)
	card_nodes.clear()

func _create_card_slot_entry(hcfg: Dictionary, frame_scene: PackedScene) -> Dictionary:
	var vp_sz: Vector2 = JsonConfigLoader.to_vec2(hcfg.get("card_viewport", []), Vector2(380.0, 546.0))
	var w_sz: Vector2 = JsonConfigLoader.to_vec2(hcfg.get("card_screen_size_m", []), Vector2(0.152, 0.218))
	var frame_scl: Vector3 = JsonConfigLoader.to_vec3(hcfg.get("card_frame_scale", []), Vector3(1.24, 1.25, 1.0))

	var holder: Node3D = Node3D.new()
	add_child(holder)

	if frame_scene != null:
		var f_inst: Node3D = frame_scene.instantiate() as Node3D
		f_inst.scale = frame_scl
		holder.add_child(f_inst)

	var border_bar: MeshInstance3D = MeshInstance3D.new()
	border_bar.mesh = shared_bar_mesh
	border_bar.position = Vector3(0.0, w_sz.y * 0.5 + 0.006, 0.006)
	border_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bar_mat: StandardMaterial3D = StandardMaterial3D.new()
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	border_bar.material_override = bar_mat
	holder.add_child(border_bar)

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		holder,
		Vector2i(int(vp_sz.x), int(vp_sz.y)),
		w_sz,
		Vector3(0.0, -0.002, 0.0075),
		Vector3.ZERO,
		false,
		true
	)
	var card_canvas: CardEmblemCanvas = CardEmblemCanvas.new()
	card_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(scr["root"] as Control).add_child(card_canvas)

	var area: Area3D = Area3D.new()
	area.collision_layer = COLLISION_LAYER_CARDS
	area.collision_mask = 0
	area.monitoring = false
	area.set_meta("interact_type", "hand_card")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(w_sz.x + 0.012, w_sz.y + 0.018, 0.026)
	cs.shape = box
	area.add_child(cs)
	holder.add_child(area)

	var shadow_mesh: MeshInstance3D = null
	var shadow_mat: StandardMaterial3D = null
	var base_s_col: Color = JsonConfigLoader.to_color(hcfg.get("card_shadow_color", []), Color(0.015, 0.018, 0.024, 0.58))
	if bool(hcfg.get("card_shadow_enabled", true)):
		shadow_mesh = MeshInstance3D.new()
		shadow_mesh.mesh = shared_shadow_mesh
		shadow_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		shadow_mat = StandardMaterial3D.new()
		shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		shadow_mat.albedo_color = base_s_col
		shadow_mesh.material_override = shadow_mat
		add_child(shadow_mesh)

	return {
		"card_id": "",
		"root": holder,
		"area": area,
		"shadow": shadow_mesh,
		"shadow_mat": shadow_mat,
		"base_shadow_color": base_s_col,
		"playable": false,
		"check": {},
		"bar_mat": bar_mat,
		"card_canvas": card_canvas
	}

func _compute_footer_state(idx: int, playable: bool, check: Dictionary, previewing_shift: bool, preview_g_name: String, in_redline: bool, c_play: Color, c_sel: Color, c_red: Color) -> Dictionary:
	var cur_playable: bool = bool(engine.can_play_card(idx, false).get("playable", false)) if previewing_shift else playable
	var f_txt: String = ""
	var f_col: Color = c_play
	var newly_unlocked: bool = previewing_shift and playable and not cur_playable
	if previewing_shift and not playable and cur_playable:
		f_txt = repo.get_ui_text("hud", "card_lock_preview_fmt") % preview_g_name
		f_col = c_red
	elif not playable:
		f_txt = str(check.get("reason", ""))
		f_col = c_red
	elif newly_unlocked:
		f_txt = repo.get_ui_text("hud", "card_unlock_preview_fmt") % preview_g_name
		f_col = c_sel
	elif in_redline:
		f_txt = repo.get_ui_text("hud", "card_redline_footer")
		f_col = c_red
	var highlighted: bool = newly_unlocked or (idx == hovered_hand_index and playable)
	return {"text": f_txt, "color": f_col, "highlighted": highlighted}

func _refresh_hand_in_place() -> void:
	if repo == null or engine == null or engine.mode != CombatEngine.MODE_COMBAT:
		return
	if card_nodes.size() != engine.hand.size():
		_rebuild_hand()
		return
	var c_playable: Color = repo.get_palette_color("playable_glow")
	var c_sel: Color = repo.get_palette_color("selected_glow")
	var c_redline: Color = repo.get_palette_color("redline_glow")
	var c_disabled: Color = repo.get_palette_color("disabled_tint")
	var eval_gear: int = engine.effective_gear()
	var previewing_shift: bool = (eval_gear != engine.current_gear)
	var preview_g_name: String = engine.transmission.gear_short_name(eval_gear) if previewing_shift else ""
	var in_red: bool = engine.transmission.is_redline(eval_gear, engine.rpm_units)

	for i: int in range(engine.hand.size()):
		var cid: String = engine.hand[i]
		var card: Dictionary = repo.get_card(cid)
		var check: Dictionary = engine.can_play_card(i)
		var playable: bool = bool(check.get("playable", false))
		var entry: Dictionary = card_nodes[i]
		entry["card_id"] = cid
		entry["playable"] = playable
		entry["check"] = check
		var area: Area3D = entry.get("area") as Area3D
		if area != null:
			area.set_meta("hand_index", i)
		var bar_mat: StandardMaterial3D = entry.get("bar_mat") as StandardMaterial3D
		if bar_mat != null:
			bar_mat.albedo_color = (c_redline if (playable and in_red) else c_playable) if playable else c_disabled
		var f_state: Dictionary = _compute_footer_state(i, playable, check, previewing_shift, preview_g_name, in_red, c_playable, c_sel, c_redline)
		var c_canvas: CardEmblemCanvas = entry.get("card_canvas") as CardEmblemCanvas
		if c_canvas != null and is_instance_valid(c_canvas):
			c_canvas.configure_full_card(
				repo,
				engine,
				card,
				"",
				playable,
				str(f_state["text"]),
				f_state["color"] as Color,
				bool(f_state["highlighted"])
			)

func _rebuild_hand() -> void:
	if selected_hand_index >= engine.hand.size():
		selected_hand_index = -1
	if hovered_hand_index >= engine.hand.size():
		hovered_hand_index = -1
	if dragged_hand_index >= engine.hand.size():
		dragged_hand_index = -1

	if engine.mode != CombatEngine.MODE_COMBAT:
		_clear_all_card_nodes()
		return

	var prev_poses: Array[Dictionary] = []
	for entry: Dictionary in card_nodes:
		var root_n: Node3D = entry.get("root") as Node3D
		if root_n != null and is_instance_valid(root_n):
			prev_poses.append({
				"card_id": str(entry.get("card_id", "")),
				"pos": root_n.position,
				"rot": root_n.rotation_degrees,
				"scale": root_n.scale.x,
				"used": false
			})

	var is_new_turn_draw: bool = (engine.turn_number != last_turn_seen)
	last_turn_seen = engine.turn_number

	var needed: int = engine.hand.size()
	if needed > slot_pool.size():
		var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
		var frame_scene: PackedScene = repo.load_model_scene("card_frame_3d")
		while slot_pool.size() < needed:
			slot_pool.append(_create_card_slot_entry(hcfg, frame_scene))

	card_nodes.clear()
	for idx: int in range(slot_pool.size()):
		var slot: Dictionary = slot_pool[idx]
		if idx < needed:
			_set_slot_active(slot, true)
			card_nodes.append(slot)
		else:
			slot["card_id"] = ""
			_set_slot_active(slot, false)

	for i: int in range(needed):
		var cid: String = engine.hand[i]
		var holder: Node3D = card_nodes[i].get("root") as Node3D
		var matched_prev: int = -1
		if not is_new_turn_draw:
			for pi: int in range(prev_poses.size()):
				if not bool(prev_poses[pi]["used"]) and str(prev_poses[pi]["card_id"]) == cid:
					matched_prev = pi
					prev_poses[pi]["used"] = true
					break
		if matched_prev >= 0:
			holder.position = prev_poses[matched_prev]["pos"] as Vector3
			holder.rotation_degrees = prev_poses[matched_prev]["rot"] as Vector3
			holder.scale = Vector3.ONE * float(prev_poses[matched_prev]["scale"])
		else:
			holder.position = Vector3(0.46, 0.14 - float(i) * 0.015, -0.26 - float(i) * 0.012)
			holder.rotation_degrees = Vector3(-38.0, -22.0, -24.0 + float(i) * 5.0)
			holder.scale = Vector3.ONE * 0.30

	_refresh_hand_in_place()

func _init_recyclable_discard_slot(hcfg: Dictionary) -> void:
	var vp_sz: Vector2 = JsonConfigLoader.to_vec2(hcfg.get("card_viewport", []), Vector2(340.0, 488.0))
	var w_sz: Vector2 = JsonConfigLoader.to_vec2(hcfg.get("card_screen_size_m", []), Vector2(0.156, 0.224))
	var frame_scl: Vector3 = JsonConfigLoader.to_vec3(hcfg.get("card_frame_scale", []), Vector3(1.27, 1.28, 1.0))

	var fx_holder: Node3D = Node3D.new()
	fx_holder.visible = false
	add_child(fx_holder)

	var frame_scene: PackedScene = repo.load_model_scene("card_frame_3d")
	if frame_scene != null:
		var f_inst: Node3D = frame_scene.instantiate() as Node3D
		f_inst.scale = frame_scl
		fx_holder.add_child(f_inst)

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		fx_holder,
		Vector2i(int(vp_sz.x), int(vp_sz.y)),
		w_sz,
		Vector3(0.0, -0.002, 0.0075),
		Vector3.ZERO,
		false,
		true
	)
	var card_canvas: CardEmblemCanvas = CardEmblemCanvas.new()
	card_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(scr["root"] as Control).add_child(card_canvas)
	DiegeticScreenFactory.set_screen_enabled(card_canvas, false)

	discard_fx_slot = {
		"node": fx_holder,
		"canvas": card_canvas,
		"active": false,
		"start_pos": Vector3.ZERO,
		"target_pos": Vector3(0.48, 0.22, -0.32),
		"elapsed": 0.0,
		"duration": 0.28
	}

func _on_card_played_fx(card_data: Dictionary, _target_index: int) -> void:
	if repo == null or engine == null or discard_fx_slot.is_empty():
		return
	var fx_holder: Node3D = discard_fx_slot.get("node") as Node3D
	var fx_canvas: CardEmblemCanvas = discard_fx_slot.get("canvas") as CardEmblemCanvas
	if fx_holder == null or fx_canvas == null:
		return
	fx_holder.position = last_interaction_pos
	fx_holder.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	fx_holder.scale = Vector3.ONE * 1.12
	fx_holder.visible = true
	DiegeticScreenFactory.set_screen_enabled(fx_canvas, true)
	fx_canvas.configure_full_card(repo, engine, card_data, "", true, "", repo.get_palette_color("playable_glow"), false)
	discard_fx_slot["active"] = true
	discard_fx_slot["start_pos"] = last_interaction_pos
	discard_fx_slot["elapsed"] = 0.0

func _refresh_card_footers() -> void:
	if repo == null or engine == null:
		return
	var c_play: Color = repo.get_palette_color("playable_glow")
	var c_sel: Color = repo.get_palette_color("selected_glow")
	var c_red: Color = repo.get_palette_color("redline_glow")
	var eval_gear: int = engine.effective_gear()
	var previewing_shift: bool = (eval_gear != engine.current_gear)
	var preview_g_name: String = engine.transmission.gear_short_name(eval_gear) if previewing_shift else ""
	var in_redline: bool = engine.transmission.is_redline(eval_gear, engine.rpm_units)

	for i: int in range(card_nodes.size()):
		var entry: Dictionary = card_nodes[i]
		var c_canvas: CardEmblemCanvas = entry.get("card_canvas") as CardEmblemCanvas
		if c_canvas == null or not is_instance_valid(c_canvas):
			continue
		var playable: bool = bool(entry.get("playable", false))
		var check: Dictionary = entry.get("check", {}) as Dictionary
		var f_state: Dictionary = _compute_footer_state(i, playable, check, previewing_shift, preview_g_name, in_redline, c_play, c_sel, c_red)
		c_canvas.update_footer(str(f_state["text"]), f_state["color"] as Color, bool(f_state["highlighted"]))

func _compute_slot_transform(idx: int, count: int, playable: bool, is_hovered: bool, is_selected: bool, is_dragged: bool) -> Dictionary:
	var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
	var arc_w: float = float(hcfg.get("arc_width", 0.78))
	var spacing_x: float = float(hcfg.get("card_spacing_x", 0.162))
	var arc_curve: float = float(hcfg.get("arc_depth_curve", 0.014))
	var fan_deg: float = float(hcfg.get("fan_angle_deg", 7.0))
	var base_tilt: float = float(hcfg.get("base_tilt_deg", -16.0))
	var hover_tilt: float = float(hcfg.get("hover_tilt_deg", -14.0))

	var x_pos: float = 0.0
	var y_pos: float = 0.0
	var z_pos: float = float(idx) * 0.0025
	var roll_deg: float = 0.0
	var yaw_deg: float = 0.0

	if count > 1:
		var span: float = minf(arc_w, float(count - 1) * spacing_x)
		var half: float = span * 0.5
		var ratio: float = float(idx) / float(count - 1)
		var t_norm: float = ratio * 2.0 - 1.0
		x_pos = lerpf(-half, half, ratio)
		y_pos = -absf(t_norm) * arc_curve
		z_pos += (1.0 - t_norm * t_norm) * float(hcfg.get("arc_forward_curve_z", 0.014))
		roll_deg = -t_norm * fan_deg * 0.5
		yaw_deg = -t_norm * float(hcfg.get("fan_yaw_deg", 4.5))

	if playable:
		y_pos += float(hcfg.get("compatible_lift_y", 0.018))
	else:
		y_pos += float(hcfg.get("incompatible_drop_y", -0.016))

	var scl: float = float(hcfg.get("normal_scale", 1.0))
	var rot_vec: Vector3 = Vector3(base_tilt, yaw_deg, roll_deg)

	if is_dragged:
		var drag_dy: float = maxf(0.0, -drag_visual_delta_px.y)
		var drag_t: float = clampf(drag_dy / 220.0, 0.0, 1.0)
		var bezier_lift: float = sin(drag_t * PI * 0.5) * float(hcfg.get("drag_bezier_lift_y", 0.016))
		var bezier_z: float = drag_t * float(hcfg.get("drag_bezier_forward_z", 0.012))
		x_pos += clampf(drag_visual_delta_px.x * 0.00018, -0.045, 0.045)
		y_pos += float(hcfg.get("drag_lift_y", 0.022)) + bezier_lift
		z_pos += float(hcfg.get("drag_forward_z", 0.018)) + bezier_z
		scl = float(hcfg.get("drag_scale", 0.94))
		var bank_roll: float = clampf(-drag_visual_delta_px.x * float(hcfg.get("drag_bank_roll_factor", 0.022)), -9.0, 9.0)
		var bank_yaw: float = clampf(drag_visual_delta_px.x * float(hcfg.get("drag_yaw_factor", 0.015)), -6.0, 6.0)
		var target_pitch: float = lerpf(hover_tilt, float(hcfg.get("drag_target_pitch_deg", -24.0)), drag_t)
		rot_vec = Vector3(target_pitch, bank_yaw, bank_roll)
	elif is_selected:
		y_pos += float(hcfg.get("selected_lift_y", 0.082))
		z_pos += float(hcfg.get("selected_forward_z", 0.070))
		scl = float(hcfg.get("selected_scale", 1.25))
		rot_vec = Vector3(hover_tilt, 0.0, 0.0)
	elif is_hovered:
		y_pos += float(hcfg.get("hover_lift_y", 0.068))
		z_pos += float(hcfg.get("selected_forward_z", 0.058))
		scl = float(hcfg.get("hover_scale", 1.22))
		rot_vec = Vector3(hover_tilt, 0.0, 0.0)

	return {"pos": Vector3(x_pos, y_pos, z_pos), "rot": rot_vec, "scale": scl}

func _process(delta: float) -> void:
	if repo == null:
		return
	var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
	var smooth: float = clampf(delta * float(hcfg.get("smoothing_speed", 14.0)), 0.0, 1.0)
	var c_sel: Color = repo.get_palette_color("selected_glow")
	var c_play: Color = repo.get_palette_color("playable_glow")
	var c_dis: Color = repo.get_palette_color("disabled_tint")

	var base_anchor: Vector3 = JsonConfigLoader.to_vec3(hcfg.get("anchor_pos", []), Vector3(-0.215, 0.690, -0.292))
	var hand_active: bool = hovered_hand_index >= 0 or selected_hand_index >= 0 or dragged_hand_index >= 0
	var target_anchor: Vector3 = base_anchor if hand_active else (base_anchor + Vector3(0.0, -0.026, 0.0))
	position = position.lerp(target_anchor, smooth)

	if bool(discard_fx_slot.get("active", false)):
		var fx_node: Node3D = discard_fx_slot.get("node") as Node3D
		var fx_canvas: CardEmblemCanvas = discard_fx_slot.get("canvas") as CardEmblemCanvas
		if fx_node != null and is_instance_valid(fx_node):
			var el: float = float(discard_fx_slot.get("elapsed", 0.0)) + delta
			var dur: float = maxf(0.05, float(discard_fx_slot.get("duration", 0.28)))
			discard_fx_slot["elapsed"] = el
			var t: float = clampf(el / dur, 0.0, 1.0)
			var ease_t: float = 1.0 - pow(1.0 - t, 3.0)
			var p0: Vector3 = discard_fx_slot["start_pos"] as Vector3
			var p2: Vector3 = discard_fx_slot["target_pos"] as Vector3
			var arc_lift: Vector3 = Vector3(0.0, sin(t * PI) * 0.08, 0.0)
			fx_node.position = p0.lerp(p2, ease_t) + arc_lift
			fx_node.rotation_degrees = Vector3(lerpf(-12.0, -48.0, ease_t), lerpf(0.0, -24.0, ease_t), lerpf(0.0, 18.0, ease_t))
			fx_node.scale = Vector3.ONE * lerpf(1.12, 0.22, ease_t)
			if t >= 1.0:
				fx_node.visible = false
				discard_fx_slot["active"] = false
				DiegeticScreenFactory.set_screen_enabled(fx_canvas, false)

	if card_nodes.is_empty():
		return

	var total: int = card_nodes.size()
	for i: int in range(total):
		var entry: Dictionary = card_nodes[i]
		var holder: Node3D = entry.get("root") as Node3D
		if holder == null or not is_instance_valid(holder):
			continue
		var playable: bool = bool(entry.get("playable", false))
		var is_hov: bool = (i == hovered_hand_index) and dragged_hand_index < 0
		var is_sel: bool = (i == selected_hand_index)
		var is_drg: bool = (i == dragged_hand_index)
		var tf: Dictionary = _compute_slot_transform(i, total, playable, is_hov, is_sel, is_drg)
		holder.position = holder.position.lerp(tf["pos"] as Vector3, smooth)
		holder.rotation_degrees = holder.rotation_degrees.lerp(tf["rot"] as Vector3, smooth)
		holder.scale = holder.scale.lerp(Vector3.ONE * float(tf["scale"]), smooth)

		var bmat: StandardMaterial3D = entry.get("bar_mat") as StandardMaterial3D
		if bmat != null:
			bmat.albedo_color = c_sel if (is_sel or is_drg) else (c_play if playable else c_dis)

		var shadow_m: MeshInstance3D = entry.get("shadow") as MeshInstance3D
		var shadow_mat: StandardMaterial3D = entry.get("shadow_mat") as StandardMaterial3D
		if shadow_m != null and is_instance_valid(shadow_m) and shadow_mat != null:
			var s_plane_y: float = float(hcfg.get("card_shadow_plane_y", -0.065))
			var s_pos: Vector3 = Vector3(holder.position.x, s_plane_y, holder.position.z + 0.016)
			shadow_m.position = shadow_m.position.lerp(s_pos, smooth)
			shadow_m.rotation_degrees.y = holder.rotation_degrees.y
			var lift: float = maxf(0.0, holder.position.y - s_plane_y - 0.05)
			var fade_k: float = float(hcfg.get("card_shadow_lift_fade", 3.8))
			var spread_k: float = float(hcfg.get("card_shadow_lift_spread", 0.95))
			var alpha_factor: float = clampf(1.0 - lift * fade_k, 0.12, 1.0)
			var base_col: Color = entry.get("base_shadow_color", Color(0.015, 0.018, 0.024, 0.58))
			shadow_mat.albedo_color = Color(base_col.r, base_col.g, base_col.b, base_col.a * alpha_factor)
			shadow_m.scale = Vector3.ONE * (1.0 + lift * spread_k)
