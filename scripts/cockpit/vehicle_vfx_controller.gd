class_name VehicleVfxController
extends Node3D

const POOL_PROJECTILES: int = 12
const POOL_SPARKS: int = 44
const POOL_FLASHES: int = 6
const POOL_SHOCKWAVES: int = 3
const POOL_PUFFS: int = 10

var repo: GameRepository
var engine: CombatEngine
var cockpit_rig: Node3D
var cockpit_shell: Node3D
var arena_ctrl: DungeonArena3D
var camera_ctrl: CockpitCameraController

var shield_material: ShaderMaterial
var chassis_meshes: Array[MeshInstance3D] = []
var shield_light: OmniLight3D
var impact_light: OmniLight3D
var muzzle_light_l: OmniLight3D
var muzzle_light_r: OmniLight3D

var shared_proj_mesh: BoxMesh
var shared_proj_mat: StandardMaterial3D
var shared_spark_mesh: BoxMesh
var shared_spark_mat: StandardMaterial3D
var shared_flash_mesh: QuadMesh
var shared_flash_mat: StandardMaterial3D
var shared_torus_mesh: TorusMesh
var shared_steam_mesh: SphereMesh
var shared_flame_mesh: SphereMesh

var projectile_pool: Array[MeshInstance3D] = []
var proj_cursor: int = 0
var spark_pool: Array[MeshInstance3D] = []
var spark_cursor: int = 0
var flash_pool: Array[MeshInstance3D] = []
var flash_cursor: int = 0
var shockwave_pool: Array[Dictionary] = []
var shockwave_cursor: int = 0
var puff_pool: Array[Dictionary] = []
var puff_cursor: int = 0
var warmup_root: Node3D
var warmup_frames_left: int = 2

var shield_active: bool = false
var shield_timer: float = 0.0
var shield_duration: float = 0.85
var shield_peak: float = 1.75
var shield_base_color: Color = Color(0.20, 0.76, 1.0, 0.95)

var suspension_stiffness: float = 190.0
var suspension_damping: float = 16.5
var ram_lunge_impulse: Vector3 = Vector3(0.0, -0.28, -0.58)
var ram_pitch_impulse_deg: float = -16.5
var ram_trauma: float = 0.42
var shot_recoil_impulse: Vector3 = Vector3(0.0, 0.035, 0.12)
var shot_pitch_impulse_deg: float = 3.2
var shot_speed: float = 45.0
var boost_squat_impulse: Vector3 = Vector3(0.0, 0.10, 0.24)
var boost_pitch_impulse_deg: float = 7.5

var hood_gun_l: Vector3 = Vector3(-0.46, 0.94, -1.35)
var hood_gun_r: Vector3 = Vector3(0.46, 0.94, -1.35)
var ram_bumper: Vector3 = Vector3(0.0, 0.65, -2.15)
var supercharger_pos: Vector3 = Vector3(0.0, 1.15, -1.48)
var hood_vent_l: Vector3 = Vector3(-0.35, 1.02, -0.92)
var hood_vent_r: Vector3 = Vector3(0.35, 1.02, -0.92)

var chassis_pos_offset: Vector3 = Vector3.ZERO
var chassis_pos_vel: Vector3 = Vector3.ZERO
var chassis_rot_offset_deg: Vector3 = Vector3.ZERO
var chassis_rot_vel_deg: Vector3 = Vector3.ZERO
var external_chassis_roll_deg: float = 0.0
var external_chassis_squat_y: float = 0.0
var smoothed_ext_roll_deg: float = 0.0
var smoothed_ext_squat_y: float = 0.0

var active_projectiles: Array[Dictionary] = []
var active_vfx_nodes: Array[Dictionary] = []
var pending_shots: Array[Dictionary] = []

