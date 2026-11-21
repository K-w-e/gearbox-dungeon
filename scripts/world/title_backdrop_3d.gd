class_name TitleBackdrop3D
extends Node3D

var repo: GameRepository
var stage_root: Node3D
var title_camera: Camera3D
var turntable_pivot: Node3D
var turntable_rim_mat: StandardMaterial3D
var chassis_holder: Node3D
var chassis_instances: Dictionary = {}
var active_chassis_id: String = ""

var cogwheel_entries: Array[Dictionary] = []
var wall_machinery_entries: Array[Dictionary] = []
var hazard_entries: Array[Dictionary] = []
var fan_blades_node: Node3D
var fan_cable_node: Node3D
var welder_arm_l: Node3D
var welder_arm_r: Node3D
var welder_tip_l: Node3D
var welder_tip_r: Node3D
var welder_base_rot_l: Vector3 = Vector3.ZERO
var welder_base_rot_r: Vector3 = Vector3.ZERO
var welder_arc_light: OmniLight3D
var turntable_glow_light: OmniLight3D
var key_spot_light: SpotLight3D
var rim_spot_light: SpotLight3D
var lamp_materials: Array[StandardMaterial3D] = []

var vfx_root: Node3D
var spark_pool: Array[Dictionary] = []
var steam_pool: Array[Dictionary] = []
var spark_cursor: int = 0
var steam_cursor: int = 0
var spark_timer: float = 0.0
var steam_timer: float = 0.0

var is_active_mode: bool = false
var active_view_mode: String = "main"
var current_cam_pos: Vector3 = Vector3.ZERO
var current_cam_target: Vector3 = Vector3.ZERO
var target_accent_color: Color = Color(1.0, 0.78, 0.24)
var current_accent_color: Color = Color(1.0, 0.78, 0.24)
var activity_boost: float = 0.0
var smoothed_boost: float = 0.0
var ignition_pulse: float = 0.0
var time_accum: float = 0.0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func initialize(repository: GameRepository) -> void:
	if repository == null:
		push_error("TitleBackdrop3D.initialize received null repository")
		return
	repo = repository
	rng.randomize()

	var bcfg: Dictionary = _backdrop_cfg()
	position = JsonConfigLoader.to_vec3(bcfg.get("world_offset", []), Vector3(0.0, -40.0, 0.0))

	stage_root = Node3D.new()
	stage_root.name = "TitleHangarStage"
	add_child(stage_root)

	vfx_root = Node3D.new()
	vfx_root.name = "TitleHangarVfx"
	stage_root.add_child(vfx_root)

	_setup_camera(bcfg)
	_build_floor_and_turntable(bcfg)
	_build_cogwheels(bcfg)
	_build_hangar_props(bcfg)
	_setup_lights(bcfg)
	_init_particle_pools(bcfg)

	set_preview_chassis("interceptor")
	set_view_mode("main", true)
	set_active(false)

func _backdrop_cfg() -> Dictionary:
	if repo == null:
		return {}
	return repo.title_menu_cfg().get("backdrop_3d", {}) as Dictionary

func _setup_camera(bcfg: Dictionary) -> void:
	var ccfg: Dictionary = bcfg.get("camera", {}) as Dictionary
	title_camera = Camera3D.new()
	title_camera.name = "TitleBackdropCamera"
	title_camera.fov = clampf(float(ccfg.get("fov_deg", 48.0)), 32.0, 75.0)
	title_camera.near = maxf(0.02, float(ccfg.get("near_clip", 0.05)))
	title_camera.far = maxf(25.0, float(ccfg.get("far_clip", 80.0)))
	title_camera.current = false
	stage_root.add_child(title_camera)

