class_name EncounterSite3DController
extends Node3D

signal site_choice_selected(choice_index: int)

const COLLISION_LAYER_SITE_DEFAULT: int = 64

var repo: GameRepository
var engine: CombatEngine

var diorama_holder: Node3D
var elite_holder: Node3D
var ui_holder: Node3D
var vfx_holder: Node3D

var site_models: Dictionary = {}
var active_model_key: String = ""
var site_accent_light: OmniLight3D

var elite_arena_inst: Node3D
var elite_flame_l: Node3D
var elite_flame_r: Node3D
var elite_strobe_l: Node3D
var elite_strobe_r: Node3D

var header_canvas: _SiteHeaderCanvas
var choice_canvases: Array[_SiteChoiceCanvas] = []
var choice_areas: Array[Area3D] = []

var particle_pool: Array[Dictionary] = []
var particle_cursor: int = 0
var shared_unit_sphere: SphereMesh
var active_particles: Array[Dictionary] = []
var approach_timer: float = 0.0
var is_approaching: bool = false
var hovered_choice_index: int = -1
var fx_timer: float = 0.0
var hammer_prev_phase: float = 0.0
var time_accum: float = 0.0

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	if repository == null or combat_engine == null:
		push_error("EncounterSite3DController.initialize received null dependencies")
		return
	repo = repository
	engine = combat_engine

	diorama_holder = Node3D.new()
	diorama_holder.name = "SiteDioramaHolder"
	add_child(diorama_holder)

	elite_holder = Node3D.new()
	elite_holder.name = "EliteArenaHolder"
	add_child(elite_holder)

	ui_holder = Node3D.new()
	ui_holder.name = "SiteDiegeticUIHolder"
	add_child(ui_holder)

	vfx_holder = Node3D.new()
	vfx_holder.name = "SiteVfxHolder"
	add_child(vfx_holder)

	_init_particle_pool()
	_build_site_dioramas()
	_build_elite_arena()
	_build_diegetic_ui()

	engine.encounter_site_opened.connect(_on_encounter_site_opened)
	engine.state_changed.connect(_sync_state)
	_sync_state()

func get_site_collision_layer() -> int:
	if repo == null:
		return COLLISION_LAYER_SITE_DEFAULT
	var scfg: Dictionary = repo.cockpit.get("encounter_site_3d", {}) as Dictionary
	return maxi(1, int(scfg.get("collision_layer", COLLISION_LAYER_SITE_DEFAULT)))

func set_hovered_choice(idx: int) -> void:
	var clean_idx: int = idx if (idx >= 0 and idx < choice_canvases.size()) else -1
	if hovered_choice_index == clean_idx:
		return
	hovered_choice_index = clean_idx
	_refresh_ui_canvases()

func describe_choice_hover(idx: int) -> String:
	if repo == null or engine == null or not engine.is_site_mode():
		return ""
	var choices: Array = engine.active_site_data.get("choices", []) as Array
	if idx < 0 or idx >= choices.size() or typeof(choices[idx]) != TYPE_DICTIONARY:
		return ""
	var ch: Dictionary = choices[idx] as Dictionary
	var eval: Dictionary = engine.evaluate_site_choice(idx)
	var label_str: String = str(ch.get("label", ""))
	var hint_str: String = str(ch.get("outcome_hint", ""))
	if not bool(eval.get("allowed", false)):
		hint_str = "%s (%s)" % [hint_str, str(eval.get("reason", ""))]
	return repo.get_ui_text("sites", "choice_hover_fmt") % [idx + 1, label_str, hint_str]

func trigger_choice(idx: int) -> bool:
	if engine == null or not engine.is_site_mode() or not engine.site_selecting_deck_action.is_empty():
		return false
	var ok: bool = engine.execute_site_choice(idx)
	if ok:
		site_choice_selected.emit(idx)
	_refresh_ui_canvases()
	return ok