func initialize(
	repository: GameRepository,
	combat_engine: CombatEngine,
	rig: Node3D,
	shell: Node3D,
	arena: DungeonArena3D,
	camera: CockpitCameraController
) -> void:
	repo = repository
	engine = combat_engine
	cockpit_rig = rig
	cockpit_shell = shell
	arena_ctrl = arena
	camera_ctrl = camera

	_load_config()
	_setup_shield_system()
	_setup_lights()
	_init_vfx_pools_and_warmup()

func _load_config() -> void:
	if repo == null:
		return
	var vcfg: Dictionary = repo.cockpit.get("vehicle_feedback", {}) as Dictionary
	suspension_stiffness = maxf(10.0, float(vcfg.get("suspension_stiffness", 190.0)))
	suspension_damping = maxf(1.0, float(vcfg.get("suspension_damping", 16.5)))
	ram_lunge_impulse = JsonConfigLoader.to_vec3(vcfg.get("ram_lunge_impulse", []), Vector3(0.0, -0.28, -0.58))
	ram_pitch_impulse_deg = float(vcfg.get("ram_pitch_impulse_deg", -16.5))
	ram_trauma = clampf(float(vcfg.get("ram_trauma", 0.42)), 0.0, 1.0)
	shot_recoil_impulse = JsonConfigLoader.to_vec3(vcfg.get("shot_recoil_impulse", []), Vector3(0.0, 0.035, 0.12))
	shot_pitch_impulse_deg = float(vcfg.get("shot_pitch_impulse_deg", 3.2))
	shot_speed = maxf(10.0, float(vcfg.get("shot_projectile_speed", 45.0)))
	boost_squat_impulse = JsonConfigLoader.to_vec3(vcfg.get("boost_squat_impulse", []), Vector3(0.0, 0.10, 0.24))
	boost_pitch_impulse_deg = float(vcfg.get("boost_pitch_impulse_deg", 7.5))
	shield_duration = maxf(0.1, float(vcfg.get("shield_duration_s", 0.85)))
	shield_peak = maxf(0.1, float(vcfg.get("shield_peak_intensity", 1.75)))
	shield_base_color = JsonConfigLoader.to_color(vcfg.get("shield_color", []), Color(0.20, 0.76, 1.0, 0.95))

	hood_gun_l = JsonConfigLoader.to_vec3(vcfg.get("hood_gun_left_pos", []), Vector3(-0.46, 0.94, -1.35))
	hood_gun_r = JsonConfigLoader.to_vec3(vcfg.get("hood_gun_right_pos", []), Vector3(0.46, 0.94, -1.35))
	ram_bumper = JsonConfigLoader.to_vec3(vcfg.get("ram_bumper_pos", []), Vector3(0.0, 0.65, -2.15))
	supercharger_pos = JsonConfigLoader.to_vec3(vcfg.get("supercharger_pos", []), Vector3(0.0, 1.15, -1.48))
	hood_vent_l = JsonConfigLoader.to_vec3(vcfg.get("hood_vent_left_pos", []), Vector3(-0.35, 1.02, -0.92))
	hood_vent_r = JsonConfigLoader.to_vec3(vcfg.get("hood_vent_right_pos", []), Vector3(0.35, 1.02, -0.92))

