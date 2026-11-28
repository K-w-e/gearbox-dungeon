class_name DungeonArena3D
extends Node3D

const COLLISION_LAYER_ENEMIES: int = 8
const POOL_ENEMY_SLOTS: int = 4
const POOL_FLOAT_LABELS: int = 16

var repo: GameRepository
var engine: CombatEngine

var tunnel_root: Node3D
var segments: Array[Node3D] = []
var enemies_root: Node3D
var enemy_slot_pool: Array[Dictionary] = []
var enemy_visuals: Array[Dictionary] = []
var label_pool: Array[Label3D] = []
var label_cursor: int = 0
var shared_ring_mesh: CylinderMesh
var shared_ring_mat: StandardMaterial3D
var plate_pulse_accum: float = 0.0

var scroll_offset: float = 0.0
var smoothed_tunnel_speed: float = 0.0
var arena_lunge_z: float = 0.0
var hovered_enemy_index: int = -1
var targeting_active: bool = false
var preview_card_hand_index: int = -1
var time_accum: float = 0.0
var floating_labels: Array[Dictionary] = []
var suppress_straight_tunnel: bool = false

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine

	tunnel_root = Node3D.new()
	add_child(tunnel_root)
	enemies_root = Node3D.new()
	add_child(enemies_root)

	_build_tunnel_segments()
	_init_enemy_and_label_pools()

	engine.state_changed.connect(_sync_enemies)
	engine.card_played_fx.connect(_on_card_played_fx)
	engine.enemy_hit_fx.connect(_on_enemy_hit_fx)
	engine.player_hit_fx.connect(_on_player_hit_fx)
	engine.enemy_action_started.connect(_on_enemy_action_started)
	engine.floating_text_requested.connect(_on_floating_text_requested)
	_sync_enemies()

func set_straight_tunnel_suppressed(suppressed: bool) -> void:
	suppress_straight_tunnel = suppressed
	if tunnel_root != null:
		tunnel_root.visible = not suppress_straight_tunnel

func set_hovered_enemy(index: int, is_targeting: bool, card_hand_index: int = -1) -> void:
	if hovered_enemy_index == index and targeting_active == is_targeting and preview_card_hand_index == card_hand_index:
		return
	hovered_enemy_index = index
	targeting_active = is_targeting
	preview_card_hand_index = card_hand_index
	_update_enemy_plates()

func describe_enemy_hover(enemy_index: int) -> String:
	if enemy_index < 0 or enemy_index >= engine.enemies.size():
		return ""
	var enemy: Dictionary = engine.enemies[enemy_index]
	if not bool(enemy.get("alive", false)):
		return ""
	return repo.get_ui_text("combat", "enemy_hover_fmt") % [
		str(enemy.get("name", "")).to_upper(),
		int(enemy.get("hp", 0)),
		int(enemy.get("max_hp", 0)),
		int(enemy.get("block", 0)),
		engine.format_enemy_intent_summary(enemy)
	]

func _build_tunnel_segments() -> void:
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var seg_count: int = maxi(3, int(dcfg.get("segment_count", 6)))
	var seg_len: float = maxf(2.0, float(dcfg.get("segment_length", 6.0)))
	var road_y: float = float(dcfg.get("road_y", -0.08))
	var start_z: float = float(dcfg.get("start_z", 2.0))
	var seg_scene: PackedScene = repo.load_model_scene("dungeon_segment")
	if seg_scene == null:
		return

	for i: int in range(seg_count):
		var inst: Node3D = seg_scene.instantiate() as Node3D
		inst.position = Vector3(0.0, road_y, start_z - float(i) * seg_len)
		tunnel_root.add_child(inst)
		segments.append(inst)

func _init_enemy_and_label_pools() -> void:
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var plate_vp: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("enemy_plate_viewport", []), Vector2(560.0, 190.0))
	var plate_w: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("enemy_plate_size_m", []), Vector2(1.88, 0.62))

	shared_ring_mesh = CylinderMesh.new()
	shared_ring_mesh.top_radius = 0.82
	shared_ring_mesh.bottom_radius = 0.82
	shared_ring_mesh.height = 0.03
	shared_ring_mat = StandardMaterial3D.new()
	shared_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shared_ring_mat.albedo_color = repo.get_palette_color("selected_glow")

	enemy_slot_pool.clear()
	for i: int in range(POOL_ENEMY_SLOTS):
		enemy_slot_pool.append(_create_pooled_enemy_slot(i, plate_vp, plate_w))

	label_pool.clear()
	for _i: int in range(POOL_FLOAT_LABELS):
		var lbl: Label3D = Label3D.new()
		DiegeticScreenFactory.style_label_3d(lbl, repo, "display", 56, 16, 0.0022, Color.WHITE)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.visible = false
		add_child(lbl)
		label_pool.append(lbl)

