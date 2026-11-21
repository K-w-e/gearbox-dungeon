class_name MainGame
extends Node3D

const VehicleVfxController = preload("res://scripts/cockpit/vehicle_vfx_controller.gd")
const TutorialCtrlScript = preload("res://scripts/core/tutorial_controller.gd")
const TitleBackdropScript = preload("res://scripts/world/title_backdrop_3d.gd")
const MainMenuOverlayScript = preload("res://scripts/ui/main_menu_overlay.gd")
const PILOT_PROFILE_PATH: String = "user://pilot_profile.cfg"

var repo: GameRepository
var engine: CombatEngine
var audio_ctrl: EngineAudioController
var camera_ctrl: CockpitCameraController
var overhead_ctrl: OverheadPod3DController
var terminal_ctrl: DiegeticTerminal3D
var dashboard_ctrl: Dashboard3DController
var shifter_ctrl: Shifter3DController
var hand_ctrl: Hand3DController
var arena_ctrl: DungeonArena3D
var fork_ctrl: RoadFork3DController
var site_ctrl: EncounterSite3DController
var world_props_ctrl: WorldProps3DController
var navigator_ctrl: Navigator3DController
var hud: TacticalHud
var title_backdrop: TitleBackdropScript
var main_menu: MainMenuOverlayScript
var vfx_ctrl: VehicleVfxController
var tutorial_ctrl: TutorialController

var cockpit_rig: Node3D
var cockpit_shell: Node3D
var world_env_res: Environment
var cabin_light: OmniLight3D
var dash_glow_light: OmniLight3D
var headlight_nodes: Array[SpotLight3D] = []
var active_chassis_visual_id: String = ""
var quality_preset_id: String = "high"
var active_biome_id: String = ""

var pressed_card_index: int = -1
var card_press_mouse_pos: Vector2 = Vector2.ZERO
var is_dragging_card: bool = false
var shift_tap_dir: int = 0
var onboarding_seen: bool = false
var last_sim_paused: bool = false
var title_presentation_initialized: bool = false
var last_title_mode: bool = false
var pilot_stats: Dictionary = {}

func _ready() -> void:
	repo = GameRepository.new()
	if not repo.load_all():
		push_error("Critical error: Gearbox-Dungeon failed loading JSON configuration files")
		return

	cockpit_rig = Node3D.new()
	cockpit_rig.name = "CockpitRig"
	add_child(cockpit_rig)

	_setup_environment_and_lights()
	_setup_cockpit_shell()

	engine = CombatEngine.new()
	add_child(engine)

	audio_ctrl = EngineAudioController.new()
	add_child(audio_ctrl)
	audio_ctrl.initialize(repo)

	camera_ctrl = CockpitCameraController.new()
	add_child(camera_ctrl)
	camera_ctrl.initialize(repo)

	arena_ctrl = DungeonArena3D.new()
	add_child(arena_ctrl)

	fork_ctrl = RoadFork3DController.new()
	add_child(fork_ctrl)

	site_ctrl = EncounterSite3DController.new()
	add_child(site_ctrl)

	world_props_ctrl = WorldProps3DController.new()
	add_child(world_props_ctrl)

	overhead_ctrl = OverheadPod3DController.new()
	cockpit_rig.add_child(overhead_ctrl)

	navigator_ctrl = Navigator3DController.new()
	cockpit_rig.add_child(navigator_ctrl)

	terminal_ctrl = DiegeticTerminal3D.new()
	cockpit_rig.add_child(terminal_ctrl)

	dashboard_ctrl = Dashboard3DController.new()
	cockpit_rig.add_child(dashboard_ctrl)

	shifter_ctrl = Shifter3DController.new()
	cockpit_rig.add_child(shifter_ctrl)

	hand_ctrl = Hand3DController.new()
	cockpit_rig.add_child(hand_ctrl)

	hud = TacticalHud.new()
	add_child(hud)

	title_backdrop = TitleBackdropScript.new()
	add_child(title_backdrop)

	main_menu = MainMenuOverlayScript.new()
	add_child(main_menu)

	tutorial_ctrl = TutorialCtrlScript.new()
	add_child(tutorial_ctrl)

	vfx_ctrl = VehicleVfxController.new()
	add_child(vfx_ctrl)

	engine.initialize(repo)
	arena_ctrl.initialize(repo, engine)
	fork_ctrl.initialize(repo, engine)
	site_ctrl.initialize(repo, engine)
	world_props_ctrl.initialize(repo, engine, arena_ctrl, fork_ctrl)
	overhead_ctrl.initialize(repo, engine)
	navigator_ctrl.initialize(repo, engine)
	terminal_ctrl.initialize(repo, engine)
	dashboard_ctrl.initialize(repo, engine)
	shifter_ctrl.initialize(repo, engine)
	hand_ctrl.initialize(repo, engine)
	hud.initialize(repo, engine)
	title_backdrop.initialize(repo)
	main_menu.initialize(repo, engine)
	vfx_ctrl.initialize(repo, engine, cockpit_rig, cockpit_shell, arena_ctrl, camera_ctrl)
	tutorial_ctrl.initialize(repo, engine)

	_connect_signals()
	_load_pilot_profile()
	_sync_realtime_feedback()

func _setup_environment_and_lights() -> void:
	var lcfg: Dictionary = repo.cockpit.get("lighting", {}) as Dictionary
	var world_env: WorldEnvironment = WorldEnvironment.new()
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = JsonConfigLoader.to_color(lcfg.get("background_color", []), Color(0.03, 0.035, 0.045))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = JsonConfigLoader.to_color(lcfg.get("ambient_color", []), Color(0.20, 0.22, 0.26))
	env.ambient_light_energy = float(lcfg.get("ambient_energy", 0.82))
	env.fog_enabled = true
	env.fog_light_color = JsonConfigLoader.to_color(lcfg.get("fog_color", []), Color(0.05, 0.055, 0.07))
	env.fog_density = float(lcfg.get("fog_density", 0.022))
	world_env_res = env
	world_env.environment = env
	add_child(world_env)

	cabin_light = OmniLight3D.new()
	cabin_light.position = JsonConfigLoader.to_vec3(lcfg.get("cabin_light_pos", []), Vector3(0.02, 1.38, -0.14))
	cabin_light.light_color = JsonConfigLoader.to_color(lcfg.get("cabin_light_color", []), Color(1.0, 0.84, 0.62))
	cabin_light.light_energy = float(lcfg.get("cabin_light_energy_on", 1.45))
	cabin_light.omni_range = 3.6
	cockpit_rig.add_child(cabin_light)

	dash_glow_light = OmniLight3D.new()
	dash_glow_light.position = JsonConfigLoader.to_vec3(lcfg.get("dash_glow_pos", []), Vector3(0.05, 0.96, -0.42))
	dash_glow_light.light_color = JsonConfigLoader.to_color(lcfg.get("dash_glow_color", []), Color(0.42, 0.88, 0.76))
	dash_glow_light.light_energy = float(lcfg.get("dash_glow_energy", 0.72))
	dash_glow_light.omni_range = 2.2
	cockpit_rig.add_child(dash_glow_light)

	headlight_nodes.clear()
	for key: String in ["headlight_left_pos", "headlight_right_pos"]:
		var spot: SpotLight3D = SpotLight3D.new()
		spot.position = JsonConfigLoader.to_vec3(lcfg.get(key, []), Vector3(0.0, 0.85, -2.35))
		spot.light_color = JsonConfigLoader.to_color(lcfg.get("headlight_color", []), Color(1.0, 0.92, 0.76))
		spot.light_energy = float(lcfg.get("headlight_energy", 4.4))
		spot.spot_range = float(lcfg.get("headlight_range", 26.0))
		spot.spot_angle = float(lcfg.get("headlight_angle", 46.0))
		spot.rotation_degrees = Vector3(2.0, 0.0, 0.0)
		cockpit_rig.add_child(spot)
		headlight_nodes.append(spot)

