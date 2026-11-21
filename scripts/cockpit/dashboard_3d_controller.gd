class_name Dashboard3DController
extends Node3D

signal engine_audio_mute_toggled(muted: bool)
signal deck_preview_requested

const COLLISION_LAYER_COCKPIT: int = 2
const TAB_ENGINE: String = "engine"
const TAB_GEARS: String = "gears"
const TAB_DECK: String = "deck"
const TAB_GLOSSARY: String = "glossary"

var repo: GameRepository
var engine: CombatEngine

var steering_wheel: Node3D
var tacho_unit: Node3D
var rpm_needle: Node3D
var heat_needle: Node3D
var dial_gear_lbl: Label3D
var dial_heat_lbl: Label3D
var rpm_tick_labels: Array[Label3D] = []
var rpm_tick_mats: Array[StandardMaterial3D] = []
var rpm_pointer_mat: StandardMaterial3D
var heat_pointer_mat: StandardMaterial3D

var slam_base: Node3D
var slam_cap: Node3D
var slam_label: Label3D

var active_tab: String = TAB_ENGINE
var hovered_tab: String = ""
var glossary_page: int = 0
var mfd_canvas: _DashboardSynopticCanvas
var mfd_screen_mesh: MeshInstance3D
var mfd_vp_size: Vector2 = Vector2(920.0, 500.0)
var mfd_world_size: Vector2 = Vector2(0.465, 0.252)
var mfd_hotspots: Array[Dictionary] = []

var inspected_card_hand_index: int = -1
var inspected_enemy_index: int = -1

var switch_levers: Dictionary = {}
var switch_states: Dictionary = {}
var lamp_materials: Dictionary = {}

var smoothed_rpm_units: float = 2.0
var smoothed_heat_ratio: float = 0.0
var steer_impulse_deg: float = 0.0
var external_steer_deg: float = 0.0
var smoothed_external_steer_deg: float = 0.0
var slam_depress: float = 0.0
var time_accum: float = 0.0
var audio_muted: bool = false

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine
	var dcfg: Dictionary = repo.cockpit.get("dashboard", {}) as Dictionary

	_build_steering_wheel(dcfg)
	_build_tachometer_and_needles(dcfg)
	_build_mfd_panel(dcfg)
	_build_slam_button(dcfg)
	_build_switches(dcfg)
	_build_warning_lamps(dcfg)

	engine.state_changed.connect(_refresh_dashboard)
	engine.preview_gear_changed.connect(_on_preview_gear_changed)
	engine.card_played_fx.connect(_on_card_played_fx)
	engine.event_logged.connect(func(_msg: String) -> void: _refresh_mfd_content())
	_refresh_dashboard()

func _on_preview_gear_changed(_gear_idx: int) -> void:
	_refresh_dashboard()

func set_external_steer_deg(deg: float) -> void:
	external_steer_deg = deg

func set_active_tab(tab_id: String) -> void:
	if not [TAB_ENGINE, TAB_GEARS, TAB_DECK, TAB_GLOSSARY].has(tab_id):
		return
	if active_tab == tab_id:
		return
	active_tab = tab_id
	_refresh_mfd_content()

func set_hovered_tab(tab_id: String) -> void:
	if hovered_tab == tab_id:
		return
	hovered_tab = tab_id
	_refresh_mfd_content()

func set_inspected_card(hand_index: int) -> void:
	if inspected_card_hand_index == hand_index and inspected_enemy_index == -1:
		return
	inspected_card_hand_index = hand_index
	if hand_index >= 0:
		inspected_enemy_index = -1
	_refresh_mfd_content()

func set_inspected_enemy(enemy_index: int) -> void:
	if inspected_enemy_index == enemy_index:
		return
	inspected_enemy_index = enemy_index
	_refresh_mfd_content()

func clear_inspector_if_transient(pinned_hand_index: int) -> void:
	var next_card: int = pinned_hand_index
	if inspected_card_hand_index == next_card and inspected_enemy_index == -1:
		return
	inspected_card_hand_index = next_card
	inspected_enemy_index = -1
	_refresh_mfd_content()

func _build_steering_wheel(dcfg: Dictionary) -> void:
	set_steering_wheel_model("steering_wheel", dcfg)

func set_steering_wheel_model(model_key: String, dcfg_override: Dictionary = {}) -> void:
	var dcfg: Dictionary = dcfg_override if not dcfg_override.is_empty() else (repo.cockpit.get("dashboard", {}) as Dictionary)
	var wheel_scene: PackedScene = repo.load_model_scene(model_key)
	if wheel_scene == null:
		return
	if steering_wheel != null and is_instance_valid(steering_wheel):
		steering_wheel.queue_free()
	steering_wheel = wheel_scene.instantiate() as Node3D
	steering_wheel.position = JsonConfigLoader.to_vec3(dcfg.get("steering_wheel_pos", []), Vector3(-0.20, 0.575, -0.54))
	steering_wheel.rotation_degrees = JsonConfigLoader.to_vec3(dcfg.get("steering_wheel_rot_deg", []), Vector3(-24.0, 0.0, 0.0))
	add_child(steering_wheel)

func _build_tachometer_and_needles(dcfg: Dictionary) -> void:
	var tacho_scene: PackedScene = repo.load_model_scene("tachometer_unit")
	if tacho_scene != null:
		tacho_unit = tacho_scene.instantiate() as Node3D
		tacho_unit.position = JsonConfigLoader.to_vec3(dcfg.get("tachometer_pos", []), Vector3(-0.18, 0.895, -0.76))
		tacho_unit.rotation_degrees = JsonConfigLoader.to_vec3(dcfg.get("tachometer_rot_deg", []), Vector3(6.0, 0.0, 0.0))
		add_child(tacho_unit)
		_upgrade_tacho_materials()
		_build_dial_markings(dcfg)

	var needle_scene: PackedScene = repo.load_model_scene("gauge_needle")
	if needle_scene != null:
		rpm_needle = needle_scene.instantiate() as Node3D
		rpm_needle.position = JsonConfigLoader.to_vec3(dcfg.get("rpm_needle_pos", []), Vector3(-0.255, 0.895, -0.736))
		rpm_needle.scale = Vector3.ONE * float(dcfg.get("rpm_needle_scale", 1.0))
		rpm_pointer_mat = _upgrade_needle_visuals(rpm_needle, Color(1.0, 0.34, 0.16), 2.4)
		add_child(rpm_needle)

		heat_needle = needle_scene.instantiate() as Node3D
		heat_needle.position = JsonConfigLoader.to_vec3(dcfg.get("heat_needle_pos", []), Vector3(-0.075, 0.883, -0.736))
		heat_needle.scale = Vector3.ONE * float(dcfg.get("heat_needle_scale", 0.64))
		heat_pointer_mat = _upgrade_needle_visuals(heat_needle, Color(1.0, 0.72, 0.18), 2.5)
		add_child(heat_needle)