func _build_site_dioramas() -> void:
	site_models.clear()
	var model_keys: Array[String] = [
		"node_rest_shelter",
		"node_upgrade_forge",
		"node_event_ruined_road",
		"node_event_convoy",
		"node_event_monolith",
		"node_event_toxic_spill"
	]
	for mkey: String in model_keys:
		var scene: PackedScene = repo.load_model_scene(mkey)
		if scene == null:
			continue
		var inst: Node3D = scene.instantiate() as Node3D
		inst.visible = false
		diorama_holder.add_child(inst)
		var entry: Dictionary = {"root": inst}
		match mkey:
			"node_rest_shelter":
				var arm_l: Node3D = inst.find_child("ShelterArmL", true, false) as Node3D
				var arm_r: Node3D = inst.find_child("ShelterArmR", true, false) as Node3D
				entry["arm_l"] = arm_l
				entry["arm_r"] = arm_r
				entry["base_rot_l"] = arm_l.rotation_degrees if arm_l != null else Vector3.ZERO
				entry["base_rot_r"] = arm_r.rotation_degrees if arm_r != null else Vector3.ZERO
				entry["fire_glow"] = inst.find_child("ShelterFireGlow", true, false) as Node3D
			"node_upgrade_forge":
				entry["roller_front"] = inst.find_child("DynoRollerFront", true, false) as Node3D
				entry["roller_rear"] = inst.find_child("DynoRollerRear", true, false) as Node3D
				var ham: Node3D = inst.find_child("ForgeHammer", true, false) as Node3D
				entry["hammer"] = ham
				entry["hammer_base_y"] = ham.position.y if ham != null else 2.32
			"node_event_ruined_road":
				entry["chasm_glow"] = inst.find_child("ChasmGlowCore", true, false) as Node3D
			"node_event_convoy":
				entry["beacon"] = inst.find_child("ConvoyBeacon", true, false) as Node3D
				entry["smoke_nozzle"] = inst.find_child("ConvoySmokeNozzle", true, false) as Node3D
			"node_event_monolith":
				entry["holo_ring"] = inst.find_child("MonolithHoloRing", true, false) as Node3D
				var claw_l: Node3D = inst.find_child("ServoClawL", true, false) as Node3D
				var claw_r: Node3D = inst.find_child("ServoClawR", true, false) as Node3D
				entry["claw_l"] = claw_l
				entry["claw_r"] = claw_r
				entry["claw_rot_l"] = claw_l.rotation_degrees if claw_l != null else Vector3.ZERO
				entry["claw_rot_r"] = claw_r.rotation_degrees if claw_r != null else Vector3.ZERO
			"node_event_toxic_spill":
				entry["fan_blades"] = inst.find_child("DeconFanBlades", true, false) as Node3D
				entry["stream"] = inst.find_child("ToxicStream", true, false) as Node3D
		site_models[mkey] = entry

	site_accent_light = OmniLight3D.new()
	site_accent_light.position = Vector3(0.0, 1.85, 0.65)
	site_accent_light.light_energy = 2.2
	site_accent_light.omni_range = 7.5
	diorama_holder.add_child(site_accent_light)

func _build_elite_arena() -> void:
	var scfg: Dictionary = repo.cockpit.get("encounter_site_3d", {}) as Dictionary
	var road_y: float = float(scfg.get("road_y", -0.08))
	var elite_z: float = float(scfg.get("elite_arena_z", -6.10))
	elite_holder.position = Vector3(0.0, road_y, elite_z)
	elite_holder.visible = false

	var elite_scene: PackedScene = repo.load_model_scene("node_elite_arena")
	if elite_scene == null:
		return
	elite_arena_inst = elite_scene.instantiate() as Node3D
	elite_holder.add_child(elite_arena_inst)
	elite_flame_l = elite_arena_inst.find_child("EliteFlameL", true, false) as Node3D
	elite_flame_r = elite_arena_inst.find_child("EliteFlameR", true, false) as Node3D
	elite_strobe_l = elite_arena_inst.find_child("EliteStrobeL", true, false) as Node3D
	elite_strobe_r = elite_arena_inst.find_child("EliteStrobeR", true, false) as Node3D