func _setup_cockpit_shell(model_key: String = "cockpit_interior") -> void:
	var cockpit_scene: PackedScene = repo.load_model_scene(model_key)
	if cockpit_scene == null:
		return
	if cockpit_shell != null and is_instance_valid(cockpit_shell):
		cockpit_shell.queue_free()
	var shell: Node3D = cockpit_scene.instantiate() as Node3D
	var overrides: Dictionary = repo.cockpit.get("shell_overrides", {}) as Dictionary

	var hide_list: Array = overrides.get("hide_nodes", []) as Array
	for h_name_val: Variant in hide_list:
		var target_node: Node = shell.find_child(str(h_name_val), true, false)
		if target_node != null:
			target_node.queue_free()

	var repos_map: Dictionary = overrides.get("reposition_nodes", {}) as Dictionary
	for node_name: Variant in repos_map.keys():
		var m_node: Node3D = shell.find_child(str(node_name), true, false) as Node3D
		if m_node != null:
			m_node.position = JsonConfigLoader.to_vec3(repos_map[node_name], m_node.position)

	var rot_map: Dictionary = overrides.get("rotate_nodes", {}) as Dictionary
	for node_name_r: Variant in rot_map.keys():
		var r_node: Node3D = shell.find_child(str(node_name_r), true, false) as Node3D
		if r_node != null:
			r_node.rotation_degrees = JsonConfigLoader.to_vec3(rot_map[node_name_r], r_node.rotation_degrees)

	cockpit_shell = shell
	cockpit_rig.add_child(shell)
	cockpit_rig.move_child(shell, 0)

func apply_chassis_visuals(chassis_id: String) -> void:
	if repo == null or engine == null or chassis_id.is_empty():
		return
	if audio_ctrl != null:
		audio_ctrl.set_chassis_profile(chassis_id)
	if chassis_id == active_chassis_visual_id:
		return
	active_chassis_visual_id = chassis_id
	var preset: Dictionary = engine.get_chassis_preset(chassis_id)
	var c_model: String = str(preset.get("cockpit_model", "cockpit_interior"))
	var s_model: String = str(preset.get("steering_model", "steering_wheel"))
	_setup_cockpit_shell(c_model)
	if dashboard_ctrl != null:
		dashboard_ctrl.set_steering_wheel_model(s_model)
	if vfx_ctrl != null:
		vfx_ctrl.set_cockpit_shell(cockpit_shell)
	if cabin_light != null and preset.has("cabin_light_color"):
		cabin_light.light_color = JsonConfigLoader.to_color(preset.get("cabin_light_color", []), cabin_light.light_color)
	if dash_glow_light != null and preset.has("dash_glow_color"):
		dash_glow_light.light_color = JsonConfigLoader.to_color(preset.get("dash_glow_color", []), dash_glow_light.light_color)

func _connect_signals() -> void:
	engine.state_changed.connect(_sync_realtime_feedback)
	engine.sfx_requested.connect(audio_ctrl.trigger_sfx)
	engine.camera_trauma_requested.connect(camera_ctrl.add_trauma)
	engine.card_played_fx.connect(vfx_ctrl.on_card_played)
	engine.run_ended.connect(_on_engine_run_ended)

	shifter_ctrl.hover_info_changed.connect(overhead_ctrl.set_scanner_text)
	dashboard_ctrl.deck_preview_requested.connect(func() -> void:
		terminal_ctrl.toggle_deck_preview()
	)
	dashboard_ctrl.engine_audio_mute_toggled.connect(func(muted: bool) -> void:
		audio_ctrl.set_engine_muted(muted)
		_sync_pause_menu_state()
		_save_pilot_profile()
	)

	hud.fullscreen_toggle_requested.connect(_toggle_fullscreen_mode)
	hud.quit_requested.connect(_on_quit_requested)
	hud.guide_toggle_requested.connect(_toggle_cockpit_guide)
	hud.tour_next_requested.connect(func() -> void: tutorial_ctrl.next_step())
	hud.tour_prev_requested.connect(func() -> void: tutorial_ctrl.prev_step())
	hud.tour_skip_requested.connect(func() -> void: tutorial_ctrl.stop())
	hud.pause_toggle_requested.connect(func() -> void:
		if engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY:
			_cancel_card_interaction()
			_sync_pause_menu_state()
			terminal_ctrl.toggle_pause_menu()
			_sync_pause_simulation_freeze()
	)

	terminal_ctrl.shift_option_selected.connect(func(delta_g: int) -> void:
		engine.resolve_pending_shift_choice(delta_g)
	)
	terminal_ctrl.reward_card_chosen.connect(func(cid: String) -> void:
		engine.select_reward_card(cid)
	)
	terminal_ctrl.workshop_action_pressed.connect(_on_workshop_action)
	terminal_ctrl.title_action_pressed.connect(_on_title_action)
	terminal_ctrl.pause_action_pressed.connect(_on_pause_action)
	terminal_ctrl.chassis_preview_hovered.connect(apply_chassis_visuals)
	terminal_ctrl.restart_requested.connect(func() -> void:
		_cancel_card_interaction()
		overhead_ctrl.set_tutorial_objective("")
		engine.enter_title_screen()
	)
	tutorial_ctrl.objective_changed.connect(func(txt: String) -> void:
		overhead_ctrl.set_tutorial_objective(txt)
	)
	tutorial_ctrl.callout_changed.connect(_on_tour_callout_changed)
	fork_ctrl.lane_hovered_changed.connect(func(lane_idx: int) -> void:
		if navigator_ctrl != null:
			navigator_ctrl.set_external_hovered_fork_option(lane_idx)
	)
	fork_ctrl.steering_feedback_updated.connect(_on_fork_steering_feedback)
	navigator_ctrl.fork_option_hovered.connect(func(opt_idx: int) -> void:
		if fork_ctrl != null:
			fork_ctrl.set_hovered_lane(opt_idx)
	)
	navigator_ctrl.fork_option_clicked.connect(func(opt_idx: int) -> void:
		if fork_ctrl != null:
			fork_ctrl.trigger_lane_choice(opt_idx)
	)

	main_menu.title_action_requested.connect(_on_title_action)
	main_menu.chassis_preview_changed.connect(func(cid: String) -> void:
		if title_backdrop != null:
			title_backdrop.set_preview_chassis(cid)
		apply_chassis_visuals(cid)
	)
	main_menu.view_mode_changed.connect(func(v_mode: String) -> void:
		if title_backdrop != null:
			title_backdrop.set_view_mode(v_mode)
	)
	main_menu.engine_audio_cycle_requested.connect(func() -> void:
		_on_pause_action("cycle_engine_audio")
	)
	main_menu.sfx_audio_cycle_requested.connect(func() -> void:
		_on_pause_action("cycle_sfx_audio")
	)
	main_menu.mute_toggle_requested.connect(func() -> void:
		var next_mute: bool = not audio_ctrl.is_engine_muted()
		audio_ctrl.set_engine_muted(next_mute)
		dashboard_ctrl.sync_audio_mute_state(next_mute)
		_sync_pause_menu_state()
		_save_pilot_profile()
	)
	main_menu.fullscreen_toggle_requested.connect(_toggle_fullscreen_mode)
	main_menu.quality_cycle_requested.connect(func() -> void:
		_on_pause_action("cycle_quality")
	)
	main_menu.quit_requested.connect(_on_quit_requested)
	main_menu.menu_hover_activity.connect(func(boost: float, _gear_slot: int) -> void:
		if title_backdrop != null:
			title_backdrop.set_activity_boost(boost)
	)

func _process(delta: float) -> void:
	_sync_pause_simulation_freeze()
	if not last_sim_paused:
		_update_biome_atmosphere(delta)
	if not last_sim_paused and arena_ctrl != null and fork_ctrl != null:
		arena_ctrl.set_straight_tunnel_suppressed(fork_ctrl.should_suppress_straight_tunnel())
	if tutorial_ctrl != null and tutorial_ctrl.is_active():
		_update_tour_screen_projection()
	if camera_ctrl != null and camera_ctrl.is_camera_moving and not shifter_ctrl.is_dragging_lever and pressed_card_index < 0:
		_update_hover_raycast()