func _build_floor_and_turntable(bcfg: Dictionary) -> void:
	var fcfg: Dictionary = bcfg.get("floor", {}) as Dictionary
	var floor_sz: Vector2 = JsonConfigLoader.to_vec2(fcfg.get("size_xz", []), Vector2(26.0, 26.0))
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = floor_sz
	floor_mesh.mesh = plane
	var floor_mat: StandardMaterial3D = StandardMaterial3D.new()
	floor_mat.albedo_color = JsonConfigLoader.to_color(fcfg.get("color", []), Color(0.075, 0.07, 0.064))
	floor_mat.metallic = float(fcfg.get("metallic", 0.55))
	floor_mat.roughness = float(fcfg.get("roughness", 0.68))
	floor_mesh.material_override = floor_mat
	stage_root.add_child(floor_mesh)

	var tcfg: Dictionary = bcfg.get("turntable", {}) as Dictionary
	var tt_pos: Vector3 = JsonConfigLoader.to_vec3(tcfg.get("position", []), Vector3(1.15, 0.0, -0.35))
	var tt_rad: float = float(tcfg.get("radius_m", 1.92))
	var tt_h: float = float(tcfg.get("height_m", 0.24))

	var outer_ring: MeshInstance3D = MeshInstance3D.new()
	var outer_cyl: CylinderMesh = CylinderMesh.new()
	var ring_r: float = float(fcfg.get("ring_radius_m", 2.38))
	outer_cyl.top_radius = ring_r
	outer_cyl.bottom_radius = ring_r + 0.14
	outer_cyl.height = float(fcfg.get("ring_height_m", 0.03))
	outer_cyl.radial_segments = 32
	outer_ring.mesh = outer_cyl
	outer_ring.position = tt_pos + Vector3(0.0, outer_cyl.height * 0.5, 0.0)
	var outer_mat: StandardMaterial3D = StandardMaterial3D.new()
	outer_mat.albedo_color = repo.get_palette_color("bezel_metal", Color(0.16, 0.15, 0.13))
	outer_mat.metallic = 0.72
	outer_mat.roughness = 0.42
	outer_ring.material_override = outer_mat
	stage_root.add_child(outer_ring)

	turntable_pivot = Node3D.new()
	turntable_pivot.name = "DynoTurntable"
	turntable_pivot.position = tt_pos
	turntable_pivot.rotation_degrees.y = float(tcfg.get("initial_yaw_deg", 142.0))
	stage_root.add_child(turntable_pivot)

	var deck_mesh: MeshInstance3D = MeshInstance3D.new()
	var deck_cyl: CylinderMesh = CylinderMesh.new()
	deck_cyl.top_radius = tt_rad
	deck_cyl.bottom_radius = tt_rad + 0.08
	deck_cyl.height = tt_h
	deck_cyl.radial_segments = 32
	deck_mesh.mesh = deck_cyl
	deck_mesh.position = Vector3(0.0, tt_h * 0.5, 0.0)
	var deck_mat: StandardMaterial3D = StandardMaterial3D.new()
	deck_mat.albedo_color = Color(0.14, 0.13, 0.12)
	deck_mat.metallic = 0.76
	deck_mat.roughness = 0.38
	deck_mesh.material_override = deck_mat
	turntable_pivot.add_child(deck_mesh)

	turntable_rim_mat = StandardMaterial3D.new()
	turntable_rim_mat.albedo_color = repo.get_palette_color("mfd_accent", Color(1.0, 0.78, 0.24))
	turntable_rim_mat.emission_enabled = true
	turntable_rim_mat.emission = turntable_rim_mat.albedo_color
	turntable_rim_mat.emission_energy_multiplier = 1.6

	var seg_count: int = maxi(8, int(tcfg.get("ring_segments", 16)))
	var seg_box: BoxMesh = BoxMesh.new()
	seg_box.size = Vector3(0.32, 0.045, 0.09)
	for si: int in range(seg_count):
		var ang: float = (TAU * float(si)) / float(seg_count)
		var seg_inst: MeshInstance3D = MeshInstance3D.new()
		seg_inst.mesh = seg_box
		seg_inst.position = Vector3(cos(ang) * (tt_rad - 0.04), tt_h + 0.015, sin(ang) * (tt_rad - 0.04))
		seg_inst.rotation.y = -ang + PI * 0.5
		seg_inst.material_override = turntable_rim_mat
		seg_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		turntable_pivot.add_child(seg_inst)

	var lamp_scene: PackedScene = repo.load_model_scene("warning_lamp")
	var lamp_count: int = maxi(3, int(tcfg.get("lamp_count", 6)))
	var lamp_rad: float = float(tcfg.get("lamp_radius_m", 1.72))
	lamp_materials.clear()
	for li: int in range(lamp_count):
		var l_ang: float = (TAU * float(li)) / float(lamp_count) + 0.26
		var l_pos: Vector3 = Vector3(cos(l_ang) * lamp_rad, tt_h + 0.02, sin(l_ang) * lamp_rad)
		if lamp_scene != null:
			var l_inst: Node3D = lamp_scene.instantiate() as Node3D
			l_inst.position = l_pos
			l_inst.scale = Vector3(1.5, 1.5, 1.5)
			turntable_pivot.add_child(l_inst)
		var bulb: MeshInstance3D = MeshInstance3D.new()
		var sph: SphereMesh = SphereMesh.new()
		sph.radius = 0.055
		sph.height = 0.11
		bulb.mesh = sph
		bulb.position = l_pos + Vector3(0.0, 0.07, 0.0)
		var lmat: StandardMaterial3D = StandardMaterial3D.new()
		lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lmat.albedo_color = turntable_rim_mat.albedo_color
		bulb.material_override = lmat
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		turntable_pivot.add_child(bulb)
		lamp_materials.append(lmat)

	chassis_holder = Node3D.new()
	chassis_holder.name = "ChassisShowcaseHolder"
	chassis_holder.position = JsonConfigLoader.to_vec3(tcfg.get("chassis_offset", []), Vector3(0.0, 0.24, 0.0))
	chassis_holder.scale = JsonConfigLoader.to_vec3(tcfg.get("chassis_scale", []), Vector3(0.92, 0.92, 0.92))
	turntable_pivot.add_child(chassis_holder)