func _init_vfx_pools_and_warmup() -> void:
	shared_proj_mesh = BoxMesh.new()
	shared_proj_mesh.size = Vector3(0.032, 0.032, 0.42)
	shared_proj_mat = StandardMaterial3D.new()
	shared_proj_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shared_proj_mat.albedo_color = Color(1.0, 0.88, 0.32, 1.0)

	shared_spark_mesh = BoxMesh.new()
	shared_spark_mesh.size = Vector3(0.024, 0.024, 0.065)
	shared_spark_mat = StandardMaterial3D.new()
	shared_spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shared_spark_mat.albedo_color = Color(1.0, 0.90, 0.40, 1.0)

	shared_flash_mesh = QuadMesh.new()
	shared_flash_mesh.size = Vector2(0.24, 0.24)
	shared_flash_mat = StandardMaterial3D.new()
	shared_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shared_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shared_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	shared_flash_mat.albedo_color = Color(1.0, 0.88, 0.35, 0.95)

	shared_torus_mesh = TorusMesh.new()
	shared_torus_mesh.inner_radius = 0.24
	shared_torus_mesh.outer_radius = 0.36
	shared_torus_mesh.rings = 24
	shared_torus_mesh.ring_segments = 12

	shared_steam_mesh = SphereMesh.new()
	shared_steam_mesh.radius = 0.09
	shared_steam_mesh.height = 0.18
	shared_steam_mesh.radial_segments = 12
	shared_steam_mesh.rings = 6

	shared_flame_mesh = SphereMesh.new()
	shared_flame_mesh.radius = 0.12
	shared_flame_mesh.height = 0.24
	shared_flame_mesh.radial_segments = 12
	shared_flame_mesh.rings = 6

	for _i: int in range(POOL_PROJECTILES):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_proj_mesh
		mi.material_override = shared_proj_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		projectile_pool.append(mi)

	for _i: int in range(POOL_SPARKS):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_spark_mesh
		mi.material_override = shared_spark_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		spark_pool.append(mi)

	for _i: int in range(POOL_FLASHES):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_flash_mesh
		mi.material_override = shared_flash_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		flash_pool.append(mi)

	for _i: int in range(POOL_SHOCKWAVES):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_torus_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = Color(1.0, 0.85, 0.45, 0.9)
		mi.material_override = mat
		mi.visible = false
		add_child(mi)
		shockwave_pool.append({"node": mi, "mat": mat})

	for _i: int in range(POOL_PUFFS):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = shared_steam_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = Color(0.35, 0.85, 1.0, 0.65)
		mi.material_override = mat
		mi.visible = false
		add_child(mi)
		puff_pool.append({"node": mi, "mat": mat})

	# Pre-warm WebGL shaders on tiny hidden frustum meshes at boot to avoid first-card stutters
	warmup_root = Node3D.new()
	warmup_root.position = Vector3(0.0, 0.95, -0.75)
	warmup_root.scale = Vector3.ONE * 0.0002
	add_child(warmup_root)

	var w_shield: MeshInstance3D = MeshInstance3D.new()
	w_shield.mesh = shared_proj_mesh
	w_shield.material_override = shared_proj_mat
	if shield_material != null:
		w_shield.material_overlay = shield_material
	warmup_root.add_child(w_shield)

	var w_add: MeshInstance3D = MeshInstance3D.new()
	w_add.mesh = shared_flash_mesh
	w_add.material_override = shared_flash_mat
	warmup_root.add_child(w_add)
	warmup_frames_left = 2

func set_cockpit_shell(new_shell: Node3D) -> void:
	cockpit_shell = new_shell
	_setup_shield_system()

func set_external_turn_pose(roll_deg: float, squat_y: float) -> void:
	external_chassis_roll_deg = roll_deg
	external_chassis_squat_y = squat_y

func _setup_shield_system() -> void:
	if shield_material == null:
		var shader_res: Shader = load("res://shaders/chassis_shield.gdshader") as Shader
		if shader_res != null:
			shield_material = ShaderMaterial.new()
			shield_material.shader = shader_res
			shield_material.set_shader_parameter("shield_color", shield_base_color)
			shield_material.set_shader_parameter("shield_intensity", 0.0)

	chassis_meshes.clear()
	if cockpit_shell == null:
		return
	var targets: Array[String] = [
		"RollBarLeft", "RollBarRight", "RollBarTop",
		"PillarLeft", "PillarRight", "RoofHeader",
		"VisorArmorPlate", "LeftDoorArmor", "RightDoorArmor",
		"FloorRib_0", "FloorRib_1", "FloorRib_2", "FloorRib_3", "FloorRib_4", "FloorRib_5",
		"FrontRamBar", "RamSpike_0", "RamSpike_1", "RamSpike_2", "RamSpike_3",
		"ExteriorHood", "HoodPowerBulge", "DozerBladeWingL", "DozerBladeWingR",
		"AeroCanardL", "AeroCanardR", "IntercoolerCore"
	]
	for t_name: String in targets:
		var n: Node = cockpit_shell.find_child(t_name, true, false)
		if n is MeshInstance3D:
			chassis_meshes.append(n as MeshInstance3D)