func _resolve_active_biome() -> Dictionary:
	if repo == null:
		return {}
	var lcfg: Dictionary = repo.cockpit.get("lighting", {}) as Dictionary
	var biomes: Array = lcfg.get("biomes", []) as Array
	if biomes.is_empty() or engine == null or engine.mode == CombatEngine.MODE_TITLE:
		return {}
	var is_boss: bool = bool(engine.current_encounter().get("is_boss", false))
	var stg: int = engine.stage_index
	if is_boss:
		for b_val: Variant in biomes:
			if typeof(b_val) == TYPE_DICTIONARY and bool((b_val as Dictionary).get("boss_only", false)):
				return b_val as Dictionary
	for b_val: Variant in biomes:
		if typeof(b_val) != TYPE_DICTIONARY:
			continue
		var bd: Dictionary = b_val as Dictionary
		if bool(bd.get("boss_only", false)):
			continue
		var min_s: int = int(bd.get("min_stage", 0))
		var max_s: int = int(bd.get("max_stage", 99))
		if stg >= min_s and stg <= max_s:
			return bd
	return biomes[0] as Dictionary if typeof(biomes[0]) == TYPE_DICTIONARY else {}

func _update_biome_atmosphere(delta: float) -> void:
	if world_env_res == null or repo == null:
		return
	var lcfg: Dictionary = repo.cockpit.get("lighting", {}) as Dictionary
	var biome: Dictionary = title_backdrop.get_atmosphere_override() if (engine != null and engine.mode == CombatEngine.MODE_TITLE and title_backdrop != null) else _resolve_active_biome()
	var target_id: String = "title_hangar" if (engine != null and engine.mode == CombatEngine.MODE_TITLE) else str(biome.get("id", "default"))
	active_biome_id = target_id
	var target_bg: Color = JsonConfigLoader.to_color(biome.get("background_color", lcfg.get("background_color", [])), Color(0.035, 0.032, 0.028))
	var target_amb: Color = JsonConfigLoader.to_color(biome.get("ambient_color", lcfg.get("ambient_color", [])), Color(0.22, 0.21, 0.19))
	var target_amb_e: float = float(biome.get("ambient_energy", lcfg.get("ambient_energy", 0.84)))
	var target_fog: Color = JsonConfigLoader.to_color(biome.get("fog_color", lcfg.get("fog_color", [])), Color(0.058, 0.052, 0.044))
	var target_fog_d: float = float(biome.get("fog_density", lcfg.get("fog_density", 0.021)))
	var target_hl: Color = JsonConfigLoader.to_color(biome.get("headlight_color", lcfg.get("headlight_color", [])), Color(1.0, 0.9, 0.72))
	var t: float = clampf(delta * float(lcfg.get("biome_lerp_speed", 2.4)), 0.0, 1.0)
	world_env_res.background_color = world_env_res.background_color.lerp(target_bg, t)
	world_env_res.ambient_light_color = world_env_res.ambient_light_color.lerp(target_amb, t)
	world_env_res.ambient_light_energy = lerpf(world_env_res.ambient_light_energy, target_amb_e, t)
	world_env_res.fog_light_color = world_env_res.fog_light_color.lerp(target_fog, t)
	world_env_res.fog_density = lerpf(world_env_res.fog_density, target_fog_d, t)
	for spot: SpotLight3D in headlight_nodes:
		if spot != null and is_instance_valid(spot):
			spot.light_color = spot.light_color.lerp(target_hl, t)

func _get_quality_presets() -> Array:
	if repo == null:
		return []
	return repo.config.get("quality_presets", []) as Array

func _find_quality_preset(preset_id: String) -> Dictionary:
	var presets: Array = _get_quality_presets()
	for p_val: Variant in presets:
		if typeof(p_val) == TYPE_DICTIONARY and str((p_val as Dictionary).get("id", "")) == preset_id:
			return p_val as Dictionary
	return presets[0] as Dictionary if (not presets.is_empty() and typeof(presets[0]) == TYPE_DICTIONARY) else {}

func apply_quality_preset(preset_id: String) -> void:
	var preset: Dictionary = _find_quality_preset(preset_id)
	if preset.is_empty():
		return
	quality_preset_id = str(preset.get("id", "high"))
	var vp: Viewport = get_viewport()
	if vp != null:
		var msaa_idx: int = clampi(int(preset.get("msaa_3d", 2)), 0, 3)
		vp.msaa_3d = msaa_idx as Viewport.MSAA
		vp.scaling_3d_scale = clampf(float(preset.get("scaling_3d_scale", 1.0)), 0.5, 1.0)
	var hl_on: bool = bool(preset.get("headlights_enabled", true))
	for spot: SpotLight3D in headlight_nodes:
		if spot != null and is_instance_valid(spot):
			spot.visible = hl_on
	if world_props_ctrl != null and is_instance_valid(world_props_ctrl):
		var in_title_now: bool = (engine != null and engine.mode == CombatEngine.MODE_TITLE)
		world_props_ctrl.visible = (not in_title_now) and bool(preset.get("props_enabled", true))
	_sync_pause_menu_state()

func cycle_quality_preset() -> String:
	var presets: Array = _get_quality_presets()
	if presets.is_empty():
		return quality_preset_id
	var cur_idx: int = 0
	for i: int in range(presets.size()):
		if typeof(presets[i]) == TYPE_DICTIONARY and str((presets[i] as Dictionary).get("id", "")) == quality_preset_id:
			cur_idx = i
			break
	var next_idx: int = (cur_idx + 1) % presets.size()
	var next_id: String = str((presets[next_idx] as Dictionary).get("id", "high"))
	apply_quality_preset(next_id)
	return quality_preset_id

func _toggle_cockpit_guide() -> void:
	if engine == null or engine.mode != CombatEngine.MODE_COMBAT or terminal_ctrl.is_active():
		return
	_cancel_card_interaction()
	if tutorial_ctrl.is_active():
		tutorial_ctrl.stop()
	else:
		tutorial_ctrl.start()

func _on_tour_callout_changed(step_data: Dictionary, index: int, total: int) -> void:
	if hud == null or camera_ctrl == null:
		return
	if index < 0 or step_data.is_empty():
		hud.hide_tour_callout()
		camera_ctrl.reset_glance()
		return
	camera_ctrl.set_glance_angles(float(step_data.get("yaw", 0.0)), float(step_data.get("pitch", 0.0)))
	hud.show_tour_callout(step_data, index, total)
	_update_tour_screen_projection()

func _update_tour_screen_projection() -> void:
	if hud == null or camera_ctrl == null or camera_ctrl.camera == null or not tutorial_ctrl.is_active():
		return
	var cam: Camera3D = camera_ctrl.camera
	var key: String = tutorial_ctrl.current_step_key()
	var w_pos: Vector3 = Vector3(0.0, 0.9, -0.6)
	var has_sec: bool = false
	var sec_pos: Vector3 = Vector3.ZERO
	match key:
		"cards":
			var mid_i: int = hand_ctrl.card_nodes.size() / 2
			if mid_i >= 0 and mid_i < hand_ctrl.card_nodes.size():
				var c_root: Node3D = hand_ctrl.card_nodes[mid_i].get("root") as Node3D
				if c_root != null and is_instance_valid(c_root):
					w_pos = c_root.global_position + Vector3(0.0, 0.05, 0.0)
				else:
					w_pos = hand_ctrl.global_position + Vector3(0.0, 0.06, 0.0)
			else:
				w_pos = hand_ctrl.global_position + Vector3(0.0, 0.06, 0.0)
		"shifter":
			if shifter_ctrl.lever_pivot != null:
				w_pos = shifter_ctrl.lever_pivot.global_position + Vector3(0.0, 0.08, 0.0)
			else:
				w_pos = shifter_ctrl.global_position + Vector3(0.0, 0.08, 0.0)
		"gauges":
			if dashboard_ctrl.tacho_unit != null:
				w_pos = dashboard_ctrl.tacho_unit.global_position + Vector3(0.01, 0.01, 0.02)
		"enemies":
			w_pos = arena_ctrl.get_enemy_world_position(0) + Vector3(0.0, 0.35, 0.0)
		"overhead":
			w_pos = overhead_ctrl.global_position + Vector3(0.32, -0.02, 0.03)
		"screens":
			if dashboard_ctrl.mfd_screen_mesh != null:
				w_pos = dashboard_ctrl.mfd_screen_mesh.global_position
			has_sec = true
			sec_pos = navigator_ctrl.global_position + Vector3(0.0, 0.0, 0.02)
		"slam":
			if dashboard_ctrl.slam_cap != null:
				w_pos = dashboard_ctrl.slam_cap.global_position + Vector3(0.0, 0.02, 0.0)
	var p_px: Vector2 = cam.unproject_position(w_pos)
	var s_px: Vector2 = cam.unproject_position(sec_pos) if has_sec else Vector2.ZERO
	hud.update_tour_targets(p_px, has_sec, s_px)