func _build_cogwheels(bcfg: Dictionary) -> void:
	cogwheel_entries.clear()
	var cogs_cfg: Array = bcfg.get("cogwheels", []) as Array
	for entry_v: Variant in cogs_cfg:
		if typeof(entry_v) != TYPE_DICTIONARY:
			continue
		var cdef: Dictionary = entry_v as Dictionary
		var pivot: Node3D = Node3D.new()
		pivot.position = JsonConfigLoader.to_vec3(cdef.get("pos", []), Vector3(0.0, 2.0, -5.0))
		pivot.rotation_degrees = JsonConfigLoader.to_vec3(cdef.get("rot_deg", []), Vector3.ZERO)
		stage_root.add_child(pivot)

		var rotor: Node3D = Node3D.new()
		pivot.add_child(rotor)

		var rad: float = maxf(0.4, float(cdef.get("radius", 1.5)))
		var thick: float = maxf(0.1, float(cdef.get("thickness", 0.28)))
		var teeth: int = clampi(int(cdef.get("teeth", 12)), 6, 28)
		var tooth_d: float = maxf(0.08, float(cdef.get("tooth_depth", 0.25)))

		var metal_mat: StandardMaterial3D = StandardMaterial3D.new()
		metal_mat.albedo_color = JsonConfigLoader.to_color(cdef.get("color", []), Color(0.24, 0.20, 0.16))
		metal_mat.metallic = float(cdef.get("metallic", 0.78))
		metal_mat.roughness = float(cdef.get("roughness", 0.42))

		var rim_mesh: MeshInstance3D = MeshInstance3D.new()
		var rim_cyl: CylinderMesh = CylinderMesh.new()
		rim_cyl.top_radius = rad
		rim_cyl.bottom_radius = rad
		rim_cyl.height = thick
		rim_cyl.radial_segments = 24
		rim_mesh.mesh = rim_cyl
		rim_mesh.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		rim_mesh.material_override = metal_mat
		rotor.add_child(rim_mesh)

		var hub_mesh: MeshInstance3D = MeshInstance3D.new()
		var hub_cyl: CylinderMesh = CylinderMesh.new()
		hub_cyl.top_radius = rad * 0.34
		hub_cyl.bottom_radius = rad * 0.34
		hub_cyl.height = thick * 1.48
		hub_cyl.radial_segments = 16
		hub_mesh.mesh = hub_cyl
		hub_mesh.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		hub_mesh.material_override = metal_mat
		rotor.add_child(hub_mesh)

		var tooth_w: float = (TAU * rad / float(teeth)) * 0.46
		var tooth_box: BoxMesh = BoxMesh.new()
		tooth_box.size = Vector3(tooth_w, tooth_d, thick * 0.92)
		for ti: int in range(teeth):
			var ang: float = (TAU * float(ti)) / float(teeth)
			var t_inst: MeshInstance3D = MeshInstance3D.new()
			t_inst.mesh = tooth_box
			var r_mid: float = rad + tooth_d * 0.42
			t_inst.position = Vector3(cos(ang) * r_mid, sin(ang) * r_mid, 0.0)
			t_inst.rotation.z = ang - PI * 0.5
			t_inst.material_override = metal_mat
			rotor.add_child(t_inst)

		if bool(cdef.get("accent_rim", false)):
			var trim_mesh: MeshInstance3D = MeshInstance3D.new()
			var trim_cyl: CylinderMesh = CylinderMesh.new()
			trim_cyl.top_radius = rad * 0.72
			trim_cyl.bottom_radius = rad * 0.72
			trim_cyl.height = thick * 1.12
			trim_cyl.radial_segments = 24
			trim_mesh.mesh = trim_cyl
			trim_mesh.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			var trim_mat: StandardMaterial3D = StandardMaterial3D.new()
			trim_mat.albedo_color = repo.get_palette_color("bezel_trim", Color(0.7, 0.52, 0.2))
			trim_mat.metallic = 0.85
			trim_mat.roughness = 0.32
			trim_mesh.material_override = trim_mat
			rotor.add_child(trim_mesh)

		cogwheel_entries.append({
			"rotor": rotor,
			"speed": float(cdef.get("speed_deg_per_sec", 12.0))
		})