func _setup_lights() -> void:
	shield_light = OmniLight3D.new()
	shield_light.position = Vector3(0.0, 1.25, -0.30)
	shield_light.light_color = shield_base_color
	shield_light.light_energy = 0.0
	shield_light.omni_range = 3.2
	shield_light.visible = false
	if cockpit_rig != null:
		cockpit_rig.add_child(shield_light)
	else:
		add_child(shield_light)

	impact_light = OmniLight3D.new()
	impact_light.position = ram_bumper + Vector3(0.0, 0.20, 0.15)
	impact_light.light_color = Color(1.0, 0.88, 0.52)
	impact_light.light_energy = 0.0
	impact_light.omni_range = 4.2
	impact_light.visible = false
	add_child(impact_light)

	muzzle_light_l = OmniLight3D.new()
	muzzle_light_l.position = hood_gun_l
	muzzle_light_l.light_color = Color(1.0, 0.84, 0.36)
	muzzle_light_l.light_energy = 0.0
	muzzle_light_l.omni_range = 2.4
	muzzle_light_l.visible = false
	add_child(muzzle_light_l)

	muzzle_light_r = OmniLight3D.new()
	muzzle_light_r.position = hood_gun_r
	muzzle_light_r.light_color = Color(1.0, 0.84, 0.36)
	muzzle_light_r.light_energy = 0.0
	muzzle_light_r.omni_range = 2.4
	muzzle_light_r.visible = false
	add_child(muzzle_light_r)

func on_card_played(card_data: Dictionary, target_index: int) -> void:
	var is_ram_act: bool = bool(card_data.get("is_ram", false)) or str(card_data.get("category", "")) in ["Ram", "Speronamento"]
	var has_block: bool = int(card_data.get("block", 0)) > 0 or str(card_data.get("category", "")) in ["Defense", "Difesa"]
	var is_ranged_act: bool = bool(card_data.get("is_ranged", false)) or str(card_data.get("category", "")) in ["Attack", "Attacco"] or (int(card_data.get("damage", 0)) > 0 and not is_ram_act)
	var is_cool_act: bool = int(card_data.get("heat_delta", 0)) < 0 or str(card_data.get("category", "")) in ["Cooling", "Raffreddamento"]
	var is_boost_act: bool = int(card_data.get("rpm_delta_units", 0)) >= 2 or str(card_data.get("category", "")) in ["Power", "Potenza", "Utility"]

	if is_ram_act:
		trigger_ram_feedback()
	if has_block:
		trigger_shield_feedback()
	if is_ranged_act:
		trigger_shooting_feedback(card_data, target_index)
	if is_cool_act:
		trigger_cooling_feedback()
	if is_boost_act and not is_ram_act:
		trigger_boost_feedback()

func trigger_ram_feedback() -> void:
	chassis_pos_vel += ram_lunge_impulse
	chassis_rot_vel_deg += Vector3(ram_pitch_impulse_deg, 0.0, (randf() - 0.5) * 6.0)
	if camera_ctrl != null:
		camera_ctrl.add_trauma(ram_trauma)
	if impact_light != null:
		impact_light.light_energy = 5.5
		impact_light.visible = true
	_spawn_shockwave(ram_bumper)
	_spawn_spark_burst(ram_bumper + Vector3(0.0, 0.25, 0.1), 16, Vector3(0.0, 2.2, 3.8), 2.8)