func _sync_pause_simulation_freeze() -> void:
	if engine == null or terminal_ctrl == null:
		return
	var paused: bool = terminal_ctrl.is_active() and terminal_ctrl.screen_mode == "pause_menu"
	if paused == last_sim_paused:
		return
	last_sim_paused = paused
	engine.sim_paused = paused
	if camera_ctrl != null:
		camera_ctrl.vibration_paused = paused
	for node_ref: Node in [arena_ctrl, fork_ctrl, site_ctrl, world_props_ctrl, vfx_ctrl, shifter_ctrl, overhead_ctrl, dashboard_ctrl, navigator_ctrl, hand_ctrl]:
		if node_ref != null and is_instance_valid(node_ref):
			node_ref.set_process(not paused)
	_sync_realtime_feedback()

func _on_fork_steering_feedback(
	wheel_deg: float,
	cam_yaw_deg: float,
	roll_deg: float,
	squat_y: float,
	compass_deg: float,
	progress: float
) -> void:
	if dashboard_ctrl != null:
		dashboard_ctrl.set_external_steer_deg(wheel_deg)
	if camera_ctrl != null:
		camera_ctrl.set_external_turn_yaw_deg(cam_yaw_deg)
	if vfx_ctrl != null:
		vfx_ctrl.set_external_turn_pose(roll_deg, squat_y)
	if navigator_ctrl != null:
		navigator_ctrl.set_compass_heading_deg(compass_deg)
		navigator_ctrl.set_route_transition_progress(progress)

func _load_pilot_profile() -> void:
	pilot_stats.clear()
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(PILOT_PROFILE_PATH) == OK:
		onboarding_seen = bool(cfg.get_value("pilot", "onboarding_seen", false))
		terminal_ctrl.selected_overdrive_level = clampi(int(cfg.get_value("pilot", "selected_overdrive", 0)), 0, 5)
		var saved_vol: float = float(cfg.get_value("audio", "master_volume", 1.0))
		var saved_eng_v: float = float(cfg.get_value("audio", "engine_volume", 1.0))
		var saved_sfx_v: float = float(cfg.get_value("audio", "sfx_volume", 1.0))
		var saved_mute: bool = bool(cfg.get_value("audio", "muted", false))
		var saved_quality: String = str(cfg.get_value("graphics", "quality", "high"))
		audio_ctrl.set_master_volume(saved_vol)
		audio_ctrl.set_engine_bus_volume(saved_eng_v)
		audio_ctrl.set_sfx_bus_volume(saved_sfx_v)
		if saved_mute:
			audio_ctrl.set_engine_muted(true)
		dashboard_ctrl.sync_audio_mute_state(audio_ctrl.is_engine_muted())
		apply_quality_preset(saved_quality)
		for pr_v: Variant in (repo.gameplay().get("chassis_presets", []) as Array):
			if typeof(pr_v) == TYPE_DICTIONARY:
				var cid: String = str((pr_v as Dictionary).get("id", ""))
				if not cid.is_empty():
					pilot_stats[cid] = {
						"runs": int(cfg.get_value("stats_" + cid, "runs", 0)),
						"wins": int(cfg.get_value("stats_" + cid, "wins", 0)),
						"best_od": int(cfg.get_value("stats_" + cid, "best_od", 0))
					}
	terminal_ctrl.chassis_stats = pilot_stats.duplicate(true)
	terminal_ctrl.first_boot_tutorial_recommended = not onboarding_seen
	if main_menu != null:
		main_menu.sync_pilot_data(pilot_stats, terminal_ctrl.selected_overdrive_level, not onboarding_seen)
	_sync_pause_menu_state()
	if engine.mode == CombatEngine.MODE_TITLE:
		terminal_ctrl._rebuild_hotspots()

func _save_pilot_profile() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("pilot", "onboarding_seen", onboarding_seen)
	cfg.set_value("pilot", "selected_overdrive", terminal_ctrl.selected_overdrive_level if terminal_ctrl != null else 0)
	cfg.set_value("audio", "master_volume", audio_ctrl.pre_mute_volume if audio_ctrl.is_engine_muted() else audio_ctrl.get_master_volume())
	cfg.set_value("audio", "engine_volume", audio_ctrl.engine_volume)
	cfg.set_value("audio", "sfx_volume", audio_ctrl.sfx_volume)
	cfg.set_value("audio", "muted", audio_ctrl.is_engine_muted())
	cfg.set_value("graphics", "quality", quality_preset_id)
	for cid: Variant in pilot_stats.keys():
		var st: Dictionary = pilot_stats[cid] as Dictionary
		cfg.set_value("stats_" + str(cid), "runs", int(st.get("runs", 0)))
		cfg.set_value("stats_" + str(cid), "wins", int(st.get("wins", 0)))
		cfg.set_value("stats_" + str(cid), "best_od", int(st.get("best_od", 0)))
	cfg.save(PILOT_PROFILE_PATH)

func _record_chassis_run_start(chassis_id: String) -> void:
	var st: Dictionary = (pilot_stats.get(chassis_id, {}) as Dictionary).duplicate()
	st["runs"] = int(st.get("runs", 0)) + 1
	pilot_stats[chassis_id] = st
	if terminal_ctrl != null:
		terminal_ctrl.chassis_stats = pilot_stats.duplicate(true)
	if main_menu != null:
		main_menu.sync_pilot_data(pilot_stats, terminal_ctrl.selected_overdrive_level if terminal_ctrl != null else 0, not onboarding_seen)
	_save_pilot_profile()

func _on_engine_run_ended(victory: bool, _summary: String) -> void:
	if engine == null or engine.tutorial_active:
		return
	var cid: String = engine.selected_chassis_id
	if victory and not cid.is_empty():
		var st: Dictionary = (pilot_stats.get(cid, {}) as Dictionary).duplicate()
		st["wins"] = int(st.get("wins", 0)) + 1
		st["best_od"] = maxi(int(st.get("best_od", 0)), engine.overdrive_level)
		pilot_stats[cid] = st
		if terminal_ctrl != null:
			terminal_ctrl.chassis_stats = pilot_stats.duplicate(true)
		if main_menu != null:
			main_menu.sync_pilot_data(pilot_stats, terminal_ctrl.selected_overdrive_level if terminal_ctrl != null else 0, not onboarding_seen)
		_save_pilot_profile()

func _mark_onboarding_seen() -> void:
	if onboarding_seen and not terminal_ctrl.first_boot_tutorial_recommended:
		return
	onboarding_seen = true
	terminal_ctrl.first_boot_tutorial_recommended = false
	if main_menu != null:
		main_menu.sync_pilot_data(pilot_stats, terminal_ctrl.selected_overdrive_level if terminal_ctrl != null else 0, false)
	_save_pilot_profile()

func _is_fullscreen_active() -> bool:
	if OS.has_feature("web") and JavaScriptBridge.eval("Boolean(document.fullscreenElement || document.webkitFullscreenElement)", true):
		return true
	var wmode: DisplayServer.WindowMode = DisplayServer.window_get_mode()
	return wmode == DisplayServer.WINDOW_MODE_FULLSCREEN or wmode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN

func _exit_web_fullscreen() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("try { if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen(); else if (document.webkitFullscreenElement && document.webkitExitFullscreen) document.webkitExitFullscreen(); } catch(e) {}", true)

func _toggle_fullscreen_mode() -> void:
	if _is_fullscreen_active():
		_exit_web_fullscreen()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_sync_pause_menu_state()

func _sync_pause_menu_state() -> void:
	if terminal_ctrl == null or audio_ctrl == null:
		return
	terminal_ctrl.pause_audio_label = audio_ctrl.format_volume_label()
	terminal_ctrl.pause_engine_audio_label = audio_ctrl.format_engine_volume_label()
	terminal_ctrl.pause_sfx_audio_label = audio_ctrl.format_sfx_volume_label()
	terminal_ctrl.pause_quality_label = str(_find_quality_preset(quality_preset_id).get("label", quality_preset_id.to_upper()))
	terminal_ctrl.pause_fullscreen_active = _is_fullscreen_active()
	if main_menu != null:
		main_menu.sync_settings_labels(
			terminal_ctrl.pause_engine_audio_label,
			terminal_ctrl.pause_sfx_audio_label,
			audio_ctrl.is_engine_muted(),
			terminal_ctrl.pause_fullscreen_active,
			terminal_ctrl.pause_quality_label
		)
	if hud != null:
		var can_pause: bool = engine != null and engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY
		hud.sync_web_bar_state(terminal_ctrl.pause_fullscreen_active, can_pause, engine != null and engine.mode == CombatEngine.MODE_COMBAT)
	if terminal_ctrl.is_active() and terminal_ctrl.screen_mode == "pause_menu":
		terminal_ctrl._rebuild_hotspots()