func _build_hangar_props(bcfg: Dictionary) -> void:
	var pcfg: Dictionary = bcfg.get("props", {}) as Dictionary

	var bay_scene: PackedScene = repo.load_model_scene("prop_workshop_bay")
	if bay_scene != null:
		var bay: Node3D = bay_scene.instantiate() as Node3D
		bay.position = JsonConfigLoader.to_vec3(pcfg.get("workshop_bay_pos", []), Vector3(1.15, 0.0, -1.65))
		bay.rotation_degrees = JsonConfigLoader.to_vec3(pcfg.get("workshop_bay_rot_deg", []), Vector3(0.0, -12.0, 0.0))
		bay.scale = JsonConfigLoader.to_vec3(pcfg.get("workshop_bay_scale", []), Vector3(1.08, 1.08, 1.08))
		stage_root.add_child(bay)
		welder_arm_l = bay.find_child("WelderArmL", true, false) as Node3D
		welder_arm_r = bay.find_child("WelderArmR", true, false) as Node3D
		welder_tip_l = bay.find_child("WelderTipL", true, false) as Node3D
		welder_tip_r = bay.find_child("WelderTipR", true, false) as Node3D
		if welder_arm_l != null:
			welder_base_rot_l = welder_arm_l.rotation_degrees
		if welder_arm_r != null:
			welder_base_rot_r = welder_arm_r.rotation_degrees

	var fan_scene: PackedScene = repo.load_model_scene("prop_ceiling_fan_duct")
	if fan_scene != null:
		var fan: Node3D = fan_scene.instantiate() as Node3D
		fan.position = JsonConfigLoader.to_vec3(pcfg.get("ceiling_fan_pos", []), Vector3(1.15, 4.15, -0.6))
		fan.scale = JsonConfigLoader.to_vec3(pcfg.get("ceiling_fan_scale", []), Vector3(1.15, 1.15, 1.15))
		stage_root.add_child(fan)
		fan_blades_node = fan.find_child("FanBlades", true, false) as Node3D
		fan_cable_node = fan.find_child("SwingingCable", true, false) as Node3D

	wall_machinery_entries.clear()
	var mach_scene: PackedScene = repo.load_model_scene("prop_wall_machinery")
	if mach_scene != null:
		var wm_list: Array = pcfg.get("wall_machinery", []) as Array
		for idx: int in range(wm_list.size()):
			if typeof(wm_list[idx]) != TYPE_DICTIONARY:
				continue
			var wdef: Dictionary = wm_list[idx] as Dictionary
			var inst: Node3D = mach_scene.instantiate() as Node3D
			inst.position = JsonConfigLoader.to_vec3(wdef.get("pos", []), Vector3.ZERO)
			inst.rotation_degrees = JsonConfigLoader.to_vec3(wdef.get("rot_deg", []), Vector3.ZERO)
			stage_root.add_child(inst)
			var p_rod: Node3D = inst.find_child("PistonRod", true, false) as Node3D
			wall_machinery_entries.append({
				"gear_large": inst.find_child("GearLarge", true, false) as Node3D,
				"gear_small": inst.find_child("GearSmall", true, false) as Node3D,
				"piston": p_rod,
				"piston_base_y": p_rod.position.y if p_rod != null else 1.15,
				"phase": float(idx) * 1.6
			})

	hazard_entries.clear()
	var haz_scene: PackedScene = repo.load_model_scene("prop_roadside_hazard")
	if haz_scene != null:
		var h_list: Array = pcfg.get("hazard_beacons", []) as Array
		for h_idx: int in range(h_list.size()):
			if typeof(h_list[h_idx]) != TYPE_DICTIONARY:
				continue
			var hdef: Dictionary = h_list[h_idx] as Dictionary
			var h_inst: Node3D = haz_scene.instantiate() as Node3D
			h_inst.position = JsonConfigLoader.to_vec3(hdef.get("pos", []), Vector3.ZERO)
			h_inst.rotation_degrees = JsonConfigLoader.to_vec3(hdef.get("rot_deg", []), Vector3.ZERO)
			stage_root.add_child(h_inst)
			hazard_entries.append({
				"gyro": h_inst.find_child("HazardGyroLight", true, false) as Node3D,
				"nozzle": h_inst.find_child("SteamNozzle", true, false) as Node3D
			})

func _setup_lights(bcfg: Dictionary) -> void:
	var lcfg: Dictionary = bcfg.get("lights", {}) as Dictionary

	key_spot_light = SpotLight3D.new()
	key_spot_light.position = JsonConfigLoader.to_vec3(lcfg.get("key_spot_pos", []), Vector3(-1.2, 4.4, 3.2))
	key_spot_light.light_color = JsonConfigLoader.to_color(lcfg.get("key_spot_color", []), Color(1.0, 0.84, 0.58))
	key_spot_light.light_energy = float(lcfg.get("key_spot_energy", 6.2))
	key_spot_light.spot_range = float(lcfg.get("key_spot_range", 18.0))
	key_spot_light.spot_angle = float(lcfg.get("key_spot_angle", 44.0))
	stage_root.add_child(key_spot_light)
	key_spot_light.look_at_from_position(
		stage_root.to_global(key_spot_light.position),
		stage_root.to_global(JsonConfigLoader.to_vec3(lcfg.get("key_spot_target", []), Vector3(1.15, 0.9, -0.35))),
		Vector3.UP
	)

	rim_spot_light = SpotLight3D.new()
	rim_spot_light.position = JsonConfigLoader.to_vec3(lcfg.get("rim_spot_pos", []), Vector3(4.4, 3.2, -3.8))
	rim_spot_light.light_color = JsonConfigLoader.to_color(lcfg.get("rim_spot_color", []), Color(0.46, 0.80, 1.0))
	rim_spot_light.light_energy = float(lcfg.get("rim_spot_energy", 4.8))
	rim_spot_light.spot_range = float(lcfg.get("rim_spot_range", 16.0))
	rim_spot_light.spot_angle = float(lcfg.get("rim_spot_angle", 52.0))
	stage_root.add_child(rim_spot_light)
	rim_spot_light.look_at_from_position(
		stage_root.to_global(rim_spot_light.position),
		stage_root.to_global(JsonConfigLoader.to_vec3(lcfg.get("rim_spot_target", []), Vector3(1.15, 1.0, -0.35))),
		Vector3.UP
	)

	var gear_light: OmniLight3D = OmniLight3D.new()
	gear_light.position = JsonConfigLoader.to_vec3(lcfg.get("gear_back_light_pos", []), Vector3(1.4, 2.4, -3.6))
	gear_light.light_color = JsonConfigLoader.to_color(lcfg.get("gear_back_light_color", []), Color(1.0, 0.56, 0.18))
	gear_light.light_energy = float(lcfg.get("gear_back_light_energy", 3.4))
	gear_light.omni_range = float(lcfg.get("gear_back_light_range", 11.0))
	stage_root.add_child(gear_light)

	turntable_glow_light = OmniLight3D.new()
	turntable_glow_light.position = JsonConfigLoader.to_vec3(lcfg.get("turntable_glow_offset", []), Vector3(0.0, 0.55, 0.0))
	turntable_glow_light.light_color = current_accent_color
	turntable_glow_light.light_energy = float(lcfg.get("turntable_glow_energy", 2.1))
	turntable_glow_light.omni_range = float(lcfg.get("turntable_glow_range", 5.2))
	turntable_pivot.add_child(turntable_glow_light)

	welder_arc_light = OmniLight3D.new()
	welder_arc_light.position = Vector3(1.15, 1.9, -1.1)
	welder_arc_light.light_color = repo.get_palette_color("fork_left_glow", Color(1.0, 0.76, 0.22))
	welder_arc_light.light_energy = 0.0
	welder_arc_light.omni_range = 6.0
	stage_root.add_child(welder_arc_light)