func _build_diegetic_ui() -> void:
	choice_canvases.clear()
	choice_areas.clear()
	var scfg: Dictionary = repo.cockpit.get("encounter_site_3d", {}) as Dictionary

	var road_y: float = float(scfg.get("road_y", -0.08))
	var b_pad: float = float(scfg.get("bezel_pad_m", 0.028))
	var b_depth: float = float(scfg.get("bezel_depth_m", 0.048))
	var st_rad: float = float(scfg.get("stanchion_radius_m", 0.032))
	var bezel_col: Color = repo.get_palette_color("bezel_metal")
	var trim_col: Color = repo.get_palette_color("bezel_trim")

	var hdr_pos: Vector3 = JsonConfigLoader.to_vec3(scfg.get("header_pos", []), Vector3(0.0, 1.84, -3.45))
	var hdr_rot: Vector3 = JsonConfigLoader.to_vec3(scfg.get("header_rot_deg", []), Vector3(8.0, 0.0, 0.0))
	var hdr_sz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("header_size_m", []), Vector2(2.76, 0.58))
	var hdr_vp: Vector2 = JsonConfigLoader.to_vec2(scfg.get("header_viewport", []), Vector2(760.0, 160.0))

	var hdr_anchor: Node3D = Node3D.new()
	hdr_anchor.position = hdr_pos
	hdr_anchor.rotation_degrees = hdr_rot
	ui_holder.add_child(hdr_anchor)

	DiegeticScreenFactory.create_metal_bezel(
		hdr_anchor,
		hdr_sz,
		b_pad * 1.25,
		b_depth,
		Vector3(0.0, 0.0, -b_depth * 0.54),
		Vector3.ZERO,
		bezel_col
	)
	for side_s: float in [-1.0, 1.0]:
		DiegeticScreenFactory.create_metal_strut(
			ui_holder,
			Vector3(st_rad * 1.8, 1.85, st_rad * 1.8),
			Vector3(side_s * hdr_sz.x * 0.36, hdr_pos.y + 0.92, hdr_pos.z - b_depth * 0.65),
			Vector3.ZERO,
			bezel_col
		)

	var hdr_scr: Dictionary = DiegeticScreenFactory.create_screen(
		hdr_anchor,
		Vector2i(int(hdr_vp.x), int(hdr_vp.y)),
		hdr_sz,
		Vector3.ZERO,
		Vector3.ZERO,
		false,
		false
	)
	header_canvas = _SiteHeaderCanvas.new()
	header_canvas.site_ctrl = self
	header_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(hdr_scr.get("root") as Control).add_child(header_canvas)

	var ch_sz: Vector2 = JsonConfigLoader.to_vec2(scfg.get("choice_size_m", []), Vector2(1.10, 0.50))
	var ch_vp: Vector2 = JsonConfigLoader.to_vec2(scfg.get("choice_viewport", []), Vector2(400.0, 182.0))
	var ch_depth: float = maxf(0.04, float(scfg.get("choice_collider_depth", 0.16)))
	var slots: Array = scfg.get("choice_slots", []) as Array

	for i: int in range(slots.size()):
		if typeof(slots[i]) != TYPE_DICTIONARY:
			continue
		var slot_cfg: Dictionary = slots[i] as Dictionary
		var s_pos: Vector3 = JsonConfigLoader.to_vec3(slot_cfg.get("pos", []), Vector3.ZERO)
		var s_rot: Vector3 = JsonConfigLoader.to_vec3(slot_cfg.get("rot_deg", []), Vector3.ZERO)

		var pod_anchor: Node3D = Node3D.new()
		pod_anchor.position = s_pos
		pod_anchor.rotation_degrees = s_rot
		ui_holder.add_child(pod_anchor)

		DiegeticScreenFactory.create_metal_bezel(
			pod_anchor,
			ch_sz,
			b_pad,
			b_depth,
			Vector3(0.0, 0.0, -b_depth * 0.54),
			Vector3.ZERO,
			bezel_col
		)
		var post_top_y: float = s_pos.y - ch_sz.y * 0.44
		var post_h: float = maxf(0.2, post_top_y - road_y)
		DiegeticScreenFactory.create_metal_strut(
			ui_holder,
			Vector3(st_rad * 2.0, post_h, st_rad * 2.0),
			Vector3(s_pos.x, road_y + post_h * 0.5, s_pos.z - b_depth * 0.7),
			Vector3.ZERO,
			bezel_col
		)
		DiegeticScreenFactory.create_metal_strut(
			ui_holder,
			Vector3(st_rad * 5.2, 0.05, st_rad * 5.2),
			Vector3(s_pos.x, road_y + 0.025, s_pos.z - b_depth * 0.7),
			Vector3.ZERO,
			trim_col.darkened(0.45)
		)

		var pod_scr: Dictionary = DiegeticScreenFactory.create_screen(
			pod_anchor,
			Vector2i(int(ch_vp.x), int(ch_vp.y)),
			ch_sz,
			Vector3.ZERO,
			Vector3.ZERO,
			false,
			false
		)
		var c_canvas: _SiteChoiceCanvas = _SiteChoiceCanvas.new()
		c_canvas.site_ctrl = self
		c_canvas.choice_idx = i
		c_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		(pod_scr.get("root") as Control).add_child(c_canvas)
		choice_canvases.append(c_canvas)

		var area: Area3D = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 0
		area.set_meta("interact_type", "encounter_site_choice")
		area.set_meta("choice_index", i)
		var cs: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		box.size = Vector3(ch_sz.x * 1.08, ch_sz.y * 1.14, ch_depth)
		cs.shape = box
		area.add_child(cs)
		pod_anchor.add_child(area)
		choice_areas.append(area)