func _on_pause_action(action_id: String) -> void:
	match action_id:
		"restart_run":
			_sync_pause_simulation_freeze()
			_cancel_card_interaction()
			if engine.tutorial_active:
				tutorial_ctrl.stop()
				engine.start_tutorial_run()
				tutorial_ctrl.start()
			else:
				overhead_ctrl.set_tutorial_objective("")
				_record_chassis_run_start(engine.selected_chassis_id)
				engine.start_new_run(engine.selected_chassis_id, engine.overdrive_level)
		"cycle_audio":
			audio_ctrl.cycle_volume_level()
			dashboard_ctrl.sync_audio_mute_state(audio_ctrl.is_engine_muted())
			_sync_pause_menu_state()
			_save_pilot_profile()
		"cycle_engine_audio":
			if audio_ctrl.is_engine_muted():
				audio_ctrl.set_engine_muted(false)
			audio_ctrl.cycle_engine_volume()
			dashboard_ctrl.sync_audio_mute_state(audio_ctrl.is_engine_muted())
			_sync_pause_menu_state()
			_save_pilot_profile()
		"cycle_sfx_audio":
			if audio_ctrl.is_engine_muted():
				audio_ctrl.set_engine_muted(false)
			audio_ctrl.cycle_sfx_volume()
			dashboard_ctrl.sync_audio_mute_state(audio_ctrl.is_engine_muted())
			_sync_pause_menu_state()
			_save_pilot_profile()
		"toggle_fullscreen":
			_toggle_fullscreen_mode()
		"cycle_quality":
			cycle_quality_preset()
			_save_pilot_profile()
		"hangar":
			_sync_pause_simulation_freeze()
			if not engine.tutorial_active:
				engine.save_active_run()
			tutorial_ctrl.stop()
			_cancel_card_interaction()
			overhead_ctrl.set_tutorial_objective("")
			engine.enter_title_screen()
		"quit_game":
			_on_quit_requested()

func _on_quit_requested() -> void:
	if OS.has_feature("web"):
		_exit_web_fullscreen()
		_sync_pause_menu_state()
		return
	if engine != null and engine.mode != CombatEngine.MODE_TITLE and not engine.tutorial_active:
		engine.save_active_run()
	_save_pilot_profile()
	if get_tree() != null:
		get_tree().quit()

func _on_title_action(action_id: String) -> void:
	if action_id.begins_with("run:"):
		var parts: PackedStringArray = action_id.trim_prefix("run:").split(":")
		var cid: String = str(parts[0]) if parts.size() > 0 else "interceptor"
		var od_lvl: int = int(parts[1]) if parts.size() > 1 else terminal_ctrl.selected_overdrive_level
		var explicit_tour: bool = parts.size() > 2 and str(parts[2]) == "tour"
		var first_boot_quick: bool = (not onboarding_seen) and (not explicit_tour)
		terminal_ctrl.selected_overdrive_level = clampi(od_lvl, 0, 5)
		_mark_onboarding_seen()
		tutorial_ctrl.stop()
		apply_chassis_visuals(cid)
		overhead_ctrl.set_tutorial_objective("")
		_cancel_card_interaction()
		_record_chassis_run_start(cid)
		engine.start_new_run(cid, od_lvl)
		if explicit_tour:
			tutorial_ctrl.start(false)
		elif first_boot_quick:
			tutorial_ctrl.start(true)
		return
	match action_id:
		"continue":
			_mark_onboarding_seen()
			tutorial_ctrl.stop()
			overhead_ctrl.set_tutorial_objective("")
			_cancel_card_interaction()
			if engine.load_saved_run():
				apply_chassis_visuals(engine.selected_chassis_id)
			else:
				engine.enter_title_screen()
		"run":
			var first_time: bool = not onboarding_seen
			_mark_onboarding_seen()
			tutorial_ctrl.stop()
			apply_chassis_visuals("interceptor")
			overhead_ctrl.set_tutorial_objective("")
			_cancel_card_interaction()
			_record_chassis_run_start("interceptor")
			engine.start_new_run("interceptor", terminal_ctrl.selected_overdrive_level)
			if first_time:
				tutorial_ctrl.start(true)
		"tutorial":
			_mark_onboarding_seen()
			tutorial_ctrl.stop()
			var chosen_cid: String = engine.selected_chassis_id if not engine.selected_chassis_id.is_empty() else "interceptor"
			apply_chassis_visuals(chosen_cid)
			_cancel_card_interaction()
			_record_chassis_run_start(chosen_cid)
			engine.start_new_run(chosen_cid, terminal_ctrl.selected_overdrive_level)
			tutorial_ctrl.start(false)
		_:
			push_error("Unknown title action requested: %s" % action_id)

func _on_workshop_action(action_id: String) -> void:
	match action_id:
		"repair":
			engine.workshop_repair_hull()
		"reinforce":
			engine.workshop_reinforce_chassis()
		"buy_card":
			engine.workshop_buy_card()
		"buy_relic":
			engine.workshop_buy_relic()
		"leave":
			engine.leave_workshop()
		_:
			push_error("Unknown workshop action requested: %s" % action_id)

func _sync_title_mode_presentation() -> void:
	if engine == null:
		return
	var in_title: bool = (engine.mode == CombatEngine.MODE_TITLE)
	if title_presentation_initialized and in_title == last_title_mode:
		return
	title_presentation_initialized = true
	last_title_mode = in_title

	if title_backdrop != null:
		title_backdrop.set_active(in_title)
		if in_title:
			var preview_cid: String = engine.selected_chassis_id if not engine.selected_chassis_id.is_empty() else "interceptor"
			title_backdrop.set_preview_chassis(preview_cid)
	if main_menu != null:
		main_menu.set_menu_visible(in_title)
	if cockpit_rig != null:
		cockpit_rig.visible = not in_title
	if arena_ctrl != null:
		arena_ctrl.visible = not in_title
	if fork_ctrl != null:
		fork_ctrl.visible = (not in_title) and fork_ctrl.is_fork_visible()
	if site_ctrl != null:
		site_ctrl.visible = not in_title
	if world_props_ctrl != null:
		world_props_ctrl.visible = (not in_title) and bool(_find_quality_preset(quality_preset_id).get("props_enabled", true))
	if camera_ctrl != null:
		camera_ctrl.set_process(not in_title)
		if not in_title and camera_ctrl.camera != null:
			camera_ctrl.camera.current = true
	if hud != null:
		hud.visible = not in_title