func _init_particle_pools(bcfg: Dictionary) -> void:
	var ptcfg: Dictionary = bcfg.get("particles", {}) as Dictionary
	var spark_count: int = clampi(int(ptcfg.get("spark_pool_size", 24)), 8, 64)
	var steam_count: int = clampi(int(ptcfg.get("steam_pool_size", 12)), 4, 32)

	var spark_box: BoxMesh = BoxMesh.new()
	spark_box.size = Vector3(0.032, 0.032, 0.085)
	var spark_mat: StandardMaterial3D = StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.albedo_color = Color(1.0, 0.74, 0.22)

	spark_pool.clear()
	for _i: int in range(spark_count):
		var sm: MeshInstance3D = MeshInstance3D.new()
		sm.mesh = spark_box
		sm.material_override = spark_mat
		sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sm.visible = false
		vfx_root.add_child(sm)
		spark_pool.append({
			"node": sm,
			"active": false,
			"vel": Vector3.ZERO,
			"age": 0.0,
			"life": 0.5
		})

	var steam_sph: SphereMesh = SphereMesh.new()
	steam_sph.radius = 0.18
	steam_sph.height = 0.36
	steam_pool.clear()
	for _j: int in range(steam_count):
		var stm: MeshInstance3D = MeshInstance3D.new()
		stm.mesh = steam_sph
		var st_mat: StandardMaterial3D = StandardMaterial3D.new()
		st_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		st_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		st_mat.albedo_color = Color(0.76, 0.72, 0.66, 0.0)
		stm.material_override = st_mat
		stm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		stm.visible = false
		vfx_root.add_child(stm)
		steam_pool.append({
			"node": stm,
			"mat": st_mat,
			"active": false,
			"vel": Vector3.ZERO,
			"age": 0.0,
			"life": 1.6
		})

func set_active(active: bool) -> void:
	is_active_mode = active
	visible = active
	set_process(active)
	if title_camera != null:
		title_camera.current = active

func set_view_mode(mode_name: String, instant: bool = false) -> void:
	active_view_mode = mode_name
	var preset: Dictionary = _resolve_camera_preset(mode_name)
	var p_pos: Vector3 = JsonConfigLoader.to_vec3(preset.get("pos", []), Vector3(-2.35, 2.28, 4.45))
	var p_look: Vector3 = JsonConfigLoader.to_vec3(preset.get("look_at", []), Vector3(0.55, 1.12, -0.35))
	if instant or current_cam_pos == Vector3.ZERO:
		current_cam_pos = p_pos
		current_cam_target = p_look
		if title_camera != null:
			title_camera.look_at_from_position(stage_root.to_global(current_cam_pos), stage_root.to_global(current_cam_target), Vector3.UP)

func set_activity_boost(boost_01: float) -> void:
	activity_boost = clampf(boost_01, 0.0, 1.5)

func trigger_ignition_pulse() -> void:
	ignition_pulse = 1.0

func set_preview_chassis(chassis_id: String) -> void:
	if repo == null or chassis_holder == null or chassis_id.is_empty():
		return
	var preset: Dictionary = _find_chassis_preset(chassis_id)
	if preset.is_empty():
		return
	active_chassis_id = chassis_id
	target_accent_color = JsonConfigLoader.to_color(
		preset.get("dash_glow_color", preset.get("cabin_light_color", [])),
		repo.get_palette_color("mfd_accent", Color(1.0, 0.78, 0.24))
	)
	if not chassis_instances.has(chassis_id):
		chassis_instances[chassis_id] = _instantiate_chassis_showcase(preset)
	for cid: Variant in chassis_instances.keys():
		var inst: Node3D = chassis_instances[cid] as Node3D
		if inst != null and is_instance_valid(inst):
			inst.visible = (str(cid) == chassis_id)
	ignition_pulse = maxf(ignition_pulse, 0.65)