func _on_encounter_site_opened(site_data: Dictionary) -> void:
	var scfg: Dictionary = repo.cockpit.get("encounter_site_3d", {}) as Dictionary
	var road_y: float = float(scfg.get("road_y", -0.08))
	var start_z: float = float(scfg.get("approach_start_z", -19.5))
	active_model_key = str(site_data.get("model_key", ""))
	for mkey: Variant in site_models.keys():
		var m_entry: Dictionary = site_models[mkey] as Dictionary
		var root_n: Node3D = m_entry.get("root") as Node3D
		if root_n != null:
			root_n.visible = (str(mkey) == active_model_key)

	var pal_key: String = str(site_data.get("palette_key", "node_event"))
	if site_accent_light != null:
		site_accent_light.light_color = repo.get_palette_color(pal_key)

	approach_timer = 0.0
	is_approaching = true
	hovered_choice_index = -1
	diorama_holder.position = Vector3(0.0, road_y, start_z)
	_sync_state()

func _sync_state() -> void:
	if engine == null or repo == null:
		return
	var in_site: bool = engine.is_site_mode()
	diorama_holder.visible = in_site
	var show_boards: bool = in_site and engine.site_selecting_deck_action.is_empty()
	ui_holder.visible = show_boards

	var choices: Array = engine.active_site_data.get("choices", []) as Array
	var active_layer: int = get_site_collision_layer() if show_boards else 0
	for i: int in range(choice_areas.size()):
		var area: Area3D = choice_areas[i]
		if area != null and is_instance_valid(area):
			area.collision_layer = active_layer if i < choices.size() else 0
		if i < choice_canvases.size() and choice_canvases[i] != null:
			var pod_node: Node3D = choice_canvases[i].get_parent().get_parent().get_parent() as Node3D
			if pod_node != null:
				pod_node.visible = (i < choices.size())

	var in_combat: bool = (engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ENEMY_TURN or engine.mode == CombatEngine.MODE_SHIFT_CHOICE)
	var is_elite_enc: bool = bool(engine.current_encounter().get("is_elite", false))
	elite_holder.visible = in_combat and is_elite_enc

	if header_canvas != null and is_instance_valid(header_canvas):
		DiegeticScreenFactory.set_screen_enabled(header_canvas, show_boards)
	for i: int in range(choice_canvases.size()):
		if choice_canvases[i] != null and is_instance_valid(choice_canvases[i]):
			DiegeticScreenFactory.set_screen_enabled(choice_canvases[i], show_boards and i < choices.size())

	if not show_boards:
		hovered_choice_index = -1
	else:
		_refresh_ui_canvases()

func _refresh_ui_canvases() -> void:
	if header_canvas != null and is_instance_valid(header_canvas):
		DiegeticScreenFactory.request_redraw(header_canvas)
	for c: _SiteChoiceCanvas in choice_canvases:
		if c != null and is_instance_valid(c):
			DiegeticScreenFactory.request_redraw(c)