func _sync_realtime_feedback() -> void:
	if engine == null or audio_ctrl == null or camera_ctrl == null:
		return
	_sync_title_mode_presentation()
	var redline: bool = engine.transmission.is_redline(engine.current_gear, engine.rpm_units)
	var can_pause: bool = engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY
	var active_drive: bool = (not last_sim_paused) and can_pause
	var heat_ratio: float = clampf(float(engine.heat) / float(maxi(1, engine.max_heat())), 0.0, 1.0)
	var enc: Dictionary = engine.current_encounter()
	var threat_tier: int = 2 if bool(enc.get("is_boss", false)) else (1 if bool(enc.get("is_elite", false)) else 0)
	var moving_in_tunnel: bool = engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ENEMY_TURN or engine.mode == CombatEngine.MODE_SHIFT_CHOICE or engine.mode == CombatEngine.MODE_ROUTE_TRANSITION
	var tunnel_spd: float = float(repo.get_gear(engine.current_gear).get("tunnel_speed", 0.0)) if (active_drive and moving_in_tunnel) else 0.0
	audio_ctrl.set_chassis_profile(engine.selected_chassis_id)
	audio_ctrl.set_environment_context(engine.mode, tunnel_spd, threat_tier)
	audio_ctrl.set_engine_state(0 if last_sim_paused else engine.rpm_units, redline, engine.current_gear, active_drive, heat_ratio)
	camera_ctrl.set_rpm_units(engine.rpm_units)
	if hud != null:
		hud.sync_web_bar_state(_is_fullscreen_active(), can_pause, engine.mode == CombatEngine.MODE_COMBAT)
	if overhead_ctrl != null:
		var g_short: String = engine.transmission.gear_short_name(engine.current_gear)
		var stall_risk: bool = engine.has_stall_risk()
		var stall_msg: String = (repo.get_ui_text("hud", "stall_banner") % g_short) if stall_risk else ""
		overhead_ctrl.set_stall_warning(stall_risk, stall_msg)
		if engine.mode == CombatEngine.MODE_ROUTE_CHOICE:
			overhead_ctrl.set_navigation_prompt(repo.get_ui_text("hud", "fork_banner"))
		elif engine.mode == CombatEngine.MODE_ROUTE_TRANSITION:
			var chosen_title: String = str(engine.pending_route_option.get("title", "")).to_upper()
			overhead_ctrl.set_navigation_prompt(repo.get_ui_text("hud", "fork_driving_banner") % chosen_title)
		elif engine.is_site_mode() and engine.site_selecting_deck_action.is_empty():
			overhead_ctrl.set_navigation_prompt(repo.get_ui_text("hud", "site_banner"))
		else:
			overhead_ctrl.set_navigation_prompt("")
	if dash_glow_light != null and repo != null:
		if engine.heat >= engine.max_heat() - 1 or redline:
			dash_glow_light.light_color = repo.get_palette_color("redline_glow")
			dash_glow_light.light_energy = 1.05
		elif engine.current_gear == 0:
			dash_glow_light.light_color = repo.get_palette_color("kw_heat_down")
			dash_glow_light.light_energy = 0.72
		elif engine.transmission.is_optimal(engine.current_gear, engine.rpm_units):
			dash_glow_light.light_color = repo.get_palette_color("playable_glow").lerp(repo.get_palette_color("selected_glow"), 0.45)
			dash_glow_light.light_energy = 0.85
		else:
			dash_glow_light.light_color = repo.get_palette_color("mfd_accent")
			dash_glow_light.light_energy = 0.68
	if engine.mode != CombatEngine.MODE_COMBAT:
		_cancel_card_interaction()

func _unhandled_input(event: InputEvent) -> void:
	if repo == null or engine == null:
		return

	if engine.mode == CombatEngine.MODE_TITLE:
		if event is InputEventKey:
			var t_kev: InputEventKey = event as InputEventKey
			if t_kev.pressed and not t_kev.echo:
				if t_kev.keycode == KEY_F11 or t_kev.keycode == KEY_F or t_kev.keycode == KEY_M:
					_handle_key_shortcut(t_kev)
				elif main_menu != null and main_menu.handle_key_input(t_kev) and get_viewport() != null:
					get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mb_check: InputEventMouseButton = event as InputEventMouseButton
		if mb_check.button_index == MOUSE_BUTTON_RIGHT and mb_check.pressed:
			if is_dragging_card or pressed_card_index >= 0 or shifter_ctrl.is_dragging_lever:
				shifter_ctrl.cancel_knob_drag()
				_cancel_card_interaction()
				camera_ctrl.set_interaction_locked(false)
				return

	camera_ctrl.handle_input(event)

	if event is InputEventKey:
		var kev: InputEventKey = event as InputEventKey
		if kev.keycode == KEY_SHIFT:
			if kev.pressed and not kev.echo:
				shift_tap_dir = 1 if kev.location == KEY_LOCATION_RIGHT else -1
			elif not kev.pressed:
				var tap_step: int = shift_tap_dir
				shift_tap_dir = 0
				if tap_step != 0 and engine.mode == CombatEngine.MODE_COMBAT and not terminal_ctrl.is_active():
					shifter_ctrl.request_safe_step(tap_step)
			return
		if kev.pressed:
			shift_tap_dir = 0
			if not kev.echo:
				_handle_key_shortcut(kev)
			if get_viewport() != null and (kev.keycode == KEY_TAB or kev.keycode == KEY_SPACE or kev.keycode == KEY_F3 or kev.keycode == KEY_PAGEUP or kev.keycode == KEY_PAGEDOWN):
				get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		if shifter_ctrl.is_dragging_lever:
			if camera_ctrl.camera != null:
				shifter_ctrl.update_knob_drag_ray(
					camera_ctrl.camera.project_ray_origin(mm.position),
					camera_ctrl.camera.project_ray_normal(mm.position)
				)
		elif pressed_card_index >= 0:
			_update_card_drag_motion(mm.position)
		else:
			_update_hover_raycast()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_handle_left_press(mb.position)
			else:
				_handle_left_release(mb.position)
		elif mb.pressed and terminal_ctrl.is_active():
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				terminal_ctrl.step_page(-1)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				terminal_ctrl.step_page(1)
		elif mb.pressed and navigator_ctrl != null and navigator_ctrl.is_zoomed and not terminal_ctrl.is_active():
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				navigator_ctrl.scroll_map(1.35)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				navigator_ctrl.scroll_map(-1.35)