func _find_chassis_preset(chassis_id: String) -> Dictionary:
	var presets: Array = repo.gameplay().get("chassis_presets", []) as Array
	for pr_v: Variant in presets:
		if typeof(pr_v) == TYPE_DICTIONARY and str((pr_v as Dictionary).get("id", "")) == chassis_id:
			return pr_v as Dictionary
	return presets[0] as Dictionary if (not presets.is_empty() and typeof(presets[0]) == TYPE_DICTIONARY) else {}

func _instantiate_chassis_showcase(preset: Dictionary) -> Node3D:
	var root_n: Node3D = Node3D.new()
	chassis_holder.add_child(root_n)

	var tcfg: Dictionary = _backdrop_cfg().get("turntable", {}) as Dictionary
	var c_model_key: String = str(preset.get("cockpit_model", "cockpit_interior"))
	var c_scene: PackedScene = repo.load_model_scene(c_model_key)
	if c_scene != null:
		root_n.add_child(c_scene.instantiate())

	var s_model_key: String = str(preset.get("steering_model", "steering_wheel"))
	var s_scene: PackedScene = repo.load_model_scene(s_model_key)
	if s_scene != null:
		var steer: Node3D = s_scene.instantiate() as Node3D
		steer.position = JsonConfigLoader.to_vec3(tcfg.get("steering_offset", []), Vector3(-0.30, 1.03, -0.52))
		steer.rotation_degrees = JsonConfigLoader.to_vec3(tcfg.get("steering_rot_deg", []), Vector3(-22.0, 0.0, 0.0))
		root_n.add_child(steer)

	var gate_scene: PackedScene = repo.load_model_scene("gearbox_gate")
	var lever_scene: PackedScene = repo.load_model_scene("shift_lever")
	var shift_pos: Vector3 = JsonConfigLoader.to_vec3(tcfg.get("shifter_offset", []), Vector3(0.52, 0.68, -0.32))
	var shift_scl: Vector3 = JsonConfigLoader.to_vec3(tcfg.get("shifter_scale", []), Vector3(1.05, 1.05, 1.05))
	if gate_scene != null:
		var gate: Node3D = gate_scene.instantiate() as Node3D
		gate.position = shift_pos
		gate.scale = shift_scl
		root_n.add_child(gate)
	if lever_scene != null:
		var lever: Node3D = lever_scene.instantiate() as Node3D
		lever.position = shift_pos + Vector3(0.0, 0.04, 0.0)
		lever.scale = shift_scl
		root_n.add_child(lever)

	return root_n

func get_atmosphere_override() -> Dictionary:
	return _backdrop_cfg().get("environment", {}) as Dictionary

func _resolve_camera_preset(mode_name: String) -> Dictionary:
	var ccfg: Dictionary = _backdrop_cfg().get("camera", {}) as Dictionary
	var presets: Dictionary = ccfg.get("presets", {}) as Dictionary
	if presets.has(mode_name) and typeof(presets[mode_name]) == TYPE_DICTIONARY:
		return presets[mode_name] as Dictionary
	return presets.get("main", {}) as Dictionary

func _process(delta: float) -> void:
	if not is_active_mode or repo == null:
		return
	time_accum += delta
	ignition_pulse = maxf(0.0, ignition_pulse - delta * 2.2)
	smoothed_boost = lerpf(smoothed_boost, activity_boost, clampf(delta * 5.0, 0.0, 1.0))

	var bcfg: Dictionary = _backdrop_cfg()
	_update_camera(delta, bcfg)
	_update_turntable_and_lights(delta, bcfg)
	_update_machinery_and_cogs(delta, bcfg)
	_update_particles(delta, bcfg)

func _update_camera(delta: float, bcfg: Dictionary) -> void:
	if title_camera == null:
		return
	var ccfg: Dictionary = bcfg.get("camera", {}) as Dictionary
	var preset: Dictionary = _resolve_camera_preset(active_view_mode)
	var base_pos: Vector3 = JsonConfigLoader.to_vec3(preset.get("pos", []), Vector3(-2.35, 2.28, 4.45))
	var base_look: Vector3 = JsonConfigLoader.to_vec3(preset.get("look_at", []), Vector3(0.55, 1.12, -0.35))

	var orbit_amp: float = deg_to_rad(float(ccfg.get("orbit_amplitude_deg", 4.5)))
	var orbit_ang: float = sin(time_accum * float(ccfg.get("orbit_speed", 0.24))) * orbit_amp
	var bob_y: float = sin(time_accum * float(ccfg.get("bob_speed", 0.65))) * float(ccfg.get("bob_amplitude_m", 0.045))

	var parallax_x: float = 0.0
	var parallax_y: float = 0.0
	var vp: Viewport = get_viewport()
	if vp != null:
		var vp_sz: Vector2 = vp.get_visible_rect().size
		if vp_sz.x > 1.0 and vp_sz.y > 1.0:
			var mpos: Vector2 = vp.get_mouse_position()
			var nx: float = clampf((mpos.x / vp_sz.x) * 2.0 - 1.0, -1.0, 1.0)
			var ny: float = clampf((mpos.y / vp_sz.y) * 2.0 - 1.0, -1.0, 1.0)
			parallax_x = nx * deg_to_rad(float(ccfg.get("parallax_yaw_deg", 3.4)))
			parallax_y = -ny * deg_to_rad(float(ccfg.get("parallax_pitch_deg", 2.1)))

	var rel: Vector3 = base_pos - base_look
	var rot_y: Vector3 = rel.rotated(Vector3.UP, orbit_ang + parallax_x)
	var goal_pos: Vector3 = base_look + rot_y + Vector3(0.0, bob_y + parallax_y * 1.4, 0.0)

	var t: float = clampf(delta * float(ccfg.get("lerp_speed", 4.2)), 0.0, 1.0)
	current_cam_pos = current_cam_pos.lerp(goal_pos, t)
	current_cam_target = current_cam_target.lerp(base_look, t)
	title_camera.look_at_from_position(stage_root.to_global(current_cam_pos), stage_root.to_global(current_cam_target), Vector3.UP)