func trigger_shield_feedback() -> void:
	var was_active: bool = shield_active
	shield_active = true
	shield_timer = 0.0
	if shield_material != null:
		shield_material.set_shader_parameter("shield_intensity", shield_peak)
		if not was_active:
			for mesh_inst: MeshInstance3D in chassis_meshes:
				if mesh_inst != null and is_instance_valid(mesh_inst):
					mesh_inst.material_overlay = shield_material
	if shield_light != null:
		shield_light.light_energy = 2.4
		shield_light.visible = true

func trigger_shooting_feedback(card_data: Dictionary, target_index: int) -> void:
	var hits_count: int = maxi(1, int(card_data.get("hits", 1)))
	var total_shots: int = maxi(2, hits_count * 2)
	var target_pos: Vector3 = Vector3(0.0, 0.8, -5.8)
	if arena_ctrl != null:
		var target_idx: int = target_index
		if target_idx < 0 and engine != null:
			target_idx = engine.first_alive_enemy_index()
		target_pos = arena_ctrl.get_enemy_world_position(target_idx)

	for s: int in range(total_shots):
		var is_left: bool = (s % 2 == 0)
		var muzzle_pos: Vector3 = hood_gun_l if is_left else hood_gun_r
		pending_shots.append({
			"delay": float(s) * 0.065,
			"muzzle_pos": muzzle_pos,
			"target_pos": target_pos + Vector3((randf() - 0.5) * 0.32, (randf() - 0.5) * 0.24, 0.0),
			"is_left": is_left,
			"target_index": target_index
		})

func trigger_cooling_feedback() -> void:
	chassis_pos_vel += Vector3(0.0, 0.07, 0.0)
	chassis_rot_vel_deg += Vector3(2.5, 0.0, 0.0)
	_spawn_steam_puff(hood_vent_l)
	_spawn_steam_puff(hood_vent_r)

func trigger_boost_feedback() -> void:
	chassis_pos_vel += boost_squat_impulse
	chassis_rot_vel_deg += Vector3(boost_pitch_impulse_deg, 0.0, 0.0)
	_spawn_flame_burst(supercharger_pos)

func _process(delta: float) -> void:
	if warmup_frames_left > 0:
		warmup_frames_left -= 1
		if warmup_frames_left == 0 and warmup_root != null:
			warmup_root.visible = false
	_update_chassis_physics(delta)
	_update_shield(delta)
	_update_pending_shots(delta)
	_update_projectiles(delta)
	_update_vfx_nodes(delta)
	_update_lights_decay(delta)

func _update_chassis_physics(delta: float) -> void:
	if cockpit_rig == null:
		return
	var dt: float = minf(delta, 0.033)
	var pos_acc: Vector3 = -chassis_pos_offset * suspension_stiffness - chassis_pos_vel * suspension_damping
	chassis_pos_vel += pos_acc * dt
	chassis_pos_offset += chassis_pos_vel * dt

	var rot_acc: Vector3 = -chassis_rot_offset_deg * suspension_stiffness - chassis_rot_vel_deg * suspension_damping
	chassis_rot_vel_deg += rot_acc * dt
	chassis_rot_offset_deg += chassis_rot_vel_deg * dt

	var blend: float = clampf(dt * 9.5, 0.0, 1.0)
	smoothed_ext_roll_deg = lerpf(smoothed_ext_roll_deg, external_chassis_roll_deg, blend)
	smoothed_ext_squat_y = lerpf(smoothed_ext_squat_y, external_chassis_squat_y, blend)

	cockpit_rig.position = chassis_pos_offset + Vector3(0.0, smoothed_ext_squat_y, 0.0)
	cockpit_rig.rotation_degrees = chassis_rot_offset_deg + Vector3(0.0, 0.0, smoothed_ext_roll_deg)