func _handle_key_shortcut(kev: InputEventKey) -> void:
	if kev.keycode == KEY_F11 or kev.keycode == KEY_F:
		_toggle_fullscreen_mode()
		return

	if kev.keycode == KEY_M:
		var next_mute: bool = not audio_ctrl.is_engine_muted()
		audio_ctrl.set_engine_muted(next_mute)
		dashboard_ctrl.sync_audio_mute_state(next_mute)
		_sync_pause_menu_state()
		_save_pilot_profile()
		return

	if kev.keycode == KEY_P and engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY:
		_cancel_card_interaction()
		_sync_pause_menu_state()
		terminal_ctrl.toggle_pause_menu()
		_sync_pause_simulation_freeze()
		return

	if kev.keycode == KEY_ESCAPE:
		if terminal_ctrl.is_active() and terminal_ctrl.screen_mode == "pause_menu":
			terminal_ctrl.close_pause_menu()
			_sync_pause_simulation_freeze()
			return
		if terminal_ctrl.is_active() and terminal_ctrl.screen_mode == "deck_preview":
			terminal_ctrl.close_deck_preview()
			return
		if terminal_ctrl.is_active() and terminal_ctrl.workshop_removing_card:
			terminal_ctrl.workshop_removing_card = false
			terminal_ctrl._rebuild_hotspots()
			return
		if terminal_ctrl.is_active() and terminal_ctrl.reward_upgrade_selecting:
			terminal_ctrl.reward_upgrade_selecting = false
			terminal_ctrl._rebuild_hotspots()
			return
		if terminal_ctrl.is_active() and terminal_ctrl.title_selecting_chassis:
			terminal_ctrl.title_selecting_chassis = false
			terminal_ctrl._rebuild_hotspots()
			return
		if engine.is_site_mode() and not engine.site_selecting_deck_action.is_empty():
			engine.cancel_site_deck_selection()
			return
		if is_dragging_card or pressed_card_index >= 0 or shifter_ctrl.is_dragging_lever:
			shifter_ctrl.cancel_knob_drag()
			_cancel_card_interaction()
			camera_ctrl.set_interaction_locked(false)
			return
		if navigator_ctrl != null and navigator_ctrl.is_zoomed:
			navigator_ctrl.set_zoomed(false)
			return
		if tutorial_ctrl != null and tutorial_ctrl.is_active():
			tutorial_ctrl.stop()
			return
		if engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY:
			_sync_pause_menu_state()
			terminal_ctrl.toggle_pause_menu()
			_sync_pause_simulation_freeze()
		return

	if kev.keycode == KEY_TAB and not terminal_ctrl.is_active():
		if navigator_ctrl != null:
			navigator_ctrl.toggle_zoom()
		return

	if navigator_ctrl != null and navigator_ctrl.is_zoomed and not terminal_ctrl.is_active():
		if kev.keycode == KEY_PAGEUP or kev.keycode == KEY_BRACKETLEFT:
			navigator_ctrl.scroll_map(1.6)
			return
		if kev.keycode == KEY_PAGEDOWN or kev.keycode == KEY_BRACKETRIGHT:
			navigator_ctrl.scroll_map(-1.6)
			return

	if kev.keycode == KEY_H and engine.mode == CombatEngine.MODE_COMBAT and not terminal_ctrl.is_active():
		_toggle_cockpit_guide()
		return

	if tutorial_ctrl != null and tutorial_ctrl.is_active() and not terminal_ctrl.is_active():
		if kev.keycode == KEY_T:
			tutorial_ctrl.stop()
			return
		if kev.keycode == KEY_SPACE or kev.keycode == KEY_ENTER or kev.keycode == KEY_KP_ENTER or kev.keycode == KEY_RIGHT:
			tutorial_ctrl.next_step()
			return
		if kev.keycode == KEY_LEFT:
			tutorial_ctrl.prev_step()
			return

	if kev.keycode == KEY_F3 or kev.keycode == KEY_I:
		terminal_ctrl.toggle_deck_preview()
		return

	if terminal_ctrl.is_active():
		if kev.keycode >= KEY_1 and kev.keycode <= KEY_9:
			terminal_ctrl.activate_row(int(kev.keycode - KEY_1))
			_sync_pause_simulation_freeze()
		elif kev.keycode == KEY_LEFT or kev.keycode == KEY_BRACKETLEFT or kev.keycode == KEY_COMMA or kev.keycode == KEY_PAGEUP:
			terminal_ctrl.step_page(-1)
		elif kev.keycode == KEY_RIGHT or kev.keycode == KEY_BRACKETRIGHT or kev.keycode == KEY_PERIOD or kev.keycode == KEY_PAGEDOWN:
			terminal_ctrl.step_page(1)
		elif kev.keycode == KEY_SPACE and engine.mode == CombatEngine.MODE_WORKSHOP and not terminal_ctrl.workshop_removing_card:
			terminal_ctrl.is_deployed = false
			engine.leave_workshop()
		return

	if engine.mode == CombatEngine.MODE_ROUTE_CHOICE:
		if kev.keycode == KEY_1 or kev.keycode == KEY_KP_1:
			fork_ctrl.trigger_lane_choice(0)
		elif kev.keycode == KEY_2 or kev.keycode == KEY_KP_2:
			fork_ctrl.trigger_lane_choice(1)
		return

	if engine.is_site_mode() and engine.site_selecting_deck_action.is_empty():
		if kev.keycode == KEY_1 or kev.keycode == KEY_KP_1:
			site_ctrl.trigger_choice(0)
		elif kev.keycode == KEY_2 or kev.keycode == KEY_KP_2:
			site_ctrl.trigger_choice(1)
		elif kev.keycode == KEY_3 or kev.keycode == KEY_KP_3:
			site_ctrl.trigger_choice(2)
		return

	if engine.mode != CombatEngine.MODE_COMBAT:
		return

	if kev.keycode == KEY_E or kev.keycode == KEY_PAGEUP or (kev.shift_pressed and (kev.keycode == KEY_W or kev.keycode == KEY_UP)):
		shifter_ctrl.request_safe_step(1)
	elif kev.keycode == KEY_Q or kev.keycode == KEY_PAGEDOWN or (kev.shift_pressed and (kev.keycode == KEY_S or kev.keycode == KEY_DOWN)):
		shifter_ctrl.request_safe_step(-1)
	elif kev.keycode == KEY_SPACE:
		_cancel_card_interaction()
		dashboard_ctrl.trigger_slam_button()
	elif kev.keycode == KEY_X:
		_burn_selected_or_hovered_card()
	elif kev.keycode == KEY_Z:
		_use_consumable_slot(0)
	elif kev.keycode == KEY_C:
		_use_consumable_slot(1)
	elif kev.keycode == KEY_V:
		_use_consumable_slot(2)

func _card_needs_manual_enemy_target(hand_index: int) -> bool:
	if hand_index < 0 or hand_index >= engine.hand.size():
		return false
	var card: Dictionary = repo.get_card(engine.hand[hand_index])
	return str(card.get("target_type", "self")) == "single_enemy" and engine.alive_enemy_count() > 1

func _update_card_drag_motion(mouse_pos: Vector2) -> void:
	if pressed_card_index < 0 or pressed_card_index >= engine.hand.size():
		_cancel_card_interaction()
		return
	var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
	var deadzone: float = float(hcfg.get("drag_deadzone_px", 16.0))
	var delta_px: Vector2 = mouse_pos - card_press_mouse_pos
	if not is_dragging_card and delta_px.length() >= deadzone:
		is_dragging_card = true
		hand_ctrl.set_selected_index(-1)

	if not is_dragging_card:
		return

	hand_ctrl.set_drag_state(pressed_card_index, delta_px)
	dashboard_ctrl.set_inspected_card(pressed_card_index)

	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var vp_h: float = maxf(200.0, vp.get_visible_rect().size.y)
	var act_y: float = vp_h * float(hcfg.get("play_activation_screen_y_ratio", 0.60))
	var origin_px: Vector2 = hand_ctrl.get_card_screen_pos(pressed_card_index, camera_ctrl.camera)

	var check: Dictionary = engine.can_play_card(pressed_card_index)
	var playable: bool = bool(check.get("playable", false))
	var needs_enemy: bool = _card_needs_manual_enemy_target(pressed_card_index)

	if not playable:
		arena_ctrl.set_hovered_enemy(-1, false)
		hud.show_drag_feedback(origin_px, mouse_pos, act_y, false, true, false)
		return

	if needs_enemy:
		var hovered_enemy: int = _raycast_alive_enemy()
		arena_ctrl.set_hovered_enemy(hovered_enemy, true, pressed_card_index)
		var locked: bool = (hovered_enemy >= 0)
		hud.show_drag_feedback(origin_px, mouse_pos, act_y, locked, false, true)
	else:
		arena_ctrl.set_hovered_enemy(-1, false, pressed_card_index)
		var above_line: bool = (mouse_pos.y <= act_y)
		hud.show_drag_feedback(origin_px, mouse_pos, act_y, above_line, false, false)

func _raycast_alive_enemy() -> int:
	var hit: Dictionary = camera_ctrl.raycast_mouse(DungeonArena3D.COLLISION_LAYER_ENEMIES)
	if hit.is_empty():
		return -1
	var collider: Object = hit.get("collider")
	if collider is Node:
		var node: Node = collider as Node
		if str(node.get_meta("interact_type", "")) == "enemy_target":
			var e_idx: int = int(node.get_meta("enemy_index", -1))
			if e_idx >= 0 and e_idx < engine.enemies.size() and bool(engine.enemies[e_idx].get("alive", false)):
				return e_idx
	return -1

func _handle_left_press(mouse_pos: Vector2) -> void:
	var mask: int = DiegeticTerminal3D.COLLISION_LAYER_TERMINAL if terminal_ctrl.is_active() else 0xFFFFFFFF
	var hit: Dictionary = camera_ctrl.raycast_mouse(mask)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if not (collider is Node):
		return
	var node: Node = collider as Node
	var itype: String = str(node.get_meta("interact_type", ""))

	if itype == "terminal_screen":
		terminal_ctrl.click_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
		return
	if itype == "terminal_option":
		terminal_ctrl.activate_row(int(node.get_meta("option_index", -1)))
		return

	if itype == "mfd_screen":
		dashboard_ctrl.click_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
		return
	if itype == "mfd_deck_toggle":
		terminal_ctrl.toggle_deck_preview()
		return
	if itype == "overhead_pod_screen":
		overhead_ctrl.click_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
		return
	if itype == "navigator_screen":
		navigator_ctrl.click_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
		return
	if itype == "road_fork_lane":
		fork_ctrl.trigger_lane_choice(int(node.get_meta("lane_index", -1)))
		return
	if itype == "encounter_site_choice":
		site_ctrl.trigger_choice(int(node.get_meta("choice_index", -1)))
		return

	if engine.mode != CombatEngine.MODE_COMBAT:
		return

	match itype:
		"hand_card":
			var h_idx: int = int(node.get_meta("hand_index", -1))
			if h_idx >= 0 and h_idx < engine.hand.size():
				pressed_card_index = h_idx
				card_press_mouse_pos = mouse_pos
				is_dragging_card = false
				camera_ctrl.set_interaction_locked(true)
		"shift_knob":
			_cancel_card_interaction()
			camera_ctrl.set_interaction_locked(true)
			shifter_ctrl.begin_knob_drag()
		"gear_slot":
			_cancel_card_interaction()
			shifter_ctrl.request_safe_shift(int(node.get_meta("gear_index", 0)))
		"end_turn_button":
			_cancel_card_interaction()
			dashboard_ctrl.trigger_slam_button()
		"dashboard_switch":
			dashboard_ctrl.trigger_switch(str(node.get_meta("switch_id", "")))