func _process(delta: float) -> void:
	if repo == null or engine == null:
		return
	time_accum += delta
	var scfg: Dictionary = repo.cockpit.get("encounter_site_3d", {}) as Dictionary

	if diorama_holder.visible:
		if is_approaching:
			var dur: float = maxf(0.1, float(scfg.get("approach_duration_s", 0.72)))
			var start_z: float = float(scfg.get("approach_start_z", -19.5))
			var stop_z: float = float(scfg.get("stop_z", -6.15))
			var road_y: float = float(scfg.get("road_y", -0.08))
			approach_timer += delta
			var t: float = clampf(approach_timer / dur, 0.0, 1.0)
			var eased: float = 1.0 - pow(1.0 - t, 3.0)
			diorama_holder.position = Vector3(0.0, road_y, lerpf(start_z, stop_z, eased))
			if t >= 1.0:
				is_approaching = false
		_animate_active_site_model(delta, scfg)

	if elite_holder.visible:
		_animate_elite_arena(delta, scfg)

	_update_particles(delta)

func _animate_active_site_model(delta: float, scfg: Dictionary) -> void:
	if not site_models.has(active_model_key):
		return
	var entry: Dictionary = site_models[active_model_key] as Dictionary
	var fx_int: float = maxf(0.12, float(scfg.get("fx_interval_s", 0.36)))
	fx_timer += delta
	var spark_col: Color = repo.get_palette_color("selected_glow")
	var hazard_col: Color = repo.get_palette_color("slot_grind")
	var muted_col: Color = repo.get_palette_color("mfd_muted")
	var play_col: Color = repo.get_palette_color("playable_glow")

	match active_model_key:
		"node_rest_shelter":
			var sway: float = float(scfg.get("shelter_arm_sway_deg", 12.0))
			var spd: float = float(scfg.get("shelter_arm_speed", 2.1))
			var arm_l: Node3D = entry.get("arm_l") as Node3D
			var arm_r: Node3D = entry.get("arm_r") as Node3D
			if arm_l != null:
				arm_l.rotation_degrees = (entry.get("base_rot_l") as Vector3) + Vector3(0.0, 0.0, sin(time_accum * spd) * sway)
			if arm_r != null:
				arm_r.rotation_degrees = (entry.get("base_rot_r") as Vector3) + Vector3(0.0, 0.0, -cos(time_accum * spd * 0.9) * sway)
			var fire: Node3D = entry.get("fire_glow") as Node3D
			if fire != null:
				var f_scl: float = 0.92 + 0.14 * sin(time_accum * 9.0)
				fire.scale = Vector3(1.0, f_scl, 1.0)
				if fx_timer >= fx_int:
					fx_timer = 0.0
					_spawn_particle(fire.global_position, Vector3(0.0, 1.3, 0.0), Color(spark_col.r, spark_col.g, spark_col.b, 0.85), 0.55, 0.05)

		"node_upgrade_forge":
			var r_spd: float = float(scfg.get("forge_roller_deg_per_sec", 220.0))
			var rf: Node3D = entry.get("roller_front") as Node3D
			var rr: Node3D = entry.get("roller_rear") as Node3D
			if rf != null:
				rf.rotation_degrees.x = fmod(rf.rotation_degrees.x + r_spd * delta, 360.0)
			if rr != null:
				rr.rotation_degrees.x = fmod(rr.rotation_degrees.x + r_spd * delta, 360.0)
			var ham: Node3D = entry.get("hammer") as Node3D
			if ham != null:
				var h_spd: float = float(scfg.get("forge_hammer_speed", 3.4))
				var stroke: float = float(scfg.get("forge_hammer_stroke_m", 0.44))
				var wave: float = absf(sin(time_accum * h_spd))
				ham.position.y = float(entry.get("hammer_base_y", 2.32)) - (1.0 - wave) * stroke
				if wave < 0.14 and hammer_prev_phase >= 0.14:
					if engine != null and engine.mode == CombatEngine.MODE_UPGRADE:
						engine.sfx_requested.emit("forge_anvil", 0.44)
					var hit_pos: Vector3 = ham.global_position + Vector3(0.0, -1.05, 0.0)
					for k: int in range(4):
						var ang: float = float(k) * 1.57 + time_accum
						_spawn_particle(hit_pos, Vector3(cos(ang) * 1.9, 1.4, sin(ang) * 1.9), Color(spark_col.r, spark_col.g, spark_col.b, 0.95), 0.30, 0.04, 7.0)
				hammer_prev_phase = wave

		"node_event_ruined_road":
			var cg: Node3D = entry.get("chasm_glow") as Node3D
			if cg != null and fx_timer >= fx_int:
				fx_timer = 0.0
				var rx: float = sin(time_accum * 7.3) * 1.2
				_spawn_particle(cg.global_position + Vector3(rx, 0.1, 0.0), Vector3(0.0, 1.6, 0.0), Color(hazard_col.r, hazard_col.g, hazard_col.b, 0.9), 0.50, 0.045)

		"node_event_convoy":
			var bcn: Node3D = entry.get("beacon") as Node3D
			if bcn != null:
				var b_spd: float = float(scfg.get("convoy_beacon_deg_per_sec", 240.0))
				bcn.rotation_degrees.y = fmod(bcn.rotation_degrees.y + b_spd * delta, 360.0)
			var snoz: Node3D = entry.get("smoke_nozzle") as Node3D
			if snoz != null and fx_timer >= fx_int:
				fx_timer = 0.0
				_spawn_particle(snoz.global_position, Vector3(0.15, 1.1, 0.0), Color(muted_col.r * 0.5, muted_col.g * 0.5, muted_col.b * 0.5, 0.52), 0.85, 0.12, 0.0, 2.2)

		"node_event_monolith":
			var ring: Node3D = entry.get("holo_ring") as Node3D
			if ring != null:
				var ring_spd: float = float(scfg.get("monolith_ring_deg_per_sec", 68.0))
				ring.rotation_degrees.y = fmod(ring.rotation_degrees.y + ring_spd * delta, 360.0)
			var c_sway: float = float(scfg.get("monolith_claw_sway_deg", 10.5))
			var cl: Node3D = entry.get("claw_l") as Node3D
			var cr: Node3D = entry.get("claw_r") as Node3D
			if cl != null:
				cl.rotation_degrees = (entry.get("claw_rot_l") as Vector3) + Vector3(sin(time_accum * 2.4) * c_sway * 0.5, cos(time_accum * 1.9) * c_sway, 0.0)
			if cr != null:
				cr.rotation_degrees = (entry.get("claw_rot_r") as Vector3) + Vector3(cos(time_accum * 2.4) * c_sway * 0.5, -sin(time_accum * 1.9) * c_sway, 0.0)

		"node_event_toxic_spill":
			var fan: Node3D = entry.get("fan_blades") as Node3D
			if fan != null:
				var f_spd: float = float(scfg.get("decon_fan_deg_per_sec", 320.0))
				fan.rotation_degrees.z = fmod(fan.rotation_degrees.z + f_spd * delta, 360.0)
			var stream_n: Node3D = entry.get("stream") as Node3D
			if stream_n != null:
				var pulse_w: float = 0.92 + 0.12 * sin(time_accum * 8.0)
				stream_n.scale = Vector3(pulse_w, 1.0, pulse_w)
				if fx_timer >= fx_int:
					fx_timer = 0.0
					var bx: float = cos(time_accum * 5.1) * 1.1
					_spawn_particle(diorama_holder.global_position + Vector3(bx, 0.12, 0.2), Vector3(0.0, 0.95, 0.0), Color(play_col.r, play_col.g, play_col.b, 0.78), 0.62, 0.075, 0.0, 1.6)

