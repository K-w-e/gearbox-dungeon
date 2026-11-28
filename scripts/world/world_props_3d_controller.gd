class_name WorldProps3DController
extends Node3D

var repo: GameRepository
var engine: CombatEngine
var arena_ctrl: DungeonArena3D
var fork_ctrl: RoadFork3DController

var scrolling_root: Node3D
var workshop_root: Node3D
var vfx_root: Node3D

var wall_units: Array[Dictionary] = []
var ceiling_units: Array[Dictionary] = []
var hazard_units: Array[Dictionary] = []

var workshop_bay_inst: Node3D
var welder_arm_l: Node3D
var welder_arm_r: Node3D
var welder_tip_l: Node3D
var welder_tip_r: Node3D
var welder_base_rot_l: Vector3 = Vector3.ZERO
var welder_base_rot_r: Vector3 = Vector3.ZERO
var welder_arc_light: OmniLight3D

var puff_pool: Array[Dictionary] = []
var puff_cursor: int = 0
var shared_steam_sph: SphereMesh
var shared_weld_box: BoxMesh
var active_puffs: Array[Dictionary] = []
var scroll_dist: float = 0.0
var steam_timer: float = 0.0
var spark_timer: float = 0.0
var time_accum: float = 0.0

func initialize(
	repository: GameRepository,
	combat_engine: CombatEngine,
	arena: DungeonArena3D,
	fork: RoadFork3DController
) -> void:
	if repository == null or combat_engine == null:
		push_error("WorldProps3DController.initialize received null dependencies")
		return
	repo = repository
	engine = combat_engine
	arena_ctrl = arena
	fork_ctrl = fork

	scrolling_root = Node3D.new()
	scrolling_root.name = "ScrollingProps"
	add_child(scrolling_root)

	workshop_root = Node3D.new()
	workshop_root.name = "WorkshopBayRoot"
	add_child(workshop_root)

	vfx_root = Node3D.new()
	vfx_root.name = "WorldPropVfx"
	add_child(vfx_root)

	_init_puff_pool()
	_build_scrolling_props()
	_build_workshop_bay()

	engine.state_changed.connect(_sync_mode_visibility)
	_sync_mode_visibility()

func _build_scrolling_props() -> void:
	var pcfg: Dictionary = repo.cockpit.get("world_props", {}) as Dictionary
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var road_y: float = float(dcfg.get("road_y", -0.08))
	var wall_x: float = float(pcfg.get("wall_x", 3.04))

	var mach_scene: PackedScene = repo.load_model_scene("prop_wall_machinery")
	if mach_scene != null:
		var m_count: int = maxi(1, int(pcfg.get("wall_machinery_count", 4)))
		var m_space: float = maxf(3.0, float(pcfg.get("wall_machinery_spacing_z", 9.0)))
		for i: int in range(m_count):
			var is_left: bool = (i % 2 == 0)
			var inst: Node3D = mach_scene.instantiate() as Node3D
			inst.position = Vector3(-wall_x if is_left else wall_x, road_y, 0.0)
			inst.rotation_degrees = Vector3(0.0, 0.0 if is_left else 180.0, 0.0)
			scrolling_root.add_child(inst)
			var p_rod: Node3D = inst.find_child("PistonRod", true, false) as Node3D
			var base_py: float = p_rod.position.y if p_rod != null else 1.15
			wall_units.append({
				"root": inst,
				"base_offset_z": float(i) * m_space + 2.5,
				"gear_large": inst.find_child("GearLarge", true, false) as Node3D,
				"gear_small": inst.find_child("GearSmall", true, false) as Node3D,
				"piston": p_rod,
				"piston_base_y": base_py,
				"phase": float(i) * 1.35
			})

	var fan_scene: PackedScene = repo.load_model_scene("prop_ceiling_fan_duct")
	if fan_scene != null:
		var f_count: int = maxi(1, int(pcfg.get("ceiling_fan_count", 3)))
		var f_space: float = maxf(4.0, float(pcfg.get("ceiling_fan_spacing_z", 12.0)))
		var fan_y: float = road_y + float(pcfg.get("ceiling_fan_y", 3.8))
		for i: int in range(f_count):
			var inst_f: Node3D = fan_scene.instantiate() as Node3D
			inst_f.position = Vector3(0.0, fan_y, 0.0)
			scrolling_root.add_child(inst_f)
			ceiling_units.append({
				"root": inst_f,
				"base_offset_z": float(i) * f_space + 5.0,
				"blades": inst_f.find_child("FanBlades", true, false) as Node3D,
				"cable": inst_f.find_child("SwingingCable", true, false) as Node3D,
				"phase": float(i) * 2.1
			})

	var haz_scene: PackedScene = repo.load_model_scene("prop_roadside_hazard")
	if haz_scene != null:
		var h_count: int = maxi(1, int(pcfg.get("roadside_hazard_count", 4)))
		var h_space: float = maxf(3.0, float(pcfg.get("roadside_hazard_spacing_z", 9.0)))
		var haz_x: float = float(pcfg.get("roadside_hazard_x", 2.38))
		for i: int in range(h_count):
			var left_side: bool = (i % 2 == 1)
			var inst_h: Node3D = haz_scene.instantiate() as Node3D
			inst_h.position = Vector3(-haz_x if left_side else haz_x, road_y, 0.0)
			inst_h.rotation_degrees = Vector3(0.0, 18.0 if left_side else -162.0, 0.0)
			scrolling_root.add_child(inst_h)
			hazard_units.append({
				"root": inst_h,
				"base_offset_z": float(i) * h_space + 6.5,
				"gyro": inst_h.find_child("HazardGyroLight", true, false) as Node3D,
				"nozzle": inst_h.find_child("SteamNozzle", true, false) as Node3D,
				"phase": float(i) * 1.7
			})