func _create_pooled_enemy_slot(slot_idx: int, plate_vp: Vector2, plate_w: Vector2) -> Dictionary:
	var holder: Node3D = Node3D.new()
	holder.visible = false
	enemies_root.add_child(holder)

	var model_holder: Node3D = Node3D.new()
	holder.add_child(model_holder)

	var area: Area3D = Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 0
	area.monitoring = false
	area.set_meta("interact_type", "enemy_target")
	area.set_meta("enemy_index", slot_idx)
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.3, 1.3, 1.2)
	cs.shape = box
	area.add_child(cs)
	holder.add_child(area)

	var ring_mesh: MeshInstance3D = MeshInstance3D.new()
	ring_mesh.mesh = shared_ring_mesh
	ring_mesh.position = Vector3(0.0, 0.04, 0.0)
	ring_mesh.material_override = shared_ring_mat
	ring_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring_mesh.visible = false
	holder.add_child(ring_mesh)

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		holder,
		Vector2i(int(plate_vp.x), int(plate_vp.y)),
		plate_w,
		Vector3(0.0, 1.60, 0.42),
		Vector3.ZERO,
		true,
		true
	)
	var plate_mesh: MeshInstance3D = scr["mesh"] as MeshInstance3D
	var plate_canvas: _EnemyReticleCanvas = _EnemyReticleCanvas.new()
	plate_canvas.arena = self
	plate_canvas.enemy_idx = slot_idx
	plate_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(scr["root"] as Control).add_child(plate_canvas)
	DiegeticScreenFactory.set_screen_enabled(plate_canvas, false)

	return {
		"id": "",
		"root": holder,
		"model": model_holder,
		"area": area,
		"box": box,
		"plate_mesh": plate_mesh,
		"plate_canvas": plate_canvas,
		"ring": ring_mesh,
		"base_pos": Vector3.ZERO,
		"bob_amp": 0.0,
		"bob_speed": 0.0,
		"recoil_z": 0.0
	}

func _sync_enemies() -> void:
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var road_y: float = float(dcfg.get("road_y", -0.08))
	var plate_vp: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("enemy_plate_viewport", []), Vector2(560.0, 190.0))
	var plate_w: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("enemy_plate_size_m", []), Vector2(1.88, 0.62))

	var needed: int = engine.enemies.size()
	while enemy_slot_pool.size() < needed:
		enemy_slot_pool.append(_create_pooled_enemy_slot(enemy_slot_pool.size(), plate_vp, plate_w))

	enemy_visuals.clear()
	for i: int in range(enemy_slot_pool.size()):
		var slot: Dictionary = enemy_slot_pool[i]
		var holder: Node3D = slot["root"] as Node3D
		var area: Area3D = slot["area"] as Area3D
		var pc: _EnemyReticleCanvas = slot["plate_canvas"] as _EnemyReticleCanvas
		if i >= needed:
			holder.visible = false
			area.collision_layer = 0
			DiegeticScreenFactory.set_screen_enabled(pc, false)
			continue

		var edata: Dictionary = engine.enemies[i]
		var eid: String = str(edata.get("id", ""))
		var tmpl: Dictionary = repo.get_enemy(eid)
		var base_pos: Vector3 = Vector3(float(edata.get("lane_x", 0.0)), road_y, float(edata.get("distance_z", -5.8)))
		holder.position = base_pos
		slot["base_pos"] = base_pos
		area.set_meta("enemy_index", i)
		area.position = Vector3(0.0, float(tmpl.get("collider_center_y", 0.8)), 0.0)
		(slot["box"] as BoxShape3D).size = JsonConfigLoader.to_vec3(tmpl.get("collider_size", []), Vector3(1.3, 1.3, 1.2))
		var label_y: float = maxf(1.48, float(tmpl.get("label_height", 1.72)) - 0.12)
		(slot["plate_mesh"] as MeshInstance3D).position = Vector3(0.0, label_y, 0.42)
		pc.enemy_idx = i
		slot["bob_amp"] = float(tmpl.get("hover_bob_amp", 0.0))
		slot["bob_speed"] = float(tmpl.get("hover_bob_speed", 0.0))

		if str(slot.get("id", "")) != eid:
			slot["id"] = eid
			slot["recoil_z"] = 0.0
			var model_holder: Node3D = slot["model"] as Node3D
			for ch: Node in model_holder.get_children():
				model_holder.remove_child(ch)
				ch.queue_free()
			var mpath: String = str(tmpl.get("model_path", ""))
			if not mpath.is_empty():
				var mscene: PackedScene = repo.load_model_scene(mpath)
				if mscene != null:
					model_holder.add_child(mscene.instantiate())

		enemy_visuals.append(slot)

	_update_enemy_plates()