func _animate_elite_arena(delta: float, scfg: Dictionary) -> void:
	var strobe_spd: float = float(scfg.get("elite_strobe_deg_per_sec", 260.0))
	var flame_spd: float = float(scfg.get("elite_flame_pulse_speed", 7.5))
	if elite_strobe_l != null:
		elite_strobe_l.rotation_degrees.y = fmod(elite_strobe_l.rotation_degrees.y + strobe_spd * delta, 360.0)
	if elite_strobe_r != null:
		elite_strobe_r.rotation_degrees.y = fmod(elite_strobe_r.rotation_degrees.y - strobe_spd * delta, 360.0)
	var fl_s: float = 0.88 + 0.20 * (0.5 + 0.5 * sin(time_accum * flame_spd))
	var fr_s: float = 0.88 + 0.20 * (0.5 + 0.5 * cos(time_accum * flame_spd * 1.1))
	if elite_flame_l != null:
		elite_flame_l.scale = Vector3(1.0, fl_s, 1.0)
	if elite_flame_r != null:
		elite_flame_r.scale = Vector3(1.0, fr_s, 1.0)

func _init_particle_pool() -> void:
	shared_unit_sphere = SphereMesh.new()
	shared_unit_sphere.radius = 1.0
	shared_unit_sphere.height = 2.0
	shared_unit_sphere.radial_segments = 10
	shared_unit_sphere.rings = 5
	particle_pool.clear()
	for _i: int in range(18):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_unit_sphere
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = mat
		mi.visible = false
		vfx_holder.add_child(mi)
		particle_pool.append({"node": mi, "mat": mat})