func _build_workshop_bay() -> void:
	var pcfg: Dictionary = repo.cockpit.get("world_props", {}) as Dictionary
	var dcfg: Dictionary = repo.cockpit.get("dungeon", {}) as Dictionary
	var road_y: float = float(dcfg.get("road_y", -0.08))
	var bay_z: float = float(pcfg.get("workshop_bay_z", -5.6))

	var bay_scene: PackedScene = repo.load_model_scene("prop_workshop_bay")
	if bay_scene == null:
		return
	workshop_bay_inst = bay_scene.instantiate() as Node3D
	workshop_bay_inst.position = Vector3(0.0, road_y, bay_z)
	workshop_root.add_child(workshop_bay_inst)

	welder_arm_l = workshop_bay_inst.find_child("WelderArmL", true, false) as Node3D
	welder_arm_r = workshop_bay_inst.find_child("WelderArmR", true, false) as Node3D
	welder_tip_l = workshop_bay_inst.find_child("WelderTipL", true, false) as Node3D
	welder_tip_r = workshop_bay_inst.find_child("WelderTipR", true, false) as Node3D
	if welder_arm_l != null:
		welder_base_rot_l = welder_arm_l.rotation_degrees
	if welder_arm_r != null:
		welder_base_rot_r = welder_arm_r.rotation_degrees

	welder_arc_light = OmniLight3D.new()
	welder_arc_light.position = Vector3(0.0, 1.8, bay_z + 0.5)
	welder_arc_light.light_color = repo.get_palette_color("fork_left_glow")
	welder_arc_light.light_energy = 0.0
	welder_arc_light.omni_range = 6.5
	welder_arc_light.visible = false
	workshop_root.add_child(welder_arc_light)

func _sync_mode_visibility() -> void:
	if engine == null or workshop_root == null:
		return
	workshop_root.visible = (engine.mode == CombatEngine.MODE_WORKSHOP)

func _process(delta: float) -> void:
	if repo == null or engine == null:
		return
	time_accum += delta
	var pcfg: Dictionary = repo.cockpit.get("world_props", {}) as Dictionary

	var suppress_tunnel: bool = (fork_ctrl != null and fork_ctrl.should_suppress_straight_tunnel()) or engine.is_site_mode() or engine.mode == CombatEngine.MODE_WORKSHOP
	scrolling_root.visible = not suppress_tunnel

	var tunnel_spd: float = arena_ctrl.smoothed_tunnel_speed if arena_ctrl != null else 0.0
	var span_z: float = maxf(12.0, float(pcfg.get("loop_span_z", 36.0)))
	var start_z: float = float(pcfg.get("start_z", 3.0))
	scroll_dist = fposmod(scroll_dist + tunnel_spd * delta, span_z)

	if scrolling_root.visible:
		_update_wall_machinery(delta, pcfg, start_z, span_z)
		_update_ceiling_fans(delta, pcfg, start_z, span_z)
		_update_roadside_hazards(delta, pcfg, start_z, span_z)

	if workshop_root != null and workshop_root.visible:
		_update_workshop_bay(delta, pcfg)

	_update_vfx(delta, tunnel_spd)