func _update_enemy_plates() -> void:
	for i: int in range(mini(enemy_visuals.size(), engine.enemies.size())):
		var vis: Dictionary = enemy_visuals[i]
		var edata: Dictionary = engine.enemies[i]
		var holder: Node3D = vis.get("root") as Node3D
		if holder == null or not is_instance_valid(holder):
			continue
		var alive: bool = bool(edata.get("alive", false))
		holder.visible = alive
		var area: Area3D = vis.get("area") as Area3D
		if area != null:
			area.collision_layer = COLLISION_LAYER_ENEMIES if alive else 0
		var pc: _EnemyReticleCanvas = vis.get("plate_canvas") as _EnemyReticleCanvas
		if pc != null and is_instance_valid(pc):
			var vis_active: bool = alive and (
				engine.mode == CombatEngine.MODE_COMBAT
				or engine.mode == CombatEngine.MODE_ENEMY_TURN
				or engine.mode == CombatEngine.MODE_SHIFT_CHOICE
			)
			DiegeticScreenFactory.set_screen_enabled(pc, vis_active)
			if vis_active:
				DiegeticScreenFactory.request_redraw(pc)

func get_enemy_world_position(idx: int) -> Vector3:
	if idx >= 0 and idx < enemy_visuals.size():
		var vis: Dictionary = enemy_visuals[idx]
		var root_node: Node3D = vis.get("root") as Node3D
		if root_node != null and is_instance_valid(root_node):
			return root_node.global_position + Vector3(0.0, 0.75, 0.0)
	return Vector3(0.0, 0.8, -5.8)

func trigger_enemy_hit_impact(idx: int) -> void:
	if idx >= 0 and idx < enemy_visuals.size():
		enemy_visuals[idx]["recoil_z"] = -0.38

func _on_card_played_fx(card_data: Dictionary, _target_index: int) -> void:
	if bool(card_data.get("is_ram", false)):
		var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
		arena_lunge_z = float(dcfg.get("chassis_lunge_distance", 0.45))

func _on_enemy_hit_fx(enemy_index: int, amount: int, blocked: bool) -> void:
	if enemy_index >= 0 and enemy_index < enemy_visuals.size():
		enemy_visuals[enemy_index]["recoil_z"] = -0.36
	var pos: Vector3 = get_enemy_world_position(enemy_index) + Vector3(0.0, 0.55, 0.35)
	if blocked:
		spawn_floating_text(pos, repo.get_ui_text("combat", "float_blocked_fmt") % amount, repo.get_palette_color("kw_shield"), 1.0)
	else:
		spawn_floating_text(pos, repo.get_ui_text("combat", "float_hp_fmt") % amount, repo.get_palette_color("enemy_hp"), 1.25)

func _on_player_hit_fx(amount: int, is_overheat: bool) -> void:
	var txt: String = (repo.get_ui_text("combat", "float_overheat_fmt") % amount) if is_overheat else (repo.get_ui_text("combat", "float_hull_fmt") % amount)
	var col: Color = repo.get_palette_color("kw_heat_up") if is_overheat else repo.get_palette_color("redline_glow")
	spawn_floating_text(Vector3(0.0, 1.24, -2.85), txt, col, 1.15)

func _on_enemy_action_started(enemy_index: int, move_name: String) -> void:
	if enemy_index >= 0 and enemy_index < enemy_visuals.size():
		enemy_visuals[enemy_index]["recoil_z"] = 0.54
	var pos: Vector3 = get_enemy_world_position(enemy_index) + Vector3(0.0, 0.85, 0.35)
	spawn_floating_text(pos, move_name.to_upper(), repo.get_palette_color("enemy_intent"), 1.05)
	_update_enemy_plates()