func _spawn_particle(
	world_pos: Vector3,
	vel: Vector3,
	col: Color,
	life: float,
	radius: float,
	gravity: float = 0.0,
	grow: float = 1.0
) -> void:
	if particle_pool.is_empty():
		return
	var slot: Dictionary = particle_pool[particle_cursor]
	particle_cursor = (particle_cursor + 1) % particle_pool.size()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
	for idx: int in range(active_particles.size() - 1, -1, -1):
		if active_particles[idx].get("node") == mi:
			active_particles.remove_at(idx)
			break
	mi.position = world_pos
	mi.scale = Vector3.ONE * radius
	mat.albedo_color = col
	mi.visible = true
	active_particles.append({
		"node": mi,
		"mat": mat,
		"vel": vel,
		"age": 0.0,
		"life": life,
		"base_radius": radius,
		"gravity": gravity,
		"grow": grow,
		"base_alpha": col.a
	})

func _update_particles(delta: float) -> void:
	for idx: int in range(active_particles.size() - 1, -1, -1):
		var p: Dictionary = active_particles[idx]
		var node: MeshInstance3D = p.get("node") as MeshInstance3D
		if node == null or not is_instance_valid(node):
			active_particles.remove_at(idx)
			continue
		var age: float = float(p.get("age", 0.0)) + delta
		var life: float = maxf(0.05, float(p.get("life", 0.5)))
		if age >= life:
			node.visible = false
			active_particles.remove_at(idx)
			continue
		p["age"] = age
		var vel: Vector3 = p.get("vel", Vector3.ZERO) as Vector3
		var grav: float = float(p.get("gravity", 0.0))
		if grav > 0.0:
			vel.y -= grav * delta
			p["vel"] = vel
		node.position += vel * delta
		var t: float = age / life
		var base_r: float = float(p.get("base_radius", 0.05))
		node.scale = Vector3.ONE * (base_r * lerpf(1.0, float(p.get("grow", 1.0)), t))
		var mat: StandardMaterial3D = p.get("mat") as StandardMaterial3D
		if mat != null:
			var c: Color = mat.albedo_color
			c.a = float(p.get("base_alpha", 0.8)) * (1.0 - t)
			mat.albedo_color = c


class _SiteHeaderCanvas extends Control:
	var site_ctrl: EncounterSite3DController

	func _draw() -> void:
		if site_ctrl == null or site_ctrl.repo == null or site_ctrl.engine == null:
			return
		var rep: GameRepository = site_ctrl.repo
		var eng: CombatEngine = site_ctrl.engine
		if not eng.is_site_mode():
			return
		var sz: Vector2 = size
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var data: Dictionary = eng.active_site_data
		var pal_key: String = str(data.get("palette_key", "node_event"))
		var accent: Color = rep.get_palette_color(pal_key)
		var txt_col: Color = rep.get_palette_color("mfd_text")

		DiegeticScreenFactory.draw_industrial_plate(
			self,
			Rect2(4.0, 4.0, sz.x - 8.0, sz.y - 8.0),
			rep,
			accent,
			12.0,
			3.0,
			true,
			46.0,
			false
		)

		var title_str: String = str(data.get("title", "")).to_upper()
		var sub_str: String = str(data.get("subtitle", "")).to_upper()
		var desc_str: String = str(data.get("description", ""))

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(28.0, 38.0),
			title_str,
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 56.0,
			28,
			txt_col,
			out_col,
			4,
			17
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(28.0, 74.0),
			sub_str,
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 56.0,
			18,
			accent.lightened(0.24),
			out_col,
			3,
			13
		)
		draw_multiline_string_outline(
			f_body,
			Vector2(34.0, 105.0),
			desc_str,
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 68.0,
			20,
			2,
			3,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(34.0, 105.0),
			desc_str,
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 68.0,
			20,
			2,
			txt_col
		)