func _update_shield(delta: float) -> void:
	if not shield_active:
		return
	shield_timer += delta
	var progress: float = clampf(shield_timer / shield_duration, 0.0, 1.0)
	var factor: float = maxf(0.0, 1.0 - progress)
	var intensity: float = shield_peak * factor * factor

	if shield_material != null:
		shield_material.set_shader_parameter("shield_intensity", intensity)
	if shield_light != null:
		shield_light.light_energy = intensity * 1.6
		shield_light.visible = shield_light.light_energy > 0.001

	if progress >= 1.0:
		shield_active = false
		if shield_material != null:
			shield_material.set_shader_parameter("shield_intensity", 0.0)
		for mesh_inst: MeshInstance3D in chassis_meshes:
			if mesh_inst != null and is_instance_valid(mesh_inst):
				mesh_inst.material_overlay = null
		if shield_light != null:
			shield_light.light_energy = 0.0
			shield_light.visible = false

func _update_pending_shots(delta: float) -> void:
	for idx: int in range(pending_shots.size() - 1, -1, -1):
		var shot: Dictionary = pending_shots[idx]
		var d: float = float(shot.get("delay", 0.0)) - delta
		if d <= 0.0:
			var m_pos: Vector3 = shot.get("muzzle_pos") as Vector3
			var t_pos: Vector3 = shot.get("target_pos") as Vector3
			var left_s: bool = bool(shot.get("is_left", false))
			var t_idx: int = int(shot.get("target_index", -1))
			pending_shots.remove_at(idx)
			_fire_single_shot(m_pos, t_pos, left_s, t_idx)
		else:
			shot["delay"] = d

func _claim_pool_vfx_node(target_node: MeshInstance3D) -> void:
	for idx: int in range(active_vfx_nodes.size() - 1, -1, -1):
		if active_vfx_nodes[idx].get("node") == target_node:
			active_vfx_nodes.remove_at(idx)
			break

func _fire_single_shot(muzzle_pos: Vector3, target_pos: Vector3, is_left: bool, target_idx: int) -> void:
	chassis_pos_vel += shot_recoil_impulse
	chassis_rot_vel_deg += Vector3(shot_pitch_impulse_deg, 0.0, -1.2 if is_left else 1.2)

	if is_left and muzzle_light_l != null:
		muzzle_light_l.light_energy = 3.6
		muzzle_light_l.visible = true
	elif not is_left and muzzle_light_r != null:
		muzzle_light_r.light_energy = 3.6
		muzzle_light_r.visible = true

	_spawn_muzzle_flash(muzzle_pos)

	if projectile_pool.is_empty():
		return
	var p_node: MeshInstance3D = projectile_pool[proj_cursor]
	proj_cursor = (proj_cursor + 1) % projectile_pool.size()
	for idx: int in range(active_projectiles.size() - 1, -1, -1):
		if active_projectiles[idx].get("node") == p_node:
			active_projectiles.remove_at(idx)
			break

	p_node.position = muzzle_pos
	p_node.scale = Vector3.ONE
	p_node.visible = true

	var dir: Vector3 = (target_pos - muzzle_pos).normalized()
	if dir.length_squared() > 0.001:
		p_node.look_at(muzzle_pos + dir, Vector3.UP)

	var total_dist: float = (target_pos - muzzle_pos).length()
	active_projectiles.append({
		"node": p_node,
		"pos": muzzle_pos,
		"dir": dir,
		"speed": shot_speed,
		"target_pos": target_pos,
		"dist_left": total_dist,
		"target_idx": target_idx
	})