func _on_floating_text_requested(target_enemy_index: int, text: String, color: Color) -> void:
	var pos: Vector3 = get_enemy_world_position(target_enemy_index) + Vector3(0.0, 0.65, 0.35) if target_enemy_index >= 0 else Vector3(0.0, 1.28, -2.95)
	spawn_floating_text(pos, text, color, 1.05)

func spawn_floating_text(world_pos: Vector3, text: String, color: Color, scale_mult: float = 1.0) -> void:
	if label_pool.is_empty():
		return
	var lbl: Label3D = label_pool[label_cursor]
	label_cursor = (label_cursor + 1) % label_pool.size()
	for idx: int in range(floating_labels.size() - 1, -1, -1):
		if floating_labels[idx].get("node") == lbl:
			floating_labels.remove_at(idx)
			break
	lbl.text = text
	lbl.scale = Vector3.ONE * scale_mult
	lbl.modulate = color
	lbl.outline_modulate = repo.get_outline_color()
	var jitter_x: float = (randf() - 0.5) * 0.28
	lbl.position = world_pos + Vector3(jitter_x, 0.0, 0.0)
	lbl.visible = true
	floating_labels.append({
		"node": lbl,
		"age": 0.0,
		"lifetime": 0.88,
		"base_color": color
	})

func _preview_card_pulses_enemy() -> bool:
	if preview_card_hand_index < 0 or preview_card_hand_index >= engine.hand.size():
		return false
	if not bool(engine.can_play_card(preview_card_hand_index).get("playable", false)):
		return false
	var p_card: Dictionary = repo.get_card(engine.hand[preview_card_hand_index])
	return int(engine.calculate_card_preview(p_card).get("damage", 0)) > 0

func _process(delta: float) -> void:
	if repo == null or engine == null:
		return
	time_accum += delta
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var seg_len: float = maxf(2.0, float(dcfg.get("segment_length", 6.0)))
	var start_z: float = float(dcfg.get("start_z", 2.0))
	var road_y: float = float(dcfg.get("road_y", -0.08))
	var rpm_factor: float = float(dcfg.get("rpm_speed_factor", 0.18))

	var g_dict: Dictionary = repo.get_gear(engine.current_gear)
	var base_speed: float = float(g_dict.get("tunnel_speed", 0.0))
	var rpm_scale: float = 0.25 + float(engine.rpm_units) * rpm_factor
	if engine.rpm_units == 0 and engine.current_gear != 0:
		rpm_scale = 0.0
	var target_speed: float = base_speed * rpm_scale
	if engine.mode == CombatEngine.MODE_WORKSHOP or engine.mode == CombatEngine.MODE_ROUTE_CHOICE or engine.is_site_mode():
		target_speed = 0.0

	if tunnel_root != null:
		tunnel_root.visible = not suppress_straight_tunnel
	if enemies_root != null:
		enemies_root.visible = (
			engine.mode == CombatEngine.MODE_COMBAT
			or engine.mode == CombatEngine.MODE_ENEMY_TURN
			or engine.mode == CombatEngine.MODE_SHIFT_CHOICE
		)

	smoothed_tunnel_speed = lerpf(smoothed_tunnel_speed, target_speed, clampf(delta * 4.5, 0.0, 1.0))
	scroll_offset = fposmod(scroll_offset + smoothed_tunnel_speed * delta, seg_len)

	for i: int in range(segments.size()):
		var seg_node: Node3D = segments[i]
		if seg_node != null:
			seg_node.position = Vector3(0.0, road_y, start_z + scroll_offset - float(i) * seg_len)

	arena_lunge_z = lerpf(arena_lunge_z, 0.0, clampf(delta * 7.5, 0.0, 1.0))
	enemies_root.position.z = arena_lunge_z

	var pulse_preview: bool = _preview_card_pulses_enemy()
	var trigger_pulse_redraw: bool = false
	if pulse_preview or engine.active_acting_enemy_index >= 0:
		plate_pulse_accum += delta
		if plate_pulse_accum >= 0.055:
			plate_pulse_accum = 0.0
			trigger_pulse_redraw = true
	else:
		plate_pulse_accum = 0.0

	for i: int in range(enemy_visuals.size()):
		var vis: Dictionary = enemy_visuals[i]
		var model_h: Node3D = vis.get("model") as Node3D
		var ring: MeshInstance3D = vis.get("ring") as MeshInstance3D
		if model_h == null or not is_instance_valid(model_h):
			continue
		var recoil: float = lerpf(float(vis.get("recoil_z", 0.0)), 0.0, clampf(delta * 9.0, 0.0, 1.0))
		vis["recoil_z"] = recoil
		var bob: float = sin(time_accum * float(vis.get("bob_speed", 0.0)) + float(i)) * float(vis.get("bob_amp", 0.0))
		model_h.position = Vector3(0.0, bob, recoil)
		if ring != null:
			ring.visible = (i == hovered_enemy_index) or targeting_active or (i == engine.active_acting_enemy_index)
		if trigger_pulse_redraw and (pulse_preview or i == engine.active_acting_enemy_index):
			var pc_anim: _EnemyReticleCanvas = vis.get("plate_canvas") as _EnemyReticleCanvas
			if pc_anim != null and is_instance_valid(pc_anim):
				DiegeticScreenFactory.request_redraw(pc_anim)

	for idx_f: int in range(floating_labels.size() - 1, -1, -1):
		var item: Dictionary = floating_labels[idx_f]
		var lbl_n: Label3D = item.get("node") as Label3D
		if lbl_n == null or not is_instance_valid(lbl_n):
			floating_labels.remove_at(idx_f)
			continue
		var age: float = float(item.get("age", 0.0)) + delta
		var life: float = maxf(0.1, float(item.get("lifetime", 0.85)))
		if age >= life:
			lbl_n.visible = false
			floating_labels.remove_at(idx_f)
			continue
		item["age"] = age
		lbl_n.position.y += delta * 0.68
		var t: float = age / life
		var bcol: Color = item.get("base_color", repo.get_palette_color("mfd_text")) as Color
		var ocol: Color = repo.get_outline_color()
		var alpha: float = clampf(1.0 - maxf(0.0, (t - 0.55) / 0.45), 0.0, 1.0)
		lbl_n.modulate = Color(bcol.r, bcol.g, bcol.b, alpha)
		lbl_n.outline_modulate = Color(ocol.r, ocol.g, ocol.b, alpha * ocol.a)