func _handle_left_release(mouse_pos: Vector2) -> void:
	camera_ctrl.set_interaction_locked(false)

	if shifter_ctrl.is_dragging_lever:
		shifter_ctrl.end_knob_drag()
		return

	if pressed_card_index < 0:
		return

	var released_idx: int = pressed_card_index
	var was_dragging: bool = is_dragging_card
	pressed_card_index = -1
	is_dragging_card = false
	hand_ctrl.set_drag_state(-1, Vector2.ZERO)
	hud.clear_drag_feedback()
	arena_ctrl.set_hovered_enemy(-1, false)

	if released_idx >= engine.hand.size() or engine.mode != CombatEngine.MODE_COMBAT:
		return

	if was_dragging:
		var check: Dictionary = engine.can_play_card(released_idx)
		if not bool(check.get("playable", false)):
			var hcfg_b: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
			var vp_b: Viewport = get_viewport()
			if vp_b != null and mouse_pos.y <= vp_b.get_visible_rect().size.y * float(hcfg_b.get("play_activation_screen_y_ratio", 0.60)):
				engine.play_card(released_idx, -1)
			overhead_ctrl.set_scanner_text("")
			return

		if _card_needs_manual_enemy_target(released_idx):
			var target_enemy: int = _raycast_alive_enemy()
			if target_enemy >= 0:
				engine.play_card(released_idx, target_enemy)
			overhead_ctrl.set_scanner_text("")
			return

		var hcfg: Dictionary = repo.cockpit.get("hand_3d", {}) as Dictionary
		var vp: Viewport = get_viewport()
		if vp != null:
			var act_y: float = vp.get_visible_rect().size.y * float(hcfg.get("play_activation_screen_y_ratio", 0.60))
			if mouse_pos.y <= act_y:
				engine.play_card(released_idx, engine.first_alive_enemy_index())
		overhead_ctrl.set_scanner_text("")
		return

func _use_consumable_slot(slot_idx: int) -> void:
	if engine == null or engine.mode != CombatEngine.MODE_COMBAT:
		return
	_cancel_card_interaction()
	engine.use_consumable(slot_idx)

func _burn_selected_or_hovered_card() -> void:
	if engine == null or engine.mode != CombatEngine.MODE_COMBAT:
		return
	var target_idx: int = hand_ctrl.hovered_hand_index
	if target_idx < 0 or target_idx >= engine.hand.size():
		return
	_cancel_card_interaction()
	engine.burn_card_for_rpm(target_idx)

func _cancel_card_interaction() -> void:
	pressed_card_index = -1
	is_dragging_card = false
	if hand_ctrl != null:
		hand_ctrl.clear_selection()
	if hud != null:
		hud.clear_drag_feedback()
	if arena_ctrl != null:
		arena_ctrl.set_hovered_enemy(-1, false)
	if dashboard_ctrl != null:
		dashboard_ctrl.clear_inspector_if_transient(-1)
	if overhead_ctrl != null:
		overhead_ctrl.set_scanner_text("")

func _update_hover_raycast() -> void:
	var mask: int = DiegeticTerminal3D.COLLISION_LAYER_TERMINAL if terminal_ctrl.is_active() else 0xFFFFFFFF
	var hit: Dictionary = camera_ctrl.raycast_mouse(mask)

	var collider: Object = hit.get("collider") if not hit.is_empty() else null
	var node: Node = (collider as Node) if (collider is Node) else null
	var itype: String = str(node.get_meta("interact_type", "")) if node != null else ""

	hud.set_reticle_highlighted(node != null)

	var next_hand_idx: int = int(node.get_meta("hand_index", -1)) if itype == "hand_card" else -1
	var next_gear_slot: int = int(node.get_meta("gear_index", 0)) if itype == "gear_slot" else -99
	var next_enemy_idx: int = int(node.get_meta("enemy_index", -1)) if itype == "enemy_target" else -1
	var next_preview_card: int = next_hand_idx if itype == "hand_card" else -1

	hand_ctrl.set_hovered_index(next_hand_idx)
	shifter_ctrl.set_hovered_slot(next_gear_slot)
	arena_ctrl.set_hovered_enemy(next_enemy_idx, false, next_preview_card)
	if itype != "terminal_screen":
		terminal_ctrl.set_hovered_row(int(node.get_meta("option_index", -1)) if itype == "terminal_option" else -1)
	if itype != "mfd_screen" and itype != "mfd_deck_toggle":
		dashboard_ctrl.set_hovered_tab("")
	if itype != "overhead_pod_screen":
		if overhead_ctrl != null:
			overhead_ctrl.clear_hover()
		if hud != null:
			hud.hide_item_tooltip()
	if itype != "navigator_screen" and navigator_ctrl != null:
		navigator_ctrl.clear_hover()
	if itype != "road_fork_lane" and itype != "navigator_screen" and fork_ctrl != null:
		fork_ctrl.set_hovered_lane(-1)
	if itype != "encounter_site_choice" and site_ctrl != null:
		site_ctrl.set_hovered_choice(-1)

	if node == null:
		dashboard_ctrl.clear_inspector_if_transient(-1)
		overhead_ctrl.set_scanner_text("")
		return

	match itype:
		"overhead_pod_screen":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			var pod_info: Dictionary = overhead_ctrl.update_hover_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
			if not pod_info.is_empty() and get_viewport() != null:
				hud.show_item_tooltip(
					get_viewport().get_mouse_position(),
					str(pod_info.get("title", "")),
					str(pod_info.get("desc", "")),
					pod_info.get("color", Color.WHITE) as Color
				)
			else:
				hud.hide_item_tooltip()
		"navigator_screen":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(navigator_ctrl.update_hover_world_pos(hit.get("position", Vector3.ZERO) as Vector3))
		"road_fork_lane":
			var lane_idx: int = int(node.get_meta("lane_index", -1))
			fork_ctrl.set_hovered_lane(lane_idx)
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(fork_ctrl.describe_lane_hover(lane_idx))
		"encounter_site_choice":
			var c_idx: int = int(node.get_meta("choice_index", -1))
			site_ctrl.set_hovered_choice(c_idx)
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(site_ctrl.describe_choice_hover(c_idx))
		"terminal_screen":
			var hint_txt: String = terminal_ctrl.update_hover_world_pos(hit.get("position", Vector3.ZERO) as Vector3)
			overhead_ctrl.set_scanner_text(hint_txt)
		"terminal_option":
			overhead_ctrl.set_scanner_text(repo.get_ui_text("hud", "hover_terminal_opt_fmt") % str(node.get_meta("option_hint", "")))
		"hand_card":
			dashboard_ctrl.set_inspected_card(next_hand_idx)
			overhead_ctrl.set_scanner_text(hand_ctrl.describe_card_hover(next_hand_idx))
		"shift_knob":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(repo.get_ui_text("hud", "hover_shifter_knob"))
		"gear_slot":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(shifter_ctrl.describe_slot_hover(next_gear_slot))
		"mfd_screen":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(dashboard_ctrl.update_hover_world_pos(hit.get("position", Vector3.ZERO) as Vector3))
		"mfd_deck_toggle":
			dashboard_ctrl.set_hovered_tab(Dashboard3DController.TAB_DECK)
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(repo.get_ui_text("hud", "hover_mfd_deck"))
		"end_turn_button":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			var warn: String = repo.get_ui_text("hud", "hover_end_turn_stall_suffix") if engine.transmission.is_stall_risk(engine.current_gear, engine.rpm_units) else ""
			overhead_ctrl.set_scanner_text(repo.get_ui_text("hud", "hover_end_turn") % warn)
		"dashboard_switch":
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text(repo.get_ui_text("hud", "hover_audio_switch_fmt") % str(node.get_meta("switch_hint", "")))
		"enemy_target":
			dashboard_ctrl.set_inspected_enemy(next_enemy_idx)
			overhead_ctrl.set_scanner_text(arena_ctrl.describe_enemy_hover(next_enemy_idx))
		_:
			dashboard_ctrl.clear_inspector_if_transient(-1)
			overhead_ctrl.set_scanner_text("")