func _update_wall_machinery(delta: float, pcfg: Dictionary, start_z: float, span_z: float) -> void:
	var spd_scale: float = 0.65 + float(engine.rpm_units) * 0.14
	var g_large_spd: float = float(pcfg.get("gear_large_deg_per_sec", 76.0)) * spd_scale
	var g_small_spd: float = float(pcfg.get("gear_small_deg_per_sec", -132.0)) * spd_scale
	var stroke: float = float(pcfg.get("piston_stroke_m", 0.24))
	var p_spd: float = float(pcfg.get("piston_speed", 4.2)) * spd_scale

	for entry: Dictionary in wall_units:
		var root_n: Node3D = entry.get("root") as Node3D
		if root_n == null:
			continue
		var z_wrapped: float = fposmod(float(entry.get("base_offset_z", 0.0)) - scroll_dist, span_z)
		root_n.position.z = start_z - z_wrapped

		var gl: Node3D = entry.get("gear_large") as Node3D
		if gl != null:
			gl.rotation_degrees.x = fmod(gl.rotation_degrees.x + g_large_spd * delta, 360.0)
		var gs: Node3D = entry.get("gear_small") as Node3D
		if gs != null:
			gs.rotation_degrees.x = fmod(gs.rotation_degrees.x + g_small_spd * delta, 360.0)
		var pist: Node3D = entry.get("piston") as Node3D
		if pist != null:
			var ph: float = float(entry.get("phase", 0.0))
			pist.position.y = float(entry.get("piston_base_y", 1.15)) + sin(time_accum * p_spd + ph) * stroke

func _update_ceiling_fans(delta: float, pcfg: Dictionary, start_z: float, span_z: float) -> void:
	var fan_spd: float = float(pcfg.get("fan_deg_per_sec", 240.0))
	var sway_deg: float = float(pcfg.get("cable_sway_deg", 7.5))
	var sway_spd: float = float(pcfg.get("cable_sway_speed", 2.3))

	for entry: Dictionary in ceiling_units:
		var root_n: Node3D = entry.get("root") as Node3D
		if root_n == null:
			continue
		var z_wrapped: float = fposmod(float(entry.get("base_offset_z", 0.0)) - scroll_dist, span_z)
		root_n.position.z = start_z - z_wrapped

		var blades: Node3D = entry.get("blades") as Node3D
		if blades != null:
			blades.rotation_degrees.y = fmod(blades.rotation_degrees.y + fan_spd * delta, 360.0)
		var cable: Node3D = entry.get("cable") as Node3D
		if cable != null:
			var ph: float = float(entry.get("phase", 0.0))
			cable.rotation_degrees.z = sin(time_accum * sway_spd + ph) * sway_deg

func _update_roadside_hazards(delta: float, pcfg: Dictionary, start_z: float, span_z: float) -> void:
	var gyro_spd: float = float(pcfg.get("gyro_deg_per_sec", 300.0))
	var steam_int: float = maxf(0.4, float(pcfg.get("steam_interval_s", 2.35)))

	for entry: Dictionary in hazard_units:
		var root_n: Node3D = entry.get("root") as Node3D
		if root_n == null:
			continue
		var z_wrapped: float = fposmod(float(entry.get("base_offset_z", 0.0)) - scroll_dist, span_z)
		root_n.position.z = start_z - z_wrapped

		var gyro: Node3D = entry.get("gyro") as Node3D
		if gyro != null:
			gyro.rotation_degrees.y = fmod(gyro.rotation_degrees.y + gyro_spd * delta, 360.0)

	steam_timer += delta
	if steam_timer >= steam_int and not hazard_units.is_empty():
		steam_timer = 0.0
		for entry: Dictionary in hazard_units:
			var root_n: Node3D = entry.get("root") as Node3D
			var noz: Node3D = entry.get("nozzle") as Node3D
			if root_n != null and noz != null and root_n.position.z < -2.5 and root_n.position.z > -18.0:
				_spawn_steam_puff(noz.global_position)
				if engine != null and (engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ROUTE_CHOICE):
					engine.sfx_requested.emit("steam_hiss", 0.34)
				break

