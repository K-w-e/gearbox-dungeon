class_name CockpitCameraController
extends Node3D

var repo: GameRepository
var camera: Camera3D

var base_eye_pos: Vector3 = Vector3.ZERO
var base_pitch_deg: float = -13.5
var base_yaw_deg: float = -3.0

var manual_yaw_offset_deg: float = 0.0
var manual_pitch_offset_deg: float = 0.0
var external_turn_yaw_deg: float = 0.0
var smoothed_yaw_deg: float = -3.0
var smoothed_pitch_deg: float = -13.5

var is_rmb_panning: bool = false
var interaction_locked: bool = false
var last_cursor_yaw: float = 0.0
var last_cursor_pitch: float = 0.0
var trauma: float = 0.0
var current_rpm_units: int = 0
var time_accum: float = 0.0
var is_camera_moving: bool = false
var vibration_paused: bool = false

func initialize(repository: GameRepository) -> void:
	repo = repository
	var cam_cfg: Dictionary = repo.cockpit.get("camera", {}) as Dictionary
	base_eye_pos = JsonConfigLoader.to_vec3(cam_cfg.get("eye_position", []), Vector3(-0.08, 1.15, 0.16))
	base_pitch_deg = float(cam_cfg.get("base_pitch_deg", -13.5))
	base_yaw_deg = float(cam_cfg.get("base_yaw_deg", -3.0))
	smoothed_pitch_deg = base_pitch_deg
	smoothed_yaw_deg = base_yaw_deg

	position = base_eye_pos
	camera = Camera3D.new()
	camera.fov = clampf(float(cam_cfg.get("fov_deg", 73.0)), 45.0, 105.0)
	camera.near = maxf(0.01, float(cam_cfg.get("near_clip", 0.04)))
	camera.far = maxf(20.0, float(cam_cfg.get("far_clip", 90.0)))
	camera.current = true
	add_child(camera)

func add_trauma(amount: float) -> void:
	trauma = clampf(trauma + maxf(0.0, amount), 0.0, 1.0)

func set_rpm_units(units: int) -> void:
	current_rpm_units = clampi(units, 0, 8)

func reset_glance() -> void:
	manual_yaw_offset_deg = 0.0
	manual_pitch_offset_deg = 0.0

func set_glance_angles(yaw_deg: float, pitch_deg: float) -> void:
	manual_yaw_offset_deg = yaw_deg
	manual_pitch_offset_deg = pitch_deg
	if repo != null:
		_clamp_manual_offsets(repo.cockpit.get("camera", {}) as Dictionary)

func set_interaction_locked(locked: bool) -> void:
	interaction_locked = locked

func set_external_turn_yaw_deg(yaw_deg: float) -> void:
	external_turn_yaw_deg = yaw_deg

func handle_input(event: InputEvent) -> void:
	if repo == null:
		return
	var cam_cfg: Dictionary = repo.cockpit.get("camera", {}) as Dictionary
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			is_rmb_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE and mb.pressed:
			reset_glance()
	elif event is InputEventMouseMotion and is_rmb_panning:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		var sens: float = float(cam_cfg.get("manual_pan_sensitivity", 0.14))
		manual_yaw_offset_deg -= mm.relative.x * sens
		manual_pitch_offset_deg -= mm.relative.y * sens
		_clamp_manual_offsets(cam_cfg)

func _clamp_manual_offsets(cam_cfg: Dictionary) -> void:
	var max_left: float = float(cam_cfg.get("max_yaw_left_deg", 28.0))
	var max_right: float = float(cam_cfg.get("max_yaw_right_deg", 34.0))
	var max_up: float = float(cam_cfg.get("max_pitch_up_deg", 16.0))
	var max_down: float = float(cam_cfg.get("max_pitch_down_deg", 23.0))
	manual_yaw_offset_deg = clampf(manual_yaw_offset_deg, -max_right, max_left)
	manual_pitch_offset_deg = clampf(manual_pitch_offset_deg, -max_down, max_up)