func _update_turntable_and_lights(delta: float, bcfg: Dictionary) -> void:
	var tcfg: Dictionary = bcfg.get("turntable", {}) as Dictionary
	var lcfg: Dictionary = bcfg.get("lights", {}) as Dictionary

	if turntable_pivot != null:
		var idle_spd: float = float(tcfg.get("idle_deg_per_sec", 12.0))
		var boost_spd: float = float(tcfg.get("boost_deg_per_sec", 34.0))
		var cur_spd: float = lerpf(idle_spd, boost_spd, clampf(smoothed_boost + ignition_pulse * 0.7, 0.0, 1.0))
		turntable_pivot.rotation_degrees.y = fmod(turntable_pivot.rotation_degrees.y + cur_spd * delta, 360.0)

	var acc_t: float = clampf(delta * float(lcfg.get("accent_lerp_speed", 5.5)), 0.0, 1.0)
	current_accent_color = current_accent_color.lerp(target_accent_color, acc_t)

	if turntable_rim_mat != null:
		turntable_rim_mat.albedo_color = current_accent_color
		turntable_rim_mat.emission = current_accent_color
		turntable_rim_mat.emission_energy_multiplier = 1.4 + smoothed_boost * 0.8 + ignition_pulse * 1.8

	if turntable_glow_light != null:
		turntable_glow_light.light_color = current_accent_color
		turntable_glow_light.light_energy = float(lcfg.get("turntable_glow_energy", 2.1)) + ignition_pulse * 1.8

	for li: int in range(lamp_materials.size()):
		var pulse: float = 0.55 + 0.45 * sin(time_accum * 4.2 + float(li) * 1.05)
		lamp_materials[li].albedo_color = current_accent_color.lerp(Color.WHITE, pulse * 0.35 + ignition_pulse * 0.4)

	if welder_arc_light != null:
		welder_arc_light.light_energy = maxf(0.0, welder_arc_light.light_energy - delta * 14.0)

func _update_machinery_and_cogs(delta: float, bcfg: Dictionary) -> void:
	var pcfg: Dictionary = bcfg.get("props", {}) as Dictionary
	var speed_mult: float = 1.0 + smoothed_boost * 1.15 + ignition_pulse * 1.6

	for entry: Dictionary in cogwheel_entries:
		var rotor: Node3D = entry.get("rotor") as Node3D
		if rotor != null:
			rotor.rotation_degrees.z = fmod(rotor.rotation_degrees.z + float(entry.get("speed", 12.0)) * speed_mult * delta, 360.0)

	if fan_blades_node != null:
		fan_blades_node.rotation_degrees.y = fmod(fan_blades_node.rotation_degrees.y + float(pcfg.get("fan_deg_per_sec", 190.0)) * speed_mult * delta, 360.0)
	if fan_cable_node != null:
		fan_cable_node.rotation_degrees.z = sin(time_accum * float(pcfg.get("cable_sway_speed", 1.9))) * float(pcfg.get("cable_sway_deg", 6.5))

	var w_spd: float = float(pcfg.get("welder_speed", 2.3))
	var w_amp: float = float(pcfg.get("welder_sway_deg", 15.0))
	if welder_arm_l != null:
		welder_arm_l.rotation_degrees.z = welder_base_rot_l.z + sin(time_accum * w_spd) * w_amp
	if welder_arm_r != null:
		welder_arm_r.rotation_degrees.z = welder_base_rot_r.z - sin(time_accum * w_spd + 1.15) * w_amp

	var g_large: float = float(pcfg.get("gear_large_deg_per_sec", 68.0)) * speed_mult
	var g_small: float = float(pcfg.get("gear_small_deg_per_sec", -118.0)) * speed_mult
	var p_stroke: float = float(pcfg.get("piston_stroke_m", 0.22))
	var p_spd: float = float(pcfg.get("piston_speed", 3.6)) * (1.0 + smoothed_boost * 0.6)
	for wm: Dictionary in wall_machinery_entries:
		var gl: Node3D = wm.get("gear_large") as Node3D
		var gs: Node3D = wm.get("gear_small") as Node3D
		var pr: Node3D = wm.get("piston") as Node3D
		if gl != null:
			gl.rotation_degrees.x = fmod(gl.rotation_degrees.x + g_large * delta, 360.0)
		if gs != null:
			gs.rotation_degrees.x = fmod(gs.rotation_degrees.x + g_small * delta, 360.0)
		if pr != null:
			pr.position.y = float(wm.get("piston_base_y", 1.15)) + sin(time_accum * p_spd + float(wm.get("phase", 0.0))) * p_stroke

	var gyro_spd: float = float(pcfg.get("gyro_deg_per_sec", 260.0))
	for hz: Dictionary in hazard_entries:
		var gyro: Node3D = hz.get("gyro") as Node3D
		if gyro != null:
			gyro.rotation_degrees.y = fmod(gyro.rotation_degrees.y + gyro_spd * delta, 360.0)