func _update_projectiles(delta: float) -> void:
	for idx: int in range(active_projectiles.size() - 1, -1, -1):
		var proj: Dictionary = active_projectiles[idx]
		var node: MeshInstance3D = proj.get("node") as MeshInstance3D
		if node == null or not is_instance_valid(node):
			active_projectiles.remove_at(idx)
			continue
		var step: float = float(proj.get("speed", 45.0)) * delta
		var dist_left: float = float(proj.get("dist_left", 0.0)) - step
		if dist_left <= 0.0:
			var t_pos: Vector3 = proj.get("target_pos") as Vector3
			var hit_i: int = int(proj.get("target_idx", -1))
			node.visible = false
			active_projectiles.remove_at(idx)
			_spawn_spark_burst(t_pos, 10, Vector3.ZERO, 2.0)
			if arena_ctrl != null:
				arena_ctrl.trigger_enemy_hit_impact(hit_i)
		else:
			var cur_pos: Vector3 = (proj.get("pos") as Vector3) + (proj.get("dir") as Vector3) * step
			proj["pos"] = cur_pos
			proj["dist_left"] = dist_left
			node.position = cur_pos

func _update_vfx_nodes(delta: float) -> void:
	for idx: int in range(active_vfx_nodes.size() - 1, -1, -1):
		var vfx: Dictionary = active_vfx_nodes[idx]
		var node: MeshInstance3D = vfx.get("node") as MeshInstance3D
		if node == null or not is_instance_valid(node):
			active_vfx_nodes.remove_at(idx)
			continue
		var t: float = float(vfx.get("time", 0.0)) + delta
		var dur: float = float(vfx.get("duration", 0.2))
		if t >= dur:
			node.visible = false
			active_vfx_nodes.remove_at(idx)
			continue
		vfx["time"] = t
		var frac: float = clampf(t / dur, 0.0, 1.0)
		var vtype: String = str(vfx.get("type", ""))
		if vtype == "shockwave":
			var s: float = lerpf(0.25, float(vfx.get("max_scale", 2.6)), frac)
			node.scale = Vector3(s, s, s)
			var sm: StandardMaterial3D = vfx.get("mat") as StandardMaterial3D
			if sm != null:
				var base_c: Color = vfx.get("base_color") as Color
				sm.albedo_color = Color(base_c.r, base_c.g, base_c.b, (1.0 - frac) * base_c.a)
		elif vtype == "particle":
			var vel: Vector3 = vfx.get("vel") as Vector3
			node.position += vel * delta
			node.scale = (vfx.get("base_scale") as Vector3) * (1.0 - frac)
		elif vtype == "puff":
			var vel_p: Vector3 = vfx.get("vel") as Vector3
			node.position += vel_p * delta
			var s_p: float = lerpf(0.08, float(vfx.get("max_scale", 0.45)), frac)
			node.scale = Vector3(s_p, s_p, s_p)
			var sm_p: StandardMaterial3D = vfx.get("mat") as StandardMaterial3D
			if sm_p != null:
				var bc: Color = vfx.get("base_color") as Color
				sm_p.albedo_color = Color(bc.r, bc.g, bc.b, (1.0 - frac) * bc.a)

func _update_lights_decay(delta: float) -> void:
	if impact_light != null and impact_light.light_energy > 0.0:
		impact_light.light_energy = maxf(0.0, impact_light.light_energy - delta * 24.0)
		impact_light.visible = impact_light.light_energy > 0.001
	if muzzle_light_l != null and muzzle_light_l.light_energy > 0.0:
		muzzle_light_l.light_energy = maxf(0.0, muzzle_light_l.light_energy - delta * 32.0)
		muzzle_light_l.visible = muzzle_light_l.light_energy > 0.001
	if muzzle_light_r != null and muzzle_light_r.light_energy > 0.0:
		muzzle_light_r.light_energy = maxf(0.0, muzzle_light_r.light_energy - delta * 32.0)
		muzzle_light_r.visible = muzzle_light_r.light_energy > 0.001

func _spawn_shockwave(pos: Vector3) -> void:
	if shockwave_pool.is_empty():
		return
	var slot: Dictionary = shockwave_pool[shockwave_cursor]
	shockwave_cursor = (shockwave_cursor + 1) % shockwave_pool.size()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
	_claim_pool_vfx_node(mi)
	var base_col: Color = Color(1.0, 0.85, 0.45, 0.9)
	mat.albedo_color = base_col
	mi.position = pos
	mi.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	mi.scale = Vector3.ONE * 0.25
	mi.visible = true
	active_vfx_nodes.append({
		"node": mi,
		"mat": mat,
		"type": "shockwave",
		"time": 0.0,
		"duration": 0.22,
		"max_scale": 2.6,
		"base_color": base_col
	})