func _process(delta: float) -> void:
	if repo == null or camera == null:
		return
	time_accum += delta
	var cam_cfg: Dictionary = repo.cockpit.get("camera", {}) as Dictionary
	var key_speed: float = float(cam_cfg.get("keyboard_pan_speed_deg", 48.0))

	if not Input.is_key_pressed(KEY_SHIFT):
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			manual_yaw_offset_deg += key_speed * delta
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			manual_yaw_offset_deg -= key_speed * delta
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			manual_pitch_offset_deg += key_speed * delta
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			manual_pitch_offset_deg -= key_speed * delta
		_clamp_manual_offsets(cam_cfg)

	var vp: Viewport = get_viewport()
	var cursor_yaw: float = last_cursor_yaw
	var cursor_pitch: float = last_cursor_pitch
	if vp != null and not interaction_locked:
		var vp_size: Vector2 = vp.get_visible_rect().size
		if vp_size.x > 1.0 and vp_size.y > 1.0:
			var mpos: Vector2 = vp.get_mouse_position()
			var nx: float = clampf((mpos.x / vp_size.x) * 2.0 - 1.0, -1.0, 1.0)
			var ny: float = clampf((mpos.y / vp_size.y) * 2.0 - 1.0, -1.0, 1.0)
			cursor_yaw = -nx * float(cam_cfg.get("cursor_parallax_yaw_deg", 4.2))
			cursor_pitch = -ny * float(cam_cfg.get("cursor_parallax_pitch_deg", 2.6))
			last_cursor_yaw = cursor_yaw
			last_cursor_pitch = cursor_pitch

	var max_left: float = float(cam_cfg.get("max_yaw_left_deg", 28.0))
	var max_right: float = float(cam_cfg.get("max_yaw_right_deg", 34.0))
	var max_up: float = float(cam_cfg.get("max_pitch_up_deg", 16.0))
	var max_down: float = float(cam_cfg.get("max_pitch_down_deg", 23.0))

	var combined_yaw_offset: float = clampf(manual_yaw_offset_deg + cursor_yaw, -max_right, max_left)
	var combined_pitch_offset: float = clampf(manual_pitch_offset_deg + cursor_pitch, -max_down, max_up)

	var target_yaw: float = base_yaw_deg + combined_yaw_offset + external_turn_yaw_deg
	var target_pitch: float = base_pitch_deg + combined_pitch_offset
	var prev_pitch: float = smoothed_pitch_deg
	var prev_yaw: float = smoothed_yaw_deg
	var smooth: float = clampf(delta * float(cam_cfg.get("look_smoothing", 9.5)), 0.0, 1.0)
	smoothed_yaw_deg = lerpf(smoothed_yaw_deg, target_yaw, smooth)
	smoothed_pitch_deg = lerpf(smoothed_pitch_deg, target_pitch, smooth)

	trauma = maxf(0.0, trauma - delta * float(cam_cfg.get("trauma_decay", 2.4)))
	var shake_power: float = trauma * trauma
	var max_off: float = float(cam_cfg.get("max_shake_offset", 0.032))
	var shake_vec: Vector3 = Vector3(
		sin(time_accum * 43.0) * max_off * shake_power,
		cos(time_accum * 51.0) * max_off * shake_power,
		0.0
	)

	var vib_thresh: int = int(cam_cfg.get("rpm_vibration_threshold_units", 6))
	if not vibration_paused and current_rpm_units >= vib_thresh:
		var vib_amp: float = float(cam_cfg.get("rpm_vibration_amplitude", 0.0038)) * float(current_rpm_units - vib_thresh + 1)
		shake_vec.x += sin(time_accum * 68.0) * vib_amp
		shake_vec.y += cos(time_accum * 82.0) * vib_amp

	position = base_eye_pos + shake_vec
	var roll_shake: float = 0.0 if vibration_paused else (sin(time_accum * 37.0) * float(cam_cfg.get("max_shake_roll_deg", 2.8)) * shake_power)
	camera.rotation_degrees = Vector3(smoothed_pitch_deg, smoothed_yaw_deg, roll_shake)
	is_camera_moving = absf(smoothed_pitch_deg - prev_pitch) > 0.025 or absf(smoothed_yaw_deg - prev_yaw) > 0.025

func raycast_mouse(collision_mask: int = 0xFFFFFFFF) -> Dictionary:
	if camera == null or get_world_3d() == null:
		return {}
	var vp: Viewport = get_viewport()
	if vp == null:
		return {}
	var mouse_pos: Vector2 = vp.get_mouse_position()
	var cam_cfg: Dictionary = repo.cockpit.get("camera", {}) as Dictionary
	var ray_len: float = float(cam_cfg.get("ray_length", 24.0))
	var origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var target: Vector3 = origin + camera.project_ray_normal(mouse_pos) * ray_len
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, collision_mask)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(query)