class _EnemyReticleCanvas extends Control:
	var arena: DungeonArena3D
	var enemy_idx: int = 0

	func _draw() -> void:
		if arena == null or arena.repo == null or arena.engine == null:
			return
		if enemy_idx < 0 or enemy_idx >= arena.engine.enemies.size():
			return
		var edata: Dictionary = arena.engine.enemies[enemy_idx]
		if not bool(edata.get("alive", false)):
			return

		var sz: Vector2 = size
		var rep: GameRepository = arena.repo
		var eng: CombatEngine = arena.engine
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var intent: Dictionary = eng.get_enemy_intent(edata)
		var is_hov: bool = (enemy_idx == arena.hovered_enemy_index)
		var is_acting: bool = (enemy_idx == eng.active_acting_enemy_index)

		var rim_col: Color = rep.get_palette_color("redline_glow") if is_acting else (rep.get_palette_color("playable_glow") if (is_hov and arena.targeting_active) else (rep.get_palette_color("selected_glow") if is_hov else rep.get_palette_color("mfd_border")))
		var plate_r: Rect2 = Rect2(6.0, 6.0, sz.x - 12.0, sz.y - 12.0)
		DiegeticScreenFactory.draw_industrial_plate(self, plate_r, rep, rim_col, 14.0, 3.2 if (is_hov or is_acting) else 2.2, true, 0.0, false)

		var med_c: Vector2 = Vector2(68.0, sz.y * 0.52)
		var med_r: float = 45.0
		var itype: String = str(intent.get("type", "attack"))
		var is_heal: bool = (itype == "heal" or itype == "heal_all")
		var is_def: bool = (itype == "defend" or itype == "defend_all" or itype == "boss_wall" or itype == "buff")
		var icol: Color = rep.get_palette_color("playable_glow") if is_heal else (rep.get_palette_color("kw_shield") if is_def else rep.get_palette_color("kw_damage"))

		if is_heal:
			CardEmblemCanvas._s_draw_shield_shape(self, med_c, med_r, icol, Color(icol.r, icol.g, icol.b, 0.25))
			var heal_r: Vector2i = eng.intent_range(intent, "heal")
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, med_c + Vector2(-40.0, 10.0), "+%s" % eng.format_range_value(heal_r), HORIZONTAL_ALIGNMENT_CENTER, 80.0, 25, txt_col, out_col, 4, 13)
		elif is_def:
			CardEmblemCanvas._s_draw_shield_shape(self, med_c, med_r, icol, Color(icol.r, icol.g, icol.b, 0.25))
			var blk_r: Vector2i = eng.intent_range(intent, "block")
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, med_c + Vector2(-40.0, 10.0), "+%s" % eng.format_range_value(blk_r), HORIZONTAL_ALIGNMENT_CENTER, 80.0, 25, txt_col, out_col, 4, 13)
		else:
			var spikes: int = 10
			var star_pts: PackedVector2Array = PackedVector2Array()
			for s: int in range(spikes * 2):
				var ang: float = (TAU * float(s)) / float(spikes * 2) - PI * 0.5
				var rad: float = med_r * (1.04 if (s % 2 == 0) else 0.72)
				star_pts.append(med_c + Vector2(cos(ang), sin(ang)) * rad)
			draw_colored_polygon(star_pts, Color(icol.r * 0.24, icol.g * 0.14, icol.b * 0.10, 0.96))
			star_pts.append(star_pts[0])
			draw_polyline(star_pts, icol, 2.6, true)

			var dmg_r: Vector2i = eng.effective_enemy_damage_range(edata, intent)
			var hits: int = maxi(1, int(intent.get("hits", 1)))
			var d_str: String = ("%sx%d" % [eng.format_range_value(dmg_r), hits]) if hits > 1 else eng.format_range_value(dmg_r)
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, med_c + Vector2(-42.0, 10.0), d_str, HORIZONTAL_ALIGNMENT_CENTER, 84.0, 24, txt_col, out_col, 4, 12)

		var rx: float = 128.0
		var rw: float = sz.x - rx - 18.0
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rx, 38.0), str(edata.get("name", "")).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, rw - 156.0, 26, txt_col, out_col, 3, 15)

		var hp_cur: int = int(edata.get("hp", 0))
		var hp_max: int = maxi(1, int(edata.get("max_hp", 1)))

		var hp_loss: int = 0
		var blocked_dmg: int = 0
		var is_reflected: bool = false
		var total_incoming: int = 0
		if arena.preview_card_hand_index >= 0 and arena.preview_card_hand_index < eng.hand.size():
			var p_check: Dictionary = eng.can_play_card(arena.preview_card_hand_index)
			if bool(p_check.get("playable", false)):
				var p_card: Dictionary = rep.get_card(eng.hand[arena.preview_card_hand_index])
				var t_type: String = str(p_card.get("target_type", "self"))
				var hits_this_enemy: bool = (t_type == "all_enemies") or (t_type == "single_enemy" and (enemy_idx == arena.hovered_enemy_index or (arena.hovered_enemy_index < 0 and eng.alive_enemy_count() == 1 and enemy_idx == eng.first_alive_enemy_index())))
				if hits_this_enemy:
					var c_prev: Dictionary = eng.calculate_card_preview(p_card)
					var single_d: int = int(c_prev.get("damage", 0))
					var hit_c: int = maxi(1, int(c_prev.get("hits", 1)))
					if single_d > 0:
						if int(edata.get("vulnerable", 0)) > 0:
							var v_mult: float = float(rep.gameplay().get("vulnerable_damage_multiplier", 1.5))
							single_d = int(round(float(single_d) * v_mult))
						total_incoming = single_d * hit_c
						if bool(edata.get("reflect_high_gear", false)) and eng.current_gear > int(edata.get("max_safe_gear", 2)):
							is_reflected = true
						else:
							blocked_dmg = mini(int(edata.get("block", 0)), total_incoming)
							hp_loss = mini(hp_cur, maxi(0, total_incoming - blocked_dmg))

		var hp_after: int = maxi(0, hp_cur - hp_loss)
		var pulse: float = 0.5 + 0.5 * sin(arena.time_accum * 13.0)
		var hp_str: String = rep.get_ui_text("combat", "plate_hp_fmt") % [hp_cur, hp_max]
		var e_hp_col: Color = rep.get_palette_color("enemy_hp")
		var hp_txt_col: Color = e_hp_col.lightened(0.24)
		if is_reflected:
			hp_str = rep.get_ui_text("combat", "plate_reflects_fmt") % total_incoming
			hp_txt_col = rep.get_palette_color("redline_glow").lerp(txt_col, pulse)
		elif hp_loss >= hp_cur and hp_cur > 0:
			hp_str = rep.get_ui_text("combat", "plate_lethal_fmt") % hp_loss
			hp_txt_col = rep.get_palette_color("playable_glow").lerp(txt_col, pulse)
		elif hp_loss > 0:
			hp_str = rep.get_ui_text("combat", "plate_dmg_preview_fmt") % [hp_cur, hp_after, hp_loss]
			hp_txt_col = rep.get_palette_color("selected_glow").lerp(txt_col, pulse * 0.6)
		elif blocked_dmg > 0:
			hp_str = rep.get_ui_text("combat", "plate_shield_dmg_fmt") % blocked_dmg
			hp_txt_col = rep.get_palette_color("kw_shield")

		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(sz.x - 168.0, 38.0), hp_str, HORIZONTAL_ALIGNMENT_RIGHT, 148.0, 23, hp_txt_col, out_col, 3, 14)

		var segs: int = 12
		var seg_w: float = (rw - float(segs - 1) * 4.0) / float(segs)
		var hp_ratio: float = clampf(float(hp_cur) / float(hp_max), 0.0, 1.0)
		var hp_after_ratio: float = clampf(float(hp_after) / float(hp_max), 0.0, 1.0)
		var bar_y: float = 48.0
		var sel_col: Color = rep.get_palette_color("selected_glow")
		for s: int in range(segs):
			var seg_frac: float = float(s) / float(segs)
			var lit: bool = seg_frac < hp_ratio and hp_cur > 0
			var is_dmg_seg: bool = lit and (hp_loss > 0) and (seg_frac >= hp_after_ratio or hp_after == 0)
			var sx_i: float = rx + float(s) * (seg_w + 4.0)
			var poly: PackedVector2Array = PackedVector2Array([
				Vector2(sx_i + 4.0, bar_y),
				Vector2(sx_i + seg_w, bar_y),
				Vector2(sx_i + seg_w - 4.0, bar_y + 18.0),
				Vector2(sx_i, bar_y + 18.0)
			])
			var fill_c: Color = Color(e_hp_col.r, e_hp_col.g, e_hp_col.b, 0.94 if lit else 0.18)
			var brd_c: Color = e_hp_col.lightened(0.22) * (0.85 if lit else 0.45)
			if is_dmg_seg:
				fill_c = Color(sel_col.r, sel_col.g, sel_col.b, 0.42 + 0.56 * pulse)
				brd_c = txt_col
			draw_colored_polygon(poly, fill_c)
			draw_polyline(poly, brd_c, 1.8 if is_dmg_seg else 1.2, true)

		var tags: PackedStringArray = PackedStringArray()
		if int(edata.get("block", 0)) > 0:
			tags.append(rep.get_ui_text("combat", "tag_shield_fmt") % int(edata.get("block", 0)))
		if int(edata.get("weakness", 0)) > 0:
			tags.append(rep.get_ui_text("combat", "tag_weak_fmt") % int(edata.get("weakness", 0)))
		if int(edata.get("vulnerable", 0)) > 0:
			tags.append(rep.get_ui_text("combat", "tag_vuln_fmt") % int(edata.get("vulnerable", 0)))
		if bool(edata.get("reflect_high_gear", false)):
			var safe_g: String = eng.transmission.gear_short_name(int(edata.get("max_safe_gear", 2)))
			tags.append(rep.get_ui_text("combat", "tag_reflect_fmt") % safe_g)
		if not tags.is_empty():
			DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rx, 88.0), "  •  ".join(tags), HORIZONTAL_ALIGNMENT_LEFT, rw, 20, rep.get_palette_color("kw_shield").lightened(0.18), out_col, 3, 14)

		var move_y: float = 114.0 if not tags.is_empty() else 96.0
		var move_txt: String = eng.format_enemy_intent_summary(edata)
		var intent_col: Color = rep.get_palette_color("enemy_intent").lightened(0.18)
		draw_multiline_string_outline(
			f_body,
			Vector2(rx, move_y),
			move_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			rw,
			22,
			3,
			3,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(rx, move_y),
			move_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			rw,
			22,
			3,
			intent_col
		)