func _spawn_spark_burst(center: Vector3, count: int, bias_vel: Vector3, speed: float) -> void:
	if spark_pool.is_empty():
		return
	for _i: int in range(count):
		var sp: MeshInstance3D = spark_pool[spark_cursor]
		spark_cursor = (spark_cursor + 1) % spark_pool.size()
		_claim_pool_vfx_node(sp)
		sp.position = center
		sp.scale = Vector3.ONE
		sp.visible = true

		var rnd_dir: Vector3 = Vector3(
			(randf() - 0.5) * 2.0,
			(randf() - 0.2) * 2.0,
			(randf() - 0.5) * 2.0
		).normalized()
		var vel: Vector3 = (rnd_dir * speed) + bias_vel
		if vel.length_squared() > 0.01:
			sp.look_at(sp.position + vel, Vector3.UP)

		active_vfx_nodes.append({
			"node": sp,
			"type": "particle",
			"vel": vel,
			"base_scale": Vector3.ONE,
			"time": 0.0,
			"duration": randf_range(0.14, 0.24)
		})

func _spawn_muzzle_flash(pos: Vector3) -> void:
	if flash_pool.is_empty():
		return
	var fl: MeshInstance3D = flash_pool[flash_cursor]
	flash_cursor = (flash_cursor + 1) % flash_pool.size()
	_claim_pool_vfx_node(fl)
	fl.position = pos
	fl.rotation_degrees = Vector3.ZERO
	fl.scale = Vector3.ONE
	fl.visible = true
	active_vfx_nodes.append({
		"node": fl,
		"type": "particle",
		"vel": Vector3.ZERO,
		"base_scale": Vector3.ONE,
		"time": 0.0,
		"duration": 0.06
	})

func _spawn_steam_puff(pos: Vector3) -> void:
	if puff_pool.is_empty():
		return
	var slot: Dictionary = puff_pool[puff_cursor]
	puff_cursor = (puff_cursor + 1) % puff_pool.size()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
	_claim_pool_vfx_node(mi)
	var base_col: Color = Color(0.35, 0.85, 1.0, 0.65)
	mi.mesh = shared_steam_mesh
	mat.albedo_color = base_col
	mi.position = pos
	mi.scale = Vector3.ONE * 0.08
	mi.visible = true
	active_vfx_nodes.append({
		"node": mi,
		"mat": mat,
		"type": "puff",
		"vel": Vector3(0.0, 0.9, 0.5),
		"time": 0.0,
		"duration": 0.38,
		"max_scale": 0.38,
		"base_color": base_col
	})

func _spawn_flame_burst(pos: Vector3) -> void:
	if puff_pool.is_empty():
		return
	var slot: Dictionary = puff_pool[puff_cursor]
	puff_cursor = (puff_cursor + 1) % puff_pool.size()
	var mi: MeshInstance3D = slot["node"] as MeshInstance3D
	var mat: StandardMaterial3D = slot["mat"] as StandardMaterial3D
	_claim_pool_vfx_node(mi)
	var base_col: Color = Color(1.0, 0.52, 0.12, 0.85)
	mi.mesh = shared_flame_mesh
	mat.albedo_color = base_col
	mi.position = pos
	mi.scale = Vector3.ONE * 0.08
	mi.visible = true
	active_vfx_nodes.append({
		"node": mi,
		"mat": mat,
		"type": "puff",
		"vel": Vector3(0.0, 1.1, 0.4),
		"time": 0.0,
		"duration": 0.26,
		"max_scale": 0.52,
		"base_color": base_col
	})