class _SiteChoiceCanvas extends Control:
	var site_ctrl: EncounterSite3DController
	var choice_idx: int = 0

	func _draw() -> void:
		if site_ctrl == null or site_ctrl.repo == null or site_ctrl.engine == null:
			return
		var rep: GameRepository = site_ctrl.repo
		var eng: CombatEngine = site_ctrl.engine
		if not eng.is_site_mode():
			return
		var choices: Array = eng.active_site_data.get("choices", []) as Array
		if choice_idx < 0 or choice_idx >= choices.size() or typeof(choices[choice_idx]) != TYPE_DICTIONARY:
			return

		var ch: Dictionary = choices[choice_idx] as Dictionary
		var eval: Dictionary = eng.evaluate_site_choice(choice_idx)
		var allowed: bool = bool(eval.get("allowed", false))
		var is_hov: bool = (site_ctrl.hovered_choice_index == choice_idx)
		var sz: Vector2 = size
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()

		var pal_key: String = str(eng.active_site_data.get("palette_key", "node_event"))
		var base_accent: Color = rep.get_palette_color(pal_key)
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var dis_col: Color = rep.get_palette_color("disabled_tint")
		var stroke: Color = (txt_col if is_hov else base_accent) if allowed else dis_col
		var border_w: float = 3.6 if (is_hov and allowed) else 2.4

		DiegeticScreenFactory.draw_industrial_plate(
			self,
			Rect2(4.0, 4.0, sz.x - 8.0, sz.y - 8.0),
			rep,
			stroke,
			10.0,
			border_w,
			true,
			54.0 if allowed else 0.0,
			is_hov and allowed
		)

		var key_rect: Rect2 = Rect2(14.0, 12.0, 44.0, 40.0)
		var key_bg: Color = rep.get_palette_color("mfd_panel_bg")
		DiegeticScreenFactory.draw_chamfer_rect(self, key_rect, 6.0, key_bg, stroke, 2.2)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(key_rect.position.x, key_rect.position.y + 29.0),
			str(choice_idx + 1),
			HORIZONTAL_ALIGNMENT_CENTER,
			key_rect.size.x,
			24,
			txt_col if allowed else dis_col.lightened(0.22),
			out_col,
			3,
			16
		)

		var lbl: String = str(ch.get("label", "")).to_upper()
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(68.0, 41.0),
			lbl,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 82.0,
			22,
			txt_col if allowed else dis_col.lightened(0.22),
			out_col,
			3,
			14
		)

		var hint_str: String = str(ch.get("outcome_hint", ""))
		var body_col: Color = txt_col if allowed else dis_col.lightened(0.18)
		draw_multiline_string_outline(
			f_body,
			Vector2(18.0, 86.0),
			hint_str,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 36.0,
			20,
			2,
			3,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(18.0, 86.0),
			hint_str,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 36.0,
			20,
			2,
			body_col
		)

		var pill_r: Rect2 = Rect2(16.0, sz.y - 40.0, sz.x - 32.0, 28.0)
		if not allowed:
			var lock_str: String = str(eval.get("reason", ""))
			var warn_col: Color = rep.get_palette_color("redline_glow")
			DiegeticScreenFactory.draw_chamfer_rect(self, pill_r, 5.0, Color(warn_col.r * 0.24, warn_col.g * 0.07, warn_col.b * 0.05, 0.95), warn_col, 1.8)
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(pill_r.position.x + 8.0, pill_r.position.y + 20.0),
				lock_str,
				HORIZONTAL_ALIGNMENT_CENTER,
				pill_r.size.x - 16.0,
				16,
				warn_col.lightened(0.28),
				out_col,
				2,
				11
			)
		else:
			var act_col: Color = rep.get_palette_color("selected_glow") if is_hov else base_accent
			var ready_txt: String = rep.get_ui_text("sites", "choice_ready_tag") % (choice_idx + 1)
			DiegeticScreenFactory.draw_chamfer_rect(self, pill_r, 5.0, Color(act_col.r * 0.16, act_col.g * 0.14, act_col.b * 0.08, 0.92), Color(act_col.r, act_col.g, act_col.b, 0.85), 1.6)
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_body,
				Vector2(pill_r.position.x + 8.0, pill_r.position.y + 20.0),
				ready_txt,
				HORIZONTAL_ALIGNMENT_CENTER,
				pill_r.size.x - 16.0,
				16,
				txt_col if is_hov else act_col.lightened(0.22),
				out_col,
				2,
				11
			)