func _upgrade_tacho_materials() -> void:
	rpm_tick_mats.clear()
	if tacho_unit == null:
		return
	var dial_bg: Color = repo.get_palette_color("mfd_bg")
	var bezel_col: Color = repo.get_palette_color("bezel_metal")
	var trim_col: Color = repo.get_palette_color("bezel_trim")
	var opt_col: Color = repo.get_palette_color("playable_glow")
	var warn_col: Color = repo.get_palette_color("mfd_accent")
	var red_col: Color = repo.get_palette_color("redline_glow")

	for dial_name: String in ["MainDial", "HeatDial"]:
		var d_mesh: MeshInstance3D = tacho_unit.find_child(dial_name, true, false) as MeshInstance3D
		if d_mesh != null:
			d_mesh.position.z = 0.0015
			var d_mat: StandardMaterial3D = StandardMaterial3D.new()
			d_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			d_mat.albedo_color = Color(dial_bg.r, dial_bg.g, dial_bg.b, 1.0)
			d_mesh.material_override = d_mat

	for bezel_name: String in ["MainBezel", "HeatBezel"]:
		var b_mesh: MeshInstance3D = tacho_unit.find_child(bezel_name, true, false) as MeshInstance3D
		if b_mesh != null:
			var b_mat: StandardMaterial3D = StandardMaterial3D.new()
			b_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			b_mat.albedo_color = bezel_col.lerp(trim_col, 0.35 if bezel_name == "MainBezel" else 0.65)
			b_mesh.material_override = b_mat

	for u: int in range(9):
		var rt_mesh: MeshInstance3D = tacho_unit.find_child("RpmTick_%d" % u, true, false) as MeshInstance3D
		var rt_mat: StandardMaterial3D = StandardMaterial3D.new()
		rt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rt_mat.albedo_color = repo.get_palette_color("mfd_text")
		if rt_mesh != null:
			rt_mesh.position.z = 0.021
			rt_mesh.scale = Vector3(1.4, 1.6, 1.2)
			rt_mesh.material_override = rt_mat
		rpm_tick_mats.append(rt_mat)

	for h: int in range(6):
		var ht_mesh: MeshInstance3D = tacho_unit.find_child("HeatTick_%d" % h, true, false) as MeshInstance3D
		if ht_mesh != null:
			var ht_mat: StandardMaterial3D = StandardMaterial3D.new()
			ht_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			ht_mat.albedo_color = opt_col if h <= 1 else (warn_col if h <= 3 else red_col)
			ht_mesh.position.z = 0.021
			ht_mesh.scale = Vector3(1.4, 1.6, 1.2)
			ht_mesh.material_override = ht_mat

func _upgrade_needle_visuals(needle_node: Node3D, col: Color, width_mult: float) -> StandardMaterial3D:
	var p_mat: StandardMaterial3D = StandardMaterial3D.new()
	p_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	p_mat.albedo_color = col
	var ptr: MeshInstance3D = needle_node.find_child("NeedlePointer", true, false) as MeshInstance3D
	if ptr != null:
		ptr.scale = Vector3(1.15, width_mult, 1.5)
		ptr.position.z = 0.012
		ptr.material_override = p_mat
	var cap: MeshInstance3D = needle_node.find_child("NeedleCap", true, false) as MeshInstance3D
	if cap != null:
		var c_mat: StandardMaterial3D = StandardMaterial3D.new()
		c_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		c_mat.albedo_color = repo.get_palette_color("bezel_metal")
		cap.position.z = 0.010
		cap.scale = Vector3(1.15, 1.15, 1.15)
		cap.material_override = c_mat
	return p_mat

func _build_dial_markings(dcfg: Dictionary) -> void:
	rpm_tick_labels.clear()
	var rpm_center: Vector3 = JsonConfigLoader.to_vec3(dcfg.get("rpm_dial_center_local", []), Vector3(-0.075, 0.0, 0.019))
	var rpm_rad: float = float(dcfg.get("rpm_tick_label_radius", 0.056))
	var zero_deg: float = float(dcfg.get("rpm_angle_zero_deg", 215.0))
	var span_deg: float = float(dcfg.get("rpm_angle_span_deg", 250.0))
	var max_u: int = maxi(1, int(repo.gameplay().get("max_rpm_units", 8)))

	for u: int in range(max_u + 1):
		var ang_rad: float = deg_to_rad(zero_deg - (float(u) / float(max_u)) * span_deg)
		var tick_lbl: Label3D = Label3D.new()
		tick_lbl.text = str(u)
		DiegeticScreenFactory.style_label_3d(tick_lbl, repo, "display", 48, 13, 0.00034, repo.get_palette_color("mfd_text"))
		tick_lbl.position = rpm_center + Vector3(cos(ang_rad) * rpm_rad, sin(ang_rad) * rpm_rad, 0.005)
		tacho_unit.add_child(tick_lbl)
		rpm_tick_labels.append(tick_lbl)

	var rpm_unit_lbl: Label3D = Label3D.new()
	rpm_unit_lbl.text = repo.get_ui_text("screens", "dial_rpm_unit")
	DiegeticScreenFactory.style_label_3d(rpm_unit_lbl, repo, "display", 30, 8, 0.00020, repo.get_palette_color("mfd_muted"))
	rpm_unit_lbl.position = rpm_center + Vector3(0.0, -0.024, 0.005)
	tacho_unit.add_child(rpm_unit_lbl)

	dial_gear_lbl = Label3D.new()
	DiegeticScreenFactory.style_label_3d(dial_gear_lbl, repo, "display", 54, 14, 0.00038, repo.get_palette_color("slot_active"))
	dial_gear_lbl.position = rpm_center + Vector3(0.0, -0.052, 0.006)
	tacho_unit.add_child(dial_gear_lbl)

	var heat_center: Vector3 = JsonConfigLoader.to_vec3(dcfg.get("heat_dial_center_local", []), Vector3(0.105, -0.012, 0.019))
	var heat_title_lbl: Label3D = Label3D.new()
	heat_title_lbl.text = repo.get_ui_text("screens", "dial_heat_unit")
	DiegeticScreenFactory.style_label_3d(heat_title_lbl, repo, "display", 28, 8, 0.00018, repo.get_palette_color("mfd_accent"))
	heat_title_lbl.position = heat_center + Vector3(0.0, -0.018, 0.005)
	tacho_unit.add_child(heat_title_lbl)

	dial_heat_lbl = Label3D.new()
	DiegeticScreenFactory.style_label_3d(dial_heat_lbl, repo, "display", 44, 12, 0.00032, repo.get_palette_color("kw_heat_up"))
	dial_heat_lbl.position = heat_center + Vector3(0.0, -0.036, 0.006)
	tacho_unit.add_child(dial_heat_lbl)

func _build_mfd_panel(dcfg: Dictionary) -> void:
	var mfd_root: Node3D = Node3D.new()
	mfd_root.position = JsonConfigLoader.to_vec3(dcfg.get("mfd_pos", []), Vector3(0.255, 0.852, -0.585))
	mfd_root.rotation_degrees = JsonConfigLoader.to_vec3(dcfg.get("mfd_rot_deg", []), Vector3(-10.0, -13.0, 0.0))
	add_child(mfd_root)

	var vp_sz: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("mfd_viewport", []), Vector2(920.0, 500.0))
	var w_sz: Vector2 = JsonConfigLoader.to_vec2(dcfg.get("mfd_size_m", []), Vector2(0.465, 0.252))
	mfd_vp_size = vp_sz
	mfd_world_size = w_sz
	var b_depth: float = float(dcfg.get("mfd_bezel_depth", 0.022))

	DiegeticScreenFactory.create_metal_bezel(
		mfd_root,
		w_sz,
		0.014,
		b_depth,
		Vector3(0.0, 0.0, 0.012 - b_depth * 0.5),
		Vector3.ZERO,
		repo.get_palette_color("bezel_metal", Color(0.13, 0.15, 0.18))
	)

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		mfd_root,
		Vector2i(int(vp_sz.x), int(vp_sz.y)),
		w_sz,
		Vector3(0.0, 0.0, 0.014),
		Vector3.ZERO,
		false,
		true
	)
	mfd_screen_mesh = scr.get("mesh") as MeshInstance3D
	var root_c: Control = scr["root"] as Control

	mfd_canvas = _DashboardSynopticCanvas.new()
	mfd_canvas.ctrl = self
	mfd_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_c.add_child(mfd_canvas)

	var mfd_area: Area3D = Area3D.new()
	mfd_area.collision_layer = COLLISION_LAYER_COCKPIT
	mfd_area.collision_mask = 0
	mfd_area.position = Vector3(0.0, 0.0, 0.020)
	mfd_area.set_meta("interact_type", "mfd_screen")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(w_sz.x * 0.96, w_sz.y * 0.96, 0.024)
	cs.shape = box
	mfd_area.add_child(cs)
	mfd_root.add_child(mfd_area)