func _update_workshop_bay(delta: float, pcfg: Dictionary) -> void:
	var sway_deg: float = float(pcfg.get("welder_sway_deg", 14.0))
	var spd: float = float(pcfg.get("welder_speed", 2.6))
	var spark_int: float = maxf(0.12, float(pcfg.get("welder_spark_interval_s", 0.42)))

	if welder_arm_l != null:
		welder_arm_l.rotation_degrees = welder_base_rot_l + Vector3(
			sin(time_accum * spd) * sway_deg * 0.5,
			cos(time_accum * spd * 0.8) * sway_deg,
			0.0
		)
	if welder_arm_r != null:
		welder_arm_r.rotation_degrees = welder_base_rot_r + Vector3(
			cos(time_accum * spd * 1.1) * sway_deg * 0.5,
			-sin(time_accum * spd * 0.9) * sway_deg,
			0.0
		)

	spark_timer += delta
	if welder_arc_light != null and welder_arc_light.visible:
		welder_arc_light.light_energy = lerpf(welder_arc_light.light_energy, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		if welder_arc_light.light_energy <= 0.01:
			welder_arc_light.light_energy = 0.0
			welder_arc_light.visible = false

	if spark_timer >= spark_int:
		spark_timer = 0.0
		var use_left: bool = (int(time_accum * 10.0) % 2 == 0)
		var tip: Node3D = welder_tip_l if use_left else welder_tip_r
		if tip != null:
			var wpos: Vector3 = tip.global_position
			_spawn_weld_sparks(wpos)
			if engine != null and engine.mode == CombatEngine.MODE_WORKSHOP:
				engine.sfx_requested.emit("weld_arc", 0.32)
			if welder_arc_light != null:
				welder_arc_light.global_position = wpos
				welder_arc_light.light_energy = 2.6
				welder_arc_light.visible = true

func _init_puff_pool() -> void:
	shared_steam_sph = SphereMesh.new()
	shared_steam_sph.radius = 0.11
	shared_steam_sph.height = 0.22
	shared_steam_sph.radial_segments = 10
	shared_steam_sph.rings = 5
	shared_weld_box = BoxMesh.new()
	shared_weld_box.size = Vector3(0.028, 0.028, 0.07)
	puff_pool.clear()
	for _i: int in range(18):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_steam_sph
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = mat
		mi.visible = false
		vfx_root.add_child(mi)
		puff_pool.append({"node": mi, "mat": mat})

func _claim_puff_slot() -> Dictionary:
	var slot: Dictionary = puff_pool[puff_cursor]
	puff_cursor = (puff_cursor + 1) % puff_pool.size()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	for idx: int in range(active_puffs.size() - 1, -1, -1):
		if active_puffs[idx].get("node") == mi:
			active_puffs.remove_at(idx)
			break
	return slot

func _spawn_steam_puff(world_pos: Vector3) -> void:
	if puff_pool.is_empty():
		return
	var slot: Dictionary = _claim_puff_slot()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
	var base_c: Color = Color(0.68, 0.82, 0.88, 0.46)
	mi.mesh = shared_steam_sph
	mi.position = world_pos
	mi.scale = Vector3.ONE
	mat.albedo_color = base_c
	mi.visible = true
	active_puffs.append({
		"node": mi,
		"mat": mat,
		"vel": Vector3(0.0, 1.15, 0.0),
		"age": 0.0,
		"life": 0.72,
		"grow": 2.4,
		"base_alpha": base_c.a
	})

func _spawn_weld_sparks(world_pos: Vector3) -> void:
	if puff_pool.is_empty():
		return
	var spark_col: Color = repo.get_palette_color("selected_glow")
	for i: int in range(5):
		var slot: Dictionary = _claim_puff_slot()
		var mi: MeshInstance3D = slot["node"] as MeshInstance3D
		var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
		mi.mesh = shared_weld_box
		mi.position = world_pos
		mi.scale = Vector3.ONE
		mat.albedo_color = spark_col
		mi.visible = true
		var ang: float = float(i) * 1.25 + time_accum * 3.0
		active_puffs.append({
			"node": mi,
			"mat": mat,
			"vel": Vector3(cos(ang) * 1.8, 1.2 + float(i % 2) * 0.6, sin(ang) * 1.8),
			"age": 0.0,
			"life": 0.28,
			"grow": 0.4,
			"base_alpha": 1.0,
			"gravity": 7.5
		})

func _update_vfx(delta: float, tunnel_spd: float) -> void:
	for idx: int in range(active_puffs.size() - 1, -1, -1):
		var item: Dictionary = active_puffs[idx]
		var node: MeshInstance3D = item.get("node") as MeshInstance3D
		if node == null or not is_instance_valid(node):
			active_puffs.remove_at(idx)
			continue
		var age: float = float(item.get("age", 0.0)) + delta
		var life: float = maxf(0.05, float(item.get("life", 0.5)))
		if age >= life:
			node.visible = false
			active_puffs.remove_at(idx)
			continue
		item["age"] = age
		var vel: Vector3 = item.get("vel", Vector3.ZERO) as Vector3
		var grav: float = float(item.get("gravity", 0.0))
		if grav > 0.0:
			vel.y -= grav * delta
			item["vel"] = vel
		node.position += (vel + Vector3(0.0, 0.0, tunnel_spd * 0.6)) * delta
		var t: float = age / life
		var grow: float = float(item.get("grow", 1.0))
		node.scale = Vector3.ONE * lerpf(1.0, maxf(0.2, grow), t)
		var mat: StandardMaterial3D = item.get("mat") as StandardMaterial3D
		if mat != null:
			var c: Color = mat.albedo_color
			c.a = float(item.get("base_alpha", 0.5)) * (1.0 - t)
			mat.albedo_color = c