func _update_particles(delta: float, bcfg: Dictionary) -> void:
	var ptcfg: Dictionary = bcfg.get("particles", {}) as Dictionary
	var spark_iv: float = maxf(0.12, float(ptcfg.get("spark_interval_s", 0.34)))
	var steam_iv: float = maxf(0.35, float(ptcfg.get("steam_interval_s", 1.15)))
	var grav: float = float(ptcfg.get("spark_gravity", 6.8))
	var rise_spd: float = float(ptcfg.get("steam_rise_speed", 0.72))

	spark_timer += delta
	if spark_timer >= spark_iv:
		spark_timer = 0.0
		var tip: Node3D = welder_tip_l if rng.randf() < 0.5 else welder_tip_r
		var origin_local: Vector3 = Vector3(1.15, 1.75, -1.25)
		if tip != null and is_instance_valid(tip):
			origin_local = stage_root.to_local(tip.global_position)
		if welder_arc_light != null:
			welder_arc_light.position = origin_local
			welder_arc_light.light_energy = 4.2
		for _b: int in range(3):
			_spawn_spark(origin_local)

	steam_timer += delta
	if steam_timer >= steam_iv:
		steam_timer = 0.0
		var steam_origin: Vector3 = Vector3(1.15 + rng.randf_range(-1.6, 1.6), 0.15, -0.35 + rng.randf_range(-1.4, 1.4))
		if not hazard_entries.is_empty():
			var hz_pick: Dictionary = hazard_entries[rng.randi_range(0, hazard_entries.size() - 1)]
			var noz: Node3D = hz_pick.get("nozzle") as Node3D
			if noz != null and is_instance_valid(noz):
				steam_origin = stage_root.to_local(noz.global_position)
		_spawn_steam(steam_origin, rise_spd)

	for sp: Dictionary in spark_pool:
		if not bool(sp.get("active", false)):
			continue
		var age: float = float(sp["age"]) + delta
		var life: float = float(sp["life"])
		var node: MeshInstance3D = sp["node"] as MeshInstance3D
		if age >= life:
			sp["active"] = false
			node.visible = false
			continue
		sp["age"] = age
		var vel: Vector3 = sp["vel"] as Vector3
		vel.y -= grav * delta
		sp["vel"] = vel
		node.position += vel * delta
		var s: float = maxf(0.15, 1.0 - (age / life))
		node.scale = Vector3(s, s, s)

	for st: Dictionary in steam_pool:
		if not bool(st.get("active", false)):
			continue
		var age_s: float = float(st["age"]) + delta
		var life_s: float = float(st["life"])
		var snode: MeshInstance3D = st["node"] as MeshInstance3D
		var smat: StandardMaterial3D = st["mat"] as StandardMaterial3D
		if age_s >= life_s:
			st["active"] = false
			snode.visible = false
			continue
		st["age"] = age_s
		snode.position += (st["vel"] as Vector3) * delta
		var ratio: float = age_s / life_s
		var grow: float = 0.7 + ratio * 2.2
		snode.scale = Vector3(grow, grow, grow)
		smat.albedo_color.a = sin(ratio * PI) * 0.22

func _spawn_spark(origin_local: Vector3) -> void:
	if spark_pool.is_empty():
		return
	var sp: Dictionary = spark_pool[spark_cursor]
	spark_cursor = (spark_cursor + 1) % spark_pool.size()
	var node: MeshInstance3D = sp["node"] as MeshInstance3D
	node.position = origin_local
	node.scale = Vector3.ONE
	node.visible = true
	sp["active"] = true
	sp["age"] = 0.0
	sp["life"] = rng.randf_range(0.32, 0.62)
	sp["vel"] = Vector3(rng.randf_range(-1.9, 1.9), rng.randf_range(0.6, 2.4), rng.randf_range(-1.8, 1.8))

func _spawn_steam(origin_local: Vector3, rise_spd: float) -> void:
	if steam_pool.is_empty():
		return
	var st: Dictionary = steam_pool[steam_cursor]
	steam_cursor = (steam_cursor + 1) % steam_pool.size()
	var node: MeshInstance3D = st["node"] as MeshInstance3D
	node.position = origin_local
	node.scale = Vector3(0.7, 0.7, 0.7)
	node.visible = true
	st["active"] = true
	st["age"] = 0.0
	st["life"] = rng.randf_range(1.4, 2.2)
	st["vel"] = Vector3(rng.randf_range(-0.22, 0.22), rise_spd, rng.randf_range(-0.22, 0.22))