func _build_slam_button(dcfg: Dictionary) -> void:
	var slam_holder: Node3D = Node3D.new()
	slam_holder.position = JsonConfigLoader.to_vec3(dcfg.get("slam_button_pos", []), Vector3(0.765, 0.915, -0.515))
	slam_holder.rotation_degrees = JsonConfigLoader.to_vec3(dcfg.get("slam_button_rot_deg", []), Vector3(48.0, -28.0, 0.0))
	var b_scl: float = float(dcfg.get("slam_button_scale", 1.18))
	slam_holder.scale = Vector3.ONE * b_scl
	add_child(slam_holder)

	var base_scene: PackedScene = repo.load_model_scene("slam_button_base")
	if base_scene != null:
		slam_base = base_scene.instantiate() as Node3D
		slam_holder.add_child(slam_base)

	var cap_scene: PackedScene = repo.load_model_scene("slam_button_cap")
	if cap_scene != null:
		slam_cap = cap_scene.instantiate() as Node3D
		slam_holder.add_child(slam_cap)

	slam_label = Label3D.new()
	slam_label.text = repo.get_ui_text("hud", "end_turn_label")
	DiegeticScreenFactory.style_label_3d(slam_label, repo, "display", 44, 13, 0.00036, repo.get_palette_color("mfd_text"))
	slam_label.position = JsonConfigLoader.to_vec3(dcfg.get("slam_label_offset", []), Vector3(0.0, 0.048, -0.056))
	slam_label.rotation_degrees = JsonConfigLoader.to_vec3(dcfg.get("slam_label_rot_deg", []), Vector3(-38.0, 0.0, 0.0))
	slam_holder.add_child(slam_label)

	var slam_area: Area3D = Area3D.new()
	slam_area.collision_layer = COLLISION_LAYER_COCKPIT
	slam_area.collision_mask = 0
	slam_area.position = Vector3(0.0, 0.025, 0.0)
	slam_area.set_meta("interact_type", "end_turn_button")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var sph: SphereShape3D = SphereShape3D.new()
	sph.radius = 0.062
	cs.shape = sph
	slam_area.add_child(cs)
	slam_holder.add_child(slam_area)

func _build_switches(dcfg: Dictionary) -> void:
	var base_scene: PackedScene = repo.load_model_scene("toggle_base")
	var lever_scene: PackedScene = repo.load_model_scene("toggle_lever")
	var sw_list: Array = dcfg.get("switches", []) as Array

	for item: Variant in sw_list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var sw: Dictionary = item as Dictionary
		var sw_id: String = str(sw.get("id", ""))
		if sw_id.is_empty():
			continue

		var holder: Node3D = Node3D.new()
		holder.position = JsonConfigLoader.to_vec3(sw.get("pos", []), Vector3.ZERO)
		holder.rotation_degrees = JsonConfigLoader.to_vec3(sw.get("rot_deg", []), Vector3(48.0, -28.0, 0.0))
		add_child(holder)

		if base_scene != null:
			holder.add_child(base_scene.instantiate())

		var lev_pivot: Node3D = Node3D.new()
		if lever_scene != null:
			lev_pivot.add_child(lever_scene.instantiate())
		holder.add_child(lev_pivot)
		switch_levers[sw_id] = lev_pivot
		switch_states[sw_id] = (sw_id == "cabin_lamp")

		var lbl: Label3D = Label3D.new()
		lbl.text = str(sw.get("label", sw_id))
		DiegeticScreenFactory.style_label_3d(lbl, repo, "display", 40, 11, 0.00032, repo.get_palette_color("mfd_text"))
		lbl.position = Vector3(0.0, 0.026, 0.046)
		lbl.rotation_degrees = Vector3(-42.0, 0.0, 0.0)
		holder.add_child(lbl)

		var area: Area3D = Area3D.new()
		area.collision_layer = COLLISION_LAYER_COCKPIT
		area.collision_mask = 0
		area.position = Vector3(0.0, 0.02, 0.0)
		area.set_meta("interact_type", "dashboard_switch")
		area.set_meta("switch_id", sw_id)
		area.set_meta("switch_hint", str(sw.get("hint", sw_id)))
		var cs: CollisionShape3D = CollisionShape3D.new()
		var sph: SphereShape3D = SphereShape3D.new()
		sph.radius = 0.032
		cs.shape = sph
		area.add_child(cs)
		holder.add_child(area)

func _build_warning_lamps(dcfg: Dictionary) -> void:
	var lamp_scene: PackedScene = repo.load_model_scene("warning_lamp")
	var lamps: Array = dcfg.get("warning_lamps", []) as Array
	for item: Variant in lamps:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var l_cfg: Dictionary = item as Dictionary
		var lid: String = str(l_cfg.get("id", ""))
		var holder: Node3D = Node3D.new()
		holder.position = JsonConfigLoader.to_vec3(l_cfg.get("pos", []), Vector3.ZERO)
		holder.rotation_degrees = JsonConfigLoader.to_vec3(l_cfg.get("rot_deg", []), Vector3(78.0, -13.0, 0.0))
		add_child(holder)

		if lamp_scene != null:
			holder.add_child(lamp_scene.instantiate())
			var bulb: MeshInstance3D = MeshInstance3D.new()
			var sph: SphereMesh = SphereMesh.new()
			sph.radius = 0.014
			sph.height = 0.028
			bulb.mesh = sph
			bulb.position = Vector3(0.0, 0.013, 0.0)
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.albedo_color = JsonConfigLoader.to_color(l_cfg.get("color", []), Color.ORANGE) * 0.25
			bulb.material_override = mat
			holder.add_child(bulb)
			lamp_materials[lid] = {
				"mat": mat,
				"base_color": JsonConfigLoader.to_color(l_cfg.get("color", []), Color.ORANGE)
			}

		var lbl: Label3D = Label3D.new()
		lbl.text = str(l_cfg.get("label", lid))
		DiegeticScreenFactory.style_label_3d(lbl, repo, "display", 40, 11, 0.00032, repo.get_palette_color("mfd_text"))
		lbl.position = Vector3(0.0, 0.016, -0.028)
		lbl.rotation_degrees = Vector3(-68.0, 0.0, 0.0)
		holder.add_child(lbl)

func trigger_slam_button() -> void:
	var dcfg: Dictionary = repo.cockpit.get("dashboard", {}) as Dictionary
	slam_depress = float(dcfg.get("slam_press_depth", 0.018))
	engine.sfx_requested.emit("slam_button", 1.0)
	engine.end_player_turn()

func trigger_switch(switch_id: String) -> void:
	if not switch_states.has(switch_id):
		return
	engine.sfx_requested.emit("switch_click", 0.85)
	if switch_id == "cabin_lamp":
		audio_muted = not audio_muted
		switch_states["cabin_lamp"] = not audio_muted
		engine_audio_mute_toggled.emit(audio_muted)
		_refresh_dashboard()

func sync_audio_mute_state(muted: bool) -> void:
	audio_muted = muted
	if switch_states.has("cabin_lamp"):
		switch_states["cabin_lamp"] = not muted
	_refresh_dashboard()

func _on_card_played_fx(card_data: Dictionary, _target_index: int) -> void:
	if bool(card_data.get("is_ram", false)):
		steer_impulse_deg = 12.0
	elif int(card_data.get("gear_shift_delta", 0)) != 0:
		steer_impulse_deg = -7.0

func _refresh_dashboard() -> void:
	if repo == null or engine == null:
		return
	if inspected_card_hand_index >= engine.hand.size():
		inspected_card_hand_index = -1

	var eval_gear: int = engine.effective_gear()
	var g_short: String = engine.transmission.gear_short_name(eval_gear)
	if eval_gear != engine.current_gear:
		g_short = ">%s<" % g_short
	var g_dict: Dictionary = repo.get_gear(eval_gear)
	var stall_risk: bool = engine.transmission.is_stall_risk(eval_gear, engine.rpm_units)
	var redline: bool = engine.transmission.is_redline(eval_gear, engine.rpm_units)
	var optimal: bool = engine.transmission.is_optimal(eval_gear, engine.rpm_units)

	_refresh_analog_dial_faces(g_short, g_dict)

	if slam_label != null:
		if stall_risk:
			slam_label.text = repo.get_ui_text("hud", "stall_warning")
			slam_label.modulate = repo.get_palette_color("redline_glow")
		else:
			slam_label.text = repo.get_ui_text("hud", "end_turn_label")
			slam_label.modulate = repo.get_palette_color("mfd_text")

	_set_lamp_state("stall", stall_risk)
	_set_lamp_state("optimal", optimal)
	_set_lamp_state("redline", redline)
	_set_lamp_state("heat", engine.heat >= engine.max_heat() - 1)
	_set_lamp_state("debuff", engine.puncture_turns > 0 or engine.gear_lock_max >= -1 or engine.gear_lock_min >= -1)

	_refresh_mfd_content()

func _refresh_analog_dial_faces(g_short: String, g_dict: Dictionary) -> void:
	if dial_gear_lbl != null:
		dial_gear_lbl.text = g_short
	if dial_heat_lbl != null:
		dial_heat_lbl.text = "%d/%d" % [engine.heat, engine.max_heat()]
		dial_heat_lbl.modulate = repo.get_palette_color("redline_glow") if engine.heat >= engine.max_heat() - 1 else repo.get_palette_color("kw_heat_up")

	var stall_u: int = int(g_dict.get("stall_rpm_units", 0))
	var opt_min: int = int(g_dict.get("optimal_min_units", 0))
	var opt_max: int = int(g_dict.get("optimal_max_units", 8))
	var red_u: int = int(g_dict.get("redline_rpm_units", 8))

	for u: int in range(rpm_tick_labels.size()):
		var tlbl: Label3D = rpm_tick_labels[u]
		var z_col: Color = repo.get_palette_color("mfd_text")
		if u >= red_u:
			z_col = repo.get_palette_color("redline_glow")
		elif u > 0 and u < stall_u:
			z_col = repo.get_palette_color("slot_grind")
		elif u >= opt_min and u <= opt_max:
			z_col = repo.get_palette_color("playable_glow")
		if tlbl != null:
			tlbl.modulate = z_col
		if u < rpm_tick_mats.size() and rpm_tick_mats[u] != null:
			rpm_tick_mats[u].albedo_color = z_col

	if rpm_pointer_mat != null:
		if engine.rpm_units >= red_u:
			rpm_pointer_mat.albedo_color = repo.get_palette_color("redline_glow")
		elif engine.rpm_units >= opt_min and engine.rpm_units <= opt_max:
			rpm_pointer_mat.albedo_color = repo.get_palette_color("selected_glow")
		else:
			rpm_pointer_mat.albedo_color = repo.get_palette_color("slot_grind")
	if heat_pointer_mat != null:
		heat_pointer_mat.albedo_color = repo.get_palette_color("redline_glow") if engine.heat >= engine.max_heat() - 1 else repo.get_palette_color("mfd_accent")

func _has_active_inspector() -> bool:
	if inspected_enemy_index >= 0 and inspected_enemy_index < engine.enemies.size():
		if bool(engine.enemies[inspected_enemy_index].get("alive", false)):
			return true
	if inspected_card_hand_index >= 0 and inspected_card_hand_index < engine.hand.size():
		return true
	return false

func world_pos_to_viewport(world_hit: Vector3) -> Vector2:
	if mfd_screen_mesh == null:
		return Vector2(-1.0, -1.0)
	var local: Vector3 = mfd_screen_mesh.to_local(world_hit)
	var u: float = (local.x / maxf(0.01, mfd_world_size.x)) + 0.5
	var v: float = 0.5 - (local.y / maxf(0.01, mfd_world_size.y))
	return Vector2(u * mfd_vp_size.x, v * mfd_vp_size.y)

func update_hover_world_pos(world_hit: Vector3) -> String:
	if repo == null:
		return ""
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	var found_id: String = ""
	var found_hint: String = ""
	for hs: Dictionary in mfd_hotspots:
		if (hs.get("rect", Rect2()) as Rect2).has_point(pt):
			found_id = str(hs.get("id", ""))
			found_hint = str(hs.get("hint", ""))
			break
	set_hovered_tab(found_id)
	if not found_hint.is_empty():
		return found_hint
	return repo.get_ui_text("hud", "hover_mfd_deck")

func click_world_pos(world_hit: Vector3) -> bool:
	if repo == null or engine == null:
		return false
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	for hs: Dictionary in mfd_hotspots:
		if (hs.get("rect", Rect2()) as Rect2).has_point(pt):
			var hid: String = str(hs.get("id", ""))
			match hid:
				TAB_ENGINE, TAB_GEARS, TAB_GLOSSARY:
					set_active_tab(hid)
					engine.sfx_requested.emit("switch_click", 0.72)
					return true
				TAB_DECK, "inspect_deck":
					deck_preview_requested.emit()
					return true
				"glossary_prev":
					if glossary_page > 0:
						glossary_page -= 1
						engine.sfx_requested.emit("switch_click", 0.65)
						_refresh_mfd_content()
					return true
				"glossary_next":
					glossary_page += 1
					engine.sfx_requested.emit("switch_click", 0.65)
					_refresh_mfd_content()
					return true
	if active_tab == TAB_ENGINE:
		deck_preview_requested.emit()
		return true
	return false

func _refresh_mfd_content() -> void:
	if mfd_canvas != null:
		DiegeticScreenFactory.request_redraw(mfd_canvas)

func _set_lamp_state(lamp_id: String, active: bool) -> void:
	if not lamp_materials.has(lamp_id):
		return
	var entry: Dictionary = lamp_materials[lamp_id] as Dictionary
	var mat: StandardMaterial3D = entry.get("mat") as StandardMaterial3D
	var col: Color = entry.get("base_color", Color.ORANGE) as Color
	if mat == null:
		return
	if active:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = col * 0.22

func _process(delta: float) -> void:
	if repo == null or engine == null:
		return
	time_accum += delta
	var dcfg: Dictionary = repo.cockpit.get("dashboard", {}) as Dictionary
	var smooth: float = clampf(delta * float(dcfg.get("needle_smoothing", 11.0)), 0.0, 1.0)

	smoothed_rpm_units = lerpf(smoothed_rpm_units, float(engine.rpm_units), smooth)
	var target_heat_ratio: float = clampf(float(engine.heat) / float(maxi(1, engine.max_heat())), 0.0, 1.0)
	smoothed_heat_ratio = lerpf(smoothed_heat_ratio, target_heat_ratio, smooth)

	if rpm_needle != null:
		var zero_deg: float = float(dcfg.get("rpm_angle_zero_deg", 215.0))
		var span_deg: float = float(dcfg.get("rpm_angle_span_deg", 250.0))
		var jitter: float = 0.0
		var shake_thresh: int = int(dcfg.get("rpm_shake_threshold_units", 6))
		if engine.rpm_units >= shake_thresh:
			var max_j: float = float(dcfg.get("rpm_shake_jitter_deg", 3.6))
			jitter = sin(time_accum * 74.0) * max_j * (float(engine.rpm_units - shake_thresh + 1) * 0.5)
		rpm_needle.rotation_degrees.z = zero_deg - (smoothed_rpm_units / 8.0) * span_deg + jitter

	if heat_needle != null:
		var h_zero: float = float(dcfg.get("heat_angle_zero_deg", 210.0))
		var h_span: float = float(dcfg.get("heat_angle_span_deg", 240.0))
		heat_needle.rotation_degrees.z = h_zero - smoothed_heat_ratio * h_span

	if steering_wheel != null:
		steer_impulse_deg = lerpf(steer_impulse_deg, 0.0, clampf(delta * 6.0, 0.0, 1.0))
		smoothed_external_steer_deg = lerpf(smoothed_external_steer_deg, external_steer_deg, clampf(delta * 10.5, 0.0, 1.0))
		var engine_vib: float = sin(time_accum * 42.0) * (0.20 + smoothed_rpm_units * 0.16)
		var base_rot: Vector3 = JsonConfigLoader.to_vec3(dcfg.get("steering_wheel_rot_deg", []), Vector3(-24.0, 0.0, 0.0))
		steering_wheel.rotation_degrees = Vector3(base_rot.x, base_rot.y, steer_impulse_deg + smoothed_external_steer_deg + engine_vib)

	if slam_cap != null:
		slam_depress = lerpf(slam_depress, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		slam_cap.position.y = -slam_depress
		if slam_label != null and engine.has_stall_risk():
			var pulse_t: float = 0.5 + 0.5 * sin(time_accum * 9.5)
			slam_label.modulate = repo.get_palette_color("redline_glow").lerp(Color.WHITE, pulse_t * 0.48)

	for sw_id: String in switch_levers.keys():
		var lev: Node3D = switch_levers[sw_id] as Node3D
		if lev != null:
			var target_x: float = -22.0 if bool(switch_states.get(sw_id, false)) else 22.0
			lev.rotation_degrees.x = lerpf(lev.rotation_degrees.x, target_x, clampf(delta * 14.0, 0.0, 1.0))


class _DashboardSynopticCanvas extends Control:
	var ctrl: Dashboard3DController

	func _draw() -> void:
		if ctrl == null or ctrl.repo == null or ctrl.engine == null:
			return
		var sz: Vector2 = size
		var rep: GameRepository = ctrl.repo
		var eng: CombatEngine = ctrl.engine
		var f_disp: Font = rep.get_font("display")
		var out_col: Color = rep.get_outline_color()

		var c_border: Color = rep.get_palette_color("mfd_border")
		var c_accent: Color = rep.get_palette_color("mfd_accent")
		var c_txt: Color = rep.get_palette_color("mfd_text")
		var c_sel: Color = rep.get_palette_color("selected_glow")
		var c_play: Color = rep.get_palette_color("playable_glow")
		var c_panel: Color = rep.get_palette_color("mfd_panel_bg")

		var outer_r: Rect2 = Rect2(3.0, 3.0, sz.x - 6.0, sz.y - 6.0)
		DiegeticScreenFactory.draw_industrial_plate(self, outer_r, rep, c_accent if not ctrl.hovered_tab.is_empty() else c_border, 12.0, 2.6, true, 42.0, false)

		var grid_c: Color = Color(c_border.r, c_border.g, c_border.b, 0.08)
		for gx: int in range(1, 9):
			var x: float = sz.x * (float(gx) / 9.0)
			draw_line(Vector2(x, 48.0), Vector2(x, sz.y - 10.0), grid_c, 1.0)
		for gy: int in range(1, 5):
			var y: float = 48.0 + (sz.y - 58.0) * (float(gy) / 5.0)
			draw_line(Vector2(12.0, y), Vector2(sz.x - 12.0, y), grid_c, 1.0)

		ctrl.mfd_hotspots.clear()
		var tabs: Array[Dictionary] = [
			{"id": Dashboard3DController.TAB_ENGINE, "label": rep.get_ui_text("screens", "mfd_tab_engine"), "hint": "MFD [ENGINE] — Drivetrain passive, status & combat log"},
			{"id": Dashboard3DController.TAB_GEARS, "label": rep.get_ui_text("screens", "mfd_tab_gears"), "hint": "MFD [GEARS] — All 8 gears: Stall, Optimal, Redline & perks"},
			{"id": Dashboard3DController.TAB_GLOSSARY, "label": rep.get_ui_text("screens", "mfd_tab_glossary"), "hint": "MFD [GLOSSARY] — Card keywords & drivetrain rules"},
			{"id": Dashboard3DController.TAB_DECK, "label": "%s [I]" % rep.get_ui_text("screens", "mfd_tab_deck"), "hint": rep.get_ui_text("hud", "hover_mfd_deck")}
		]
		var tab_gap: float = 8.0
		var tab_w: float = (sz.x - 28.0 - tab_gap * 3.0) / 4.0
		for ti: int in range(tabs.size()):
			var td: Dictionary = tabs[ti]
			var tid: String = str(td["id"])
			var tr: Rect2 = Rect2(14.0 + float(ti) * (tab_w + tab_gap), 8.0, tab_w, 32.0)
			var is_act: bool = (ctrl.active_tab == tid)
			var is_thov: bool = (ctrl.hovered_tab == tid)
			var tcol: Color = c_sel if is_act else (c_play if tid == Dashboard3DController.TAB_DECK else c_accent)
			var tbg: Color = c_panel.lerp(tcol, 0.30 if is_act else (0.20 if is_thov else 0.06))
			DiegeticScreenFactory.draw_chamfer_rect(self, tr, 5.0, tbg, c_txt if is_thov else tcol, 2.2 if (is_act or is_thov) else 1.5)
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(tr.position.x + 6.0, tr.position.y + 22.0),
				str(td["label"]),
				HORIZONTAL_ALIGNMENT_CENTER,
				tr.size.x - 12.0,
				16,
				c_txt if (is_act or is_thov) else tcol.lightened(0.22),
				out_col,
				2,
				11
			)
			ctrl.mfd_hotspots.append({"id": tid, "rect": tr, "hint": str(td["hint"])})

		var content_r: Rect2 = Rect2(10.0, 48.0, sz.x - 20.0, sz.y - 58.0)
		_draw_synoptic_engine_and_radar(content_r, rep, eng)

	func _draw_synoptic_engine_and_radar(area: Rect2, rep: GameRepository, eng: CombatEngine) -> void:
		if ctrl.active_tab == Dashboard3DController.TAB_GEARS:
			_draw_gears_table(area, rep, eng)
			return
		if ctrl.active_tab == Dashboard3DController.TAB_GLOSSARY:
			_draw_glossary_panel(area, rep)
			return
		if ctrl.inspected_enemy_index >= 0 and ctrl.inspected_enemy_index < eng.enemies.size() and bool(eng.enemies[ctrl.inspected_enemy_index].get("alive", false)):
			_draw_right_enemy_radar(area, rep, eng, eng.enemies[ctrl.inspected_enemy_index])
		elif ctrl.inspected_card_hand_index >= 0 and ctrl.inspected_card_hand_index < eng.hand.size():
			_draw_right_card_schematic(area, rep, eng, ctrl.inspected_card_hand_index)
		else:
			_draw_deck_counter_summary(area, rep, eng)

	func _draw_mini_stat_pill(rect: Rect2, label: String, val: String, col: Color, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var out_col: Color = rep.get_outline_color()
		var bg_col: Color = rep.get_palette_color("mfd_panel_bg")
		var txt_col: Color = rep.get_palette_color("mfd_text")
		DiegeticScreenFactory.draw_chamfer_rect(self, rect, 7.0, bg_col, col * 0.88, 2.0)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			rect.position + Vector2(4.0, 24.0),
			label,
			HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x - 8.0,
			15,
			col.lightened(0.24),
			out_col,
			2,
			11
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			rect.position + Vector2(4.0, 66.0),
			val,
			HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x - 8.0,
			32,
			txt_col,
			out_col,
			3,
			18
		)

	func _draw_deck_counter_summary(rect: Rect2, rep: GameRepository, eng: CombatEngine) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var c_accent: Color = rep.get_palette_color("mfd_accent")
		var c_play: Color = rep.get_palette_color("playable_glow")
		var c_shield: Color = rep.get_palette_color("kw_shield")
		var c_txt: Color = rep.get_palette_color("mfd_text")
		var c_muted: Color = rep.get_palette_color("mfd_muted")
		var c_panel: Color = rep.get_palette_color("mfd_panel_bg")
		var c_sel: Color = rep.get_palette_color("selected_glow")
		var c_red: Color = rep.get_palette_color("redline_glow")
		var is_hov: bool = (ctrl.hovered_tab == "inspect_deck" or ctrl.hovered_tab == Dashboard3DController.TAB_DECK)

		var cnt_y: float = rect.position.y + 4.0
		var cnt_h: float = 72.0
		var left_w: float = rect.size.x * 0.52
		var cnt_w: float = (left_w - 16.0) / 3.0
		_draw_mini_stat_pill(Rect2(rect.position.x + 6.0, cnt_y, cnt_w, cnt_h), rep.get_ui_text("screens", "mfd_draw_lbl"), str(eng.draw_pile.size()), c_play, rep)
		_draw_mini_stat_pill(Rect2(rect.position.x + 12.0 + cnt_w, cnt_y, cnt_w, cnt_h), rep.get_ui_text("screens", "mfd_discard_lbl"), str(eng.discard_pile.size()), c_accent, rep)
		_draw_mini_stat_pill(Rect2(rect.position.x + 18.0 + cnt_w * 2.0, cnt_y, cnt_w, cnt_h), rep.get_ui_text("screens", "mfd_total_lbl"), str(eng.master_deck.size()), c_shield, rep)

		var btn_r: Rect2 = Rect2(rect.position.x + left_w + 12.0, cnt_y, rect.size.x - left_w - 18.0, cnt_h)
		var btn_col: Color = c_accent if is_hov else c_play
		var btn_bg: Color = c_panel.lerp(btn_col, 0.22 if is_hov else 0.08)
		DiegeticScreenFactory.draw_chamfer_rect(self, btn_r, 8.0, btn_bg, btn_col, 2.2 if is_hov else 1.7)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(btn_r.position.x + 8.0, btn_r.position.y + 30.0),
			rep.get_ui_text("screens", "mfd_inspect_btn"),
			HORIZONTAL_ALIGNMENT_CENTER,
			btn_r.size.x - 16.0,
			19,
			c_txt if is_hov else btn_col.lightened(0.24),
			out_col,
			3,
			12
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(btn_r.position.x + 8.0, btn_r.position.y + 55.0),
			rep.get_ui_text("screens", "mfd_inspect_sub"),
			HORIZONTAL_ALIGNMENT_CENTER,
			btn_r.size.x - 16.0,
			15,
			c_txt if is_hov else c_muted.lightened(0.18),
			out_col,
			2,
			11
		)
		ctrl.mfd_hotspots.append({"id": "inspect_deck", "rect": btn_r, "hint": rep.get_ui_text("hud", "hover_mfd_deck")})

		var eval_gear: int = eng.effective_gear()
		var g_dict: Dictionary = rep.get_gear(eval_gear)
		var g_short: String = eng.transmission.gear_short_name(eval_gear)
		var pas_y: float = cnt_y + cnt_h + 8.0
		var pas_h: float = 96.0
		var pas_r: Rect2 = Rect2(rect.position.x + 6.0, pas_y, rect.size.x - 12.0, pas_h)
		DiegeticScreenFactory.draw_chamfer_rect(self, pas_r, 7.0, c_panel, c_sel * 0.78, 1.8)
		var sync_lbl: String = rep.get_ui_text("screens", "mfd_free_shift_ready" if eng.free_shift_available else "mfd_grind_warning")
		var sync_col: Color = c_play if eng.free_shift_available else rep.get_palette_color("slot_grind")
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(pas_r.position.x + 12.0, pas_r.position.y + 24.0),
			"%s  [%s — %s]" % [rep.get_ui_text("screens", "mfd_section_passive"), g_short, str(g_dict.get("role", "")).to_upper()],
			HORIZONTAL_ALIGNMENT_LEFT,
			pas_r.size.x - 250.0,
			16,
			c_sel.lightened(0.20),
			out_col,
			2,
			11
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(pas_r.end.x - 234.0, pas_r.position.y + 24.0),
			sync_lbl,
			HORIZONTAL_ALIGNMENT_RIGHT,
			222.0,
			14,
			sync_col.lightened(0.20),
			out_col,
			2,
			10
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(pas_r.position.x + 12.0, pas_r.position.y + 52.0),
			str(g_dict.get("description", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			pas_r.size.x - 24.0,
			18,
			c_txt,
			out_col,
			2,
			12
		)
		var rel_names: PackedStringArray = PackedStringArray()
		for rid: String in eng.owned_relics:
			rel_names.append(str(rep.get_relic(rid).get("name", rid)).to_upper())
		var rel_str: String = "RELICS: " + (" • ".join(rel_names) if not rel_names.is_empty() else "NONE")
		if eng.turn_torque_bonus > 0:
			rel_str = ("TORQUE +%d DMG  |  " % eng.turn_torque_bonus) + rel_str
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(pas_r.position.x + 12.0, pas_r.position.y + 80.0),
			rel_str,
			HORIZONTAL_ALIGNMENT_LEFT,
			pas_r.size.x - 24.0,
			15,
			c_accent.lightened(0.18),
			out_col,
			2,
			10
		)

		var log_y: float = pas_y + pas_h + 8.0
		var log_r: Rect2 = Rect2(rect.position.x + 6.0, log_y, rect.size.x - 12.0, maxf(96.0, rect.end.y - log_y - 4.0))
		DiegeticScreenFactory.draw_chamfer_rect(self, log_r, 7.0, c_panel, rep.get_palette_color("mfd_border") * 0.85, 1.6)
		var status_parts: PackedStringArray = PackedStringArray()
		if eng.puncture_turns > 0:
			status_parts.append("PUNCTURE %dT" % eng.puncture_turns)
		if eng.gear_lock_max >= -1:
			status_parts.append("MAX GEAR %s" % eng.transmission.gear_short_name(eng.gear_lock_max))
		if eng.gear_lock_min >= -1:
			status_parts.append("MIN GEAR %s" % eng.transmission.gear_short_name(eng.gear_lock_min))
		if eng.ranged_dodge_charges > 0:
			status_parts.append("DODGE x%d" % eng.ranged_dodge_charges)
		if eng.retain_half_block_next_turn:
			status_parts.append("RETAIN 50% SHD")
		var status_txt: String = " • ".join(status_parts) if not status_parts.is_empty() else rep.get_ui_text("screens", "mfd_nominal_status")
		var status_col: Color = c_red.lightened(0.24) if (eng.puncture_turns > 0 or eng.gear_lock_max >= -1 or eng.gear_lock_min >= -1) else c_play.lightened(0.18)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(log_r.position.x + 12.0, log_r.position.y + 23.0),
			rep.get_ui_text("screens", "mfd_section_vehicle"),
			HORIZONTAL_ALIGNMENT_LEFT,
			320.0,
			15,
			c_accent,
			out_col,
			2,
			11
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(log_r.position.x + 336.0, log_r.position.y + 23.0),
			status_txt,
			HORIZONTAL_ALIGNMENT_RIGHT,
			log_r.size.x - 348.0,
			15,
			status_col,
			out_col,
			2,
			11
		)
		draw_line(Vector2(log_r.position.x + 10.0, log_r.position.y + 32.0), Vector2(log_r.end.x - 10.0, log_r.position.y + 32.0), Color(c_accent.r, c_accent.g, c_accent.b, 0.25), 1.2)

		var total_logs: int = eng.combat_log.size()
		var show_n: int = mini(5, total_logs)
		for li: int in range(show_n):
			var msg: String = eng.combat_log[total_logs - show_n + li]
			var is_latest: bool = (li == show_n - 1)
			var ly: float = log_r.position.y + 56.0 + float(li) * 35.0
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_body,
				Vector2(log_r.position.x + 14.0, ly),
				("> " if is_latest else "· ") + msg,
				HORIZONTAL_ALIGNMENT_LEFT,
				log_r.size.x - 28.0,
				17 if is_latest else 16,
				c_txt if is_latest else c_muted.lightened(0.26),
				out_col,
				2,
				11
			)

	func _draw_gears_table(rect: Rect2, rep: GameRepository, eng: CombatEngine) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var c_panel: Color = rep.get_palette_color("mfd_panel_bg")
		var c_txt: Color = rep.get_palette_color("mfd_text")
		var c_sel: Color = rep.get_palette_color("selected_glow")
		var c_play: Color = rep.get_palette_color("playable_glow")
		var c_red: Color = rep.get_palette_color("redline_glow")
		var c_accent: Color = rep.get_palette_color("mfd_accent")
		var eval_gear: int = eng.effective_gear()

		DiegeticScreenFactory.draw_fitted_text(
			self, f_disp, rect.position + Vector2(8.0, 20.0),
			rep.get_ui_text("screens", "mfd_header_gears"),
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 16, c_accent, out_col, 2, 11
		)
		var gears: Array[Dictionary] = rep.ordered_gears
		var count: int = maxi(1, gears.size())
		var top_y: float = rect.position.y + 28.0
		var row_h: float = (rect.size.y - 32.0) / float(count)
		for i: int in range(gears.size()):
			var gd: Dictionary = gears[i]
			var g_idx: int = int(gd.get("index", 0))
			var is_cur: bool = (g_idx == eval_gear)
			var rr: Rect2 = Rect2(rect.position.x + 4.0, top_y + float(i) * row_h, rect.size.x - 8.0, row_h - 4.0)
			var brd: Color = c_sel if is_cur else rep.get_palette_color("mfd_border") * 0.72
			var bg: Color = c_panel.lerp(c_sel, 0.16) if is_cur else c_panel
			DiegeticScreenFactory.draw_chamfer_rect(self, rr, 5.0, bg, brd, 2.2 if is_cur else 1.3)
			var ty: float = rr.position.y + rr.size.y * 0.68
			var g_lbl: String = "%s (%s)" % [str(gd.get("short_name", "")), str(gd.get("role", "")).to_upper()]
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rr.position.x + 10.0, ty), g_lbl, HORIZONTAL_ALIGNMENT_LEFT, 148.0, 16, c_sel if is_cur else c_txt, out_col, 2, 11)
			var stall_u: int = int(gd.get("stall_rpm_units", 0))
			var opt_min: int = int(gd.get("optimal_min_units", 0))
			var opt_max: int = int(gd.get("optimal_max_units", 8))
			var red_u: int = int(gd.get("redline_rpm_units", 8))
			var stall_str: String = ("STALL <%dK" % stall_u) if stall_u > 0 else "NO STALL"
			var opt_str: String = "OPT %d-%dK" % [opt_min, opt_max]
			var red_str: String = "RED %dK+" % red_u
			DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rr.position.x + 164.0, ty), stall_str, HORIZONTAL_ALIGNMENT_LEFT, 86.0, 15, rep.get_palette_color("slot_grind") if stall_u > 0 else c_play, out_col, 2, 10)
			DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rr.position.x + 254.0, ty), opt_str, HORIZONTAL_ALIGNMENT_LEFT, 86.0, 15, c_play, out_col, 2, 10)
			DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rr.position.x + 344.0, ty), red_str, HORIZONTAL_ALIGNMENT_LEFT, 76.0, 15, c_red.lightened(0.20), out_col, 2, 10)
			DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rr.position.x + 426.0, ty), str(gd.get("description", "")), HORIZONTAL_ALIGNMENT_LEFT, rr.size.x - 436.0, 16, c_txt, out_col, 2, 11)

	func _draw_glossary_panel(rect: Rect2, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var c_panel: Color = rep.get_palette_color("mfd_panel_bg")
		var c_txt: Color = rep.get_palette_color("mfd_text")
		var c_accent: Color = rep.get_palette_color("mfd_accent")
		var c_sel: Color = rep.get_palette_color("selected_glow")

		var kw_map: Dictionary = rep.ui_strings.get("keywords", {}) as Dictionary
		var keys: Array = kw_map.keys()
		var per_page: int = 10
		var total_pages: int = maxi(1, int(ceil(float(keys.size()) / float(per_page))))
		ctrl.glossary_page = clampi(ctrl.glossary_page, 0, total_pages - 1)

		DiegeticScreenFactory.draw_fitted_text(
			self, f_disp, rect.position + Vector2(8.0, 22.0),
			"%s  (%d/%d)" % [rep.get_ui_text("screens", "mfd_header_glossary"), ctrl.glossary_page + 1, total_pages],
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 200.0, 16, c_accent, out_col, 2, 11
		)
		var prev_r: Rect2 = Rect2(rect.end.x - 156.0, rect.position.y + 2.0, 70.0, 26.0)
		var next_r: Rect2 = Rect2(rect.end.x - 78.0, rect.position.y + 2.0, 70.0, 26.0)
		var can_prev: bool = ctrl.glossary_page > 0
		var can_next: bool = ctrl.glossary_page < total_pages - 1
		for btn_info: Dictionary in [
			{"id": "glossary_prev", "rect": prev_r, "lbl": "[<]", "en": can_prev, "hint": "MFD Glossary — Previous page"},
			{"id": "glossary_next", "rect": next_r, "lbl": "[>]", "en": can_next, "hint": "MFD Glossary — Next page"}
		]:
			var br: Rect2 = btn_info["rect"] as Rect2
			var en: bool = bool(btn_info["en"])
			var hov: bool = (ctrl.hovered_tab == str(btn_info["id"]))
			var bc: Color = (c_txt if hov else c_sel) if en else rep.get_palette_color("disabled_tint")
			DiegeticScreenFactory.draw_chamfer_rect(self, br, 4.0, c_panel, bc, 1.8)
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(br.position.x, br.position.y + 19.0), str(btn_info["lbl"]), HORIZONTAL_ALIGNMENT_CENTER, br.size.x, 15, bc, out_col, 2, 11)
			ctrl.mfd_hotspots.append({"id": str(btn_info["id"]), "rect": br, "hint": str(btn_info["hint"])})

		var start_idx: int = ctrl.glossary_page * per_page
		var col_w: float = (rect.size.x - 16.0) * 0.5
		var row_h: float = (rect.size.y - 36.0) / 5.0
		for i: int in range(per_page):
			var k_idx: int = start_idx + i
			if k_idx >= keys.size():
				break
			var kw_entry: Dictionary = kw_map[keys[k_idx]] as Dictionary
			var col_i: int = i % 2
			var row_i: int = i / 2
			var cell_r: Rect2 = Rect2(rect.position.x + 4.0 + float(col_i) * (col_w + 8.0), rect.position.y + 34.0 + float(row_i) * row_h, col_w, row_h - 5.0)
			var kcol: Color = rep.get_palette_color(str(kw_entry.get("color_key", "mfd_accent")))
			DiegeticScreenFactory.draw_chamfer_rect(self, cell_r, 5.0, c_panel, kcol * 0.78, 1.5)
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, cell_r.position + Vector2(10.0, 22.0), str(kw_entry.get("label", "")).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, cell_r.size.x - 20.0, 15, kcol.lightened(0.24), out_col, 2, 11)
			DiegeticScreenFactory.draw_fitted_text(self, f_body, cell_r.position + Vector2(10.0, 48.0), str(kw_entry.get("glossary", "")), HORIZONTAL_ALIGNMENT_LEFT, cell_r.size.x - 20.0, 15, c_txt, out_col, 2, 10)

	func _draw_right_card_schematic(rect: Rect2, rep: GameRepository, eng: CombatEngine, hand_idx: int) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var card: Dictionary = rep.get_card(eng.hand[hand_idx])
		var check: Dictionary = eng.can_play_card(hand_idx)
		var playable: bool = bool(check.get("playable", false))
		var brd: Color = rep.get_palette_color("playable_glow") if playable else rep.get_palette_color("redline_glow")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")

		DiegeticScreenFactory.draw_chamfer_rect(self, rect, 10.0, panel_bg, brd, 2.4)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			rect.position + Vector2(12.0, 27.0),
			str(card.get("name", "")).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 24.0,
			22,
			rep.get_palette_color("selected_glow"),
			out_col,
			3,
			14
		)
		var g_txt: String = rep.get_ui_text("screens", "mfd_gears_fmt") % eng.transmission.format_allowed_gears(card.get("allowed_gears", []) as Array)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			rect.position + Vector2(12.0, 50.0),
			g_txt if playable else str(check.get("reason", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 24.0,
			18,
			brd.lightened(0.20),
			out_col,
			2,
			12
		)

		var effects: Array[Dictionary] = CardEffectFormatter.format_effects(rep, eng, card)
		var ey: float = rect.position.y + 58.0
		var row_h: float = clampf((rect.size.y - 66.0) / float(maxi(1, effects.size())), 40.0, 62.0)
		for eff: Dictionary in effects:
			var row_r: Rect2 = Rect2(rect.position.x + 10.0, ey, rect.size.x - 20.0, row_h - 4.0)
			CardEmblemCanvas.draw_clear_effect_row(self, row_r, eff, playable, 0.84, rep)
			ey += row_h

	func _draw_right_enemy_radar(rect: Rect2, rep: GameRepository, eng: CombatEngine, enemy: Dictionary) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var col: Color = rep.get_palette_color("enemy_intent")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")
		var txt_col: Color = rep.get_palette_color("mfd_text")

		DiegeticScreenFactory.draw_chamfer_rect(self, rect, 10.0, panel_bg, col, 2.4)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			rect.position + Vector2(14.0, 27.0),
			rep.get_ui_text("screens", "mfd_radar_prefix") + str(enemy.get("name", "")).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 28.0,
			20,
			col.lightened(0.16),
			out_col,
			3,
			13
		)

		var rc: Vector2 = rect.position + Vector2(68.0, 132.0)
		draw_circle(rc, 48.0, mfd_bg)
		draw_arc(rc, 48.0, 0.0, TAU, 28, col * 0.75, 2.2, true)
		draw_arc(rc, 30.0, 0.0, TAU, 20, col * 0.45, 1.4, true)
		draw_line(rc + Vector2(-54.0, 0.0), rc + Vector2(54.0, 0.0), col * 0.45, 1.2)
		draw_line(rc + Vector2(0.0, -54.0), rc + Vector2(0.0, 54.0), col * 0.45, 1.2)
		CardEmblemCanvas._s_draw_impact_burst(self, rc, 24.0, rep.get_palette_color("enemy_hp"))

		var tx: float = rect.position.x + 132.0
		var tw: float = rect.size.x - 144.0
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(tx, rect.position.y + 62.0),
			rep.get_ui_text("screens", "mfd_hull_fmt") % [int(enemy.get("hp", 0)), int(enemy.get("max_hp", 0))],
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			19,
			rep.get_palette_color("enemy_hp").lightened(0.18),
			out_col,
			3,
			13
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(tx, rect.position.y + 88.0),
			rep.get_ui_text("screens", "mfd_shield_fmt") % int(enemy.get("block", 0)),
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			18,
			rep.get_palette_color("kw_shield").lightened(0.16),
			out_col,
			3,
			12
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(tx, rect.position.y + 116.0),
			rep.get_ui_text("screens", "mfd_next_move"),
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			16,
			col,
			out_col,
			2,
			12
		)
		var move_txt: String = eng.format_enemy_intent_summary(enemy)
		draw_multiline_string_outline(
			f_body,
			Vector2(tx, rect.position.y + 138.0),
			move_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			17,
			3,
			3,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(tx, rect.position.y + 138.0),
			move_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			17,
			3,
			txt_col
		)

