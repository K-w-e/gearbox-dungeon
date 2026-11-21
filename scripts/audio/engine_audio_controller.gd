class_name EngineAudioController
extends Node

var repo: GameRepository
var engine_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer

const VOLUME_PRESETS: Array[float] = [1.0, 0.60, 0.25, 0.0]
const THREAT_RIFF_HZ: Array[float] = [41.20, 41.20, 48.99, 36.71]

var sample_rate: float = 22050.0
var phase_primary: float = 0.0
var phase_sub: float = 0.0
var phase_pulse: float = 0.0
var phase_turbo: float = 0.0
var phase_drone: float = 0.0
var phase_drone_b: float = 0.0
var phase_drone_lfo: float = 0.0
var phase_road_joint: float = 0.0
var phase_duct_pass: float = 0.0
var phase_threat_step: float = 0.0
var phase_threat_osc: float = 0.0
var drone_lp_state: float = 0.0
var road_lp_state: float = 0.0
var road_hp_state: float = 0.0
var lowpass_state: float = 0.0

var smoothed_rpm_units: float = 2.0
var target_rpm_units: float = 2.0
var smoothed_speed_mps: float = 0.0
var target_speed_mps: float = 0.0
var current_gear_index: int = 1
var current_heat_ratio: float = 0.0
var active_tunnel_drive: bool = false
var active_chassis_id: String = "interceptor"
var active_env_mode: String = "title"
var active_threat_tier: int = 0
var rev_flare: float = 0.0
var in_redline: bool = false
var engine_muted: bool = false
var master_volume: float = 1.0
var pre_mute_volume: float = 1.0
var engine_volume: float = 1.0
var sfx_volume: float = 1.0
var sfx_queue: Array[Dictionary] = []
var noise_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var window_focused: bool = true
var engine_buf_vec: PackedVector2Array = PackedVector2Array()
var sfx_buf_vec: PackedVector2Array = PackedVector2Array()

func initialize(repository: GameRepository) -> void:
	repo = repository
	noise_rng.randomize()
	var acfg: Dictionary = repo.audio_cfg()
	var is_web: bool = OS.has_feature("web")
	sample_rate = maxf(8000.0, float(acfg.get("web_mix_rate" if is_web else "mix_rate", 16000.0 if is_web else 22050.0)))
	var eng_buf: float = float(acfg.get("web_buffer_length" if is_web else "buffer_length", 0.24 if is_web else 0.12))
	var sfx_buf: float = float(acfg.get("web_sfx_buffer_length" if is_web else "sfx_buffer_length", 0.32 if is_web else 0.25))

	engine_player = AudioStreamPlayer.new()
	engine_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var eng_stream: AudioStreamGenerator = AudioStreamGenerator.new()
	eng_stream.mix_rate = sample_rate
	eng_stream.buffer_length = clampf(eng_buf, 0.05, 0.5)
	engine_player.stream = eng_stream
	add_child(engine_player)
	engine_player.play()

	sfx_player = AudioStreamPlayer.new()
	sfx_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var sfx_stream: AudioStreamGenerator = AudioStreamGenerator.new()
	sfx_stream.mix_rate = sample_rate
	sfx_stream.buffer_length = clampf(sfx_buf, 0.08, 0.6)
	sfx_player.stream = sfx_stream
	add_child(sfx_player)
	sfx_player.play()

func _exit_tree() -> void:
	sfx_queue.clear()
	if engine_player != null and is_instance_valid(engine_player):
		engine_player.stop()
	if sfx_player != null and is_instance_valid(sfx_player):
		sfx_player.stop()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		window_focused = false
		sfx_queue.clear()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		window_focused = true
		ensure_playback_active()

func _input(event: InputEvent) -> void:
	if (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) or (event is InputEventKey and (event as InputEventKey).pressed):
		ensure_playback_active()

func ensure_playback_active() -> void:
	if engine_player != null and is_instance_valid(engine_player) and not engine_player.playing:
		engine_player.play()
	if sfx_player != null and is_instance_valid(sfx_player) and not sfx_player.playing:
		sfx_player.play()

func set_chassis_profile(chassis_id: String) -> void:
	if not chassis_id.is_empty():
		active_chassis_id = chassis_id

func set_environment_context(env_mode: String, tunnel_speed_mps: float = 0.0, threat_tier: int = 0) -> void:
	active_env_mode = env_mode
	target_speed_mps = clampf(tunnel_speed_mps, -12.0, 35.0)
	active_threat_tier = clampi(threat_tier, 0, 2)

func set_engine_state(rpm_units: int, redline_active: bool, gear_index: int = 1, active_drive: bool = true, heat_ratio: float = 0.0) -> void:
	var new_target: float = clampf(float(rpm_units), 0.0, 8.0)
	if new_target > target_rpm_units:
		rev_flare = clampf(rev_flare + (new_target - target_rpm_units) * 0.35, 0.0, 1.0)
	target_rpm_units = new_target
	in_redline = redline_active
	current_gear_index = gear_index
	active_tunnel_drive = active_drive
	current_heat_ratio = clampf(heat_ratio, 0.0, 1.0)

func set_engine_bus_volume(vol: float) -> void:
	engine_volume = clampf(vol, 0.0, 1.0)

func set_sfx_bus_volume(vol: float) -> void:
	sfx_volume = clampf(vol, 0.0, 1.0)
	if sfx_volume <= 0.001:
		sfx_queue.clear()

func cycle_engine_volume() -> float:
	var idx: int = 0
	for i: int in range(VOLUME_PRESETS.size()):
		if absf(engine_volume - VOLUME_PRESETS[i]) < 0.08:
			idx = (i + 1) % VOLUME_PRESETS.size()
			break
	set_engine_bus_volume(VOLUME_PRESETS[idx])
	return engine_volume

func cycle_sfx_volume() -> float:
	var idx: int = 0
	for i: int in range(VOLUME_PRESETS.size()):
		if absf(sfx_volume - VOLUME_PRESETS[i]) < 0.08:
			idx = (i + 1) % VOLUME_PRESETS.size()
			break
	set_sfx_bus_volume(VOLUME_PRESETS[idx])
	return sfx_volume

func format_engine_volume_label() -> String:
	if is_engine_muted() or engine_volume <= 0.001:
		return "MUTED"
	return "%d%%" % roundi(engine_volume * master_volume * 100.0)

func format_sfx_volume_label() -> String:
	if is_engine_muted() or sfx_volume <= 0.001:
		return "MUTED"
	return "%d%%" % roundi(sfx_volume * master_volume * 100.0)

func set_engine_muted(muted: bool) -> void:
	engine_muted = muted
	if muted:
		sfx_queue.clear()
	elif master_volume <= 0.01:
		master_volume = pre_mute_volume if pre_mute_volume > 0.05 else 1.0

func is_engine_muted() -> bool:
	return engine_muted or master_volume <= 0.001

func set_master_volume(vol: float) -> void:
	master_volume = clampf(vol, 0.0, 1.0)
	if master_volume > 0.01:
		pre_mute_volume = master_volume
		engine_muted = false
	else:
		engine_muted = true
		sfx_queue.clear()

func get_master_volume() -> float:
	return 0.0 if engine_muted else master_volume

func cycle_volume_level() -> float:
	var cur: float = get_master_volume()
	var idx: int = 0
	for i: int in range(VOLUME_PRESETS.size()):
		if absf(cur - VOLUME_PRESETS[i]) < 0.08:
			idx = (i + 1) % VOLUME_PRESETS.size()
			break
	set_master_volume(VOLUME_PRESETS[idx])
	return get_master_volume()

func format_volume_label() -> String:
	var eff: float = get_master_volume()
	if eff <= 0.001:
		return "MUTED"
	return "%d%%" % roundi(eff * 100.0)

func trigger_sfx(sfx_id: String, intensity: float = 1.0) -> void:
	if is_engine_muted() or sfx_volume <= 0.001:
		return
	ensure_playback_active()
	if sfx_queue.size() >= 18:
		sfx_queue.pop_front()
	var clean_intensity: float = clampf(intensity, 0.08, 1.35)
	if sfx_id == "shift_clack" or sfx_id == "grind":
		rev_flare = clampf(rev_flare + 0.45, 0.0, 1.0)
	elif sfx_id == "clutch_kick" or sfx_id == "turbo_blowoff":
		rev_flare = clampf(rev_flare + 0.65 * clean_intensity, 0.0, 1.35)
	elif sfx_id == "throttle_blip":
		var blip_flare: float = float(repo.audio_cfg().get("throttle_blip_flare", 0.95))
		rev_flare = clampf(rev_flare + blip_flare * clean_intensity, 0.0, 1.6)

	match sfx_id:
		"throttle_blip":
			var blip_dur: float = float(repo.audio_cfg().get("throttle_blip_duration", 0.22))
			sfx_queue.append({"type": "throttle_blip", "t": 0.0, "dur": blip_dur, "amp": clean_intensity})
		"rev_match":
			sfx_queue.append({"type": "rev_match", "t": 0.0, "dur": 0.26, "amp": clean_intensity})
		"clutch_kick":
			sfx_queue.append({"type": "clutch_kick", "t": 0.0, "dur": 0.22, "amp": clean_intensity})
		"turbo_blowoff":
			sfx_queue.append({"type": "turbo_blowoff", "t": 0.0, "dur": 0.34, "amp": clean_intensity})
		"coolant_vent":
			sfx_queue.append({"type": "coolant_vent", "t": 0.0, "dur": 0.32, "amp": clean_intensity})
		"gun_burst":
			sfx_queue.append({"type": "gun_burst", "t": 0.0, "dur": 0.24, "amp": clean_intensity})
		"steam_hiss":
			sfx_queue.append({"type": "steam_hiss", "t": 0.0, "dur": 0.38, "amp": clean_intensity})
		"weld_arc":
			sfx_queue.append({"type": "weld_arc", "t": 0.0, "dur": 0.19, "amp": clean_intensity})
		"forge_anvil":
			sfx_queue.append({"type": "forge_anvil", "t": 0.0, "dur": 0.36, "amp": clean_intensity})
		"air_brake":
			sfx_queue.append({"type": "air_brake", "t": 0.0, "dur": 0.34, "amp": clean_intensity})
		"tire_screech":
			sfx_queue.append({"type": "tire_screech", "t": 0.0, "dur": 0.30, "amp": clean_intensity})
		"hydraulic_servo":
			sfx_queue.append({"type": "hydraulic_servo", "t": 0.0, "dur": 0.15, "amp": clean_intensity})
		"shift_clack":
			sfx_queue.append({"type": "clack", "t": 0.0, "dur": 0.12, "amp": clean_intensity})
		"grind":
			sfx_queue.append({"type": "grind", "t": 0.0, "dur": 0.28, "amp": clean_intensity})
		"slam_button":
			sfx_queue.append({"type": "slam", "t": 0.0, "dur": 0.16, "amp": clean_intensity})
		"switch_click":
			sfx_queue.append({"type": "switch", "t": 0.0, "dur": 0.05, "amp": clean_intensity})
		"card_play":
			sfx_queue.append({"type": "card", "t": 0.0, "dur": 0.12, "amp": clean_intensity})
		"ram_hit":
			sfx_queue.append({"type": "ram_crunch", "t": 0.0, "dur": 0.26, "amp": clean_intensity})
		"attack_hit":
			sfx_queue.append({"type": "impact", "t": 0.0, "dur": 0.22, "amp": clean_intensity})
		"shield":
			sfx_queue.append({"type": "shield", "t": 0.0, "dur": 0.16, "amp": clean_intensity})
		"stall":
			sfx_queue.append({"type": "stall", "t": 0.0, "dur": 0.40, "amp": clean_intensity})
		"blocked":
			sfx_queue.append({"type": "blocked", "t": 0.0, "dur": 0.16, "amp": clean_intensity})
		"alarm":
			sfx_queue.append({"type": "alarm", "t": 0.0, "dur": 0.24, "amp": clean_intensity})
		"overheat", "explosion", "player_hit":
			sfx_queue.append({"type": "alarm_boom", "t": 0.0, "dur": 0.36, "amp": clean_intensity})
		"victory_chime":
			sfx_queue.append({"type": "victory", "t": 0.0, "dur": 0.44, "amp": clean_intensity})
		_:
			sfx_queue.append({"type": "switch", "t": 0.0, "dur": 0.04, "amp": 0.4})

func _process(delta: float) -> void:
	if repo == null:
		return
	var acfg: Dictionary = repo.audio_cfg()
	smoothed_rpm_units = lerpf(smoothed_rpm_units, target_rpm_units, clampf(delta * 6.5, 0.0, 1.0))
	var target_spd: float = target_speed_mps if active_tunnel_drive else 0.0
	smoothed_speed_mps = lerpf(smoothed_speed_mps, target_spd, clampf(delta * 4.5, 0.0, 1.0))
	rev_flare = maxf(0.0, rev_flare - delta * float(acfg.get("engine_rev_flare_decay", 1.85)))
	_fill_engine_buffer(acfg)
	_fill_sfx_buffer(acfg)

func _fill_engine_buffer(acfg: Dictionary) -> void:
	if engine_player == null or not is_instance_valid(engine_player) or not engine_player.playing:
		return
	var pb_raw: AudioStreamPlayback = engine_player.get_stream_playback()
	if not (pb_raw is AudioStreamGeneratorPlayback):
		return
	var engine_playback: AudioStreamGeneratorPlayback = pb_raw as AudioStreamGeneratorPlayback
	var frames: int = engine_playback.get_frames_available()
	if frames <= 0:
		return

	if is_engine_muted() or engine_volume <= 0.001 or not window_focused:
		if engine_buf_vec.size() != frames:
			engine_buf_vec.resize(frames)
		engine_buf_vec.fill(Vector2.ZERO)
		engine_playback.push_buffer(engine_buf_vec)
		return

	var base_hz: float = float(acfg.get("engine_base_hz", 28.0))
	var hz_per_unit: float = float(acfg.get("engine_hz_per_rpm_unit", 9.5))
	var gain_idle: float = float(acfg.get("engine_gain_idle", 0.026))
	var gain_max: float = float(acfg.get("engine_gain_max", 0.078))
	var flare_gain: float = float(acfg.get("engine_rev_flare_gain", 0.088))
	var cutoff_hz: float = maxf(40.0, float(acfg.get("engine_lowpass_cutoff_hz", 150.0)))
	var red_buzz: float = float(acfg.get("redline_buzz_gain", 0.012))
	var drone_gain: float = float(acfg.get("ambient_drone_gain", 0.016)) * (0.65 + current_heat_ratio * 0.65)
	var road_gain_cfg: float = float(acfg.get("road_noise_gain", 0.022))
	var threat_gain_cfg: float = float(acfg.get("threat_pulse_gain", 0.026))

	var is_dozer: bool = (active_chassis_id == "bulldozer")
	var is_proto: bool = (active_chassis_id == "turbo_proto")
	if is_dozer:
		base_hz *= 0.68
		hz_per_unit *= 0.72
		cutoff_hz = 112.0
	elif is_proto:
		base_hz *= 1.48
		hz_per_unit *= 1.45
		cutoff_hz = 340.0

	var rpm_norm: float = clampf(smoothed_rpm_units / 8.0, 0.0, 1.0)
	var gear_abs: int = absi(current_gear_index)
	var gear_pitch_trim: float = 1.0 + float(maxi(0, gear_abs - 1)) * 0.035
	var freq: float = (base_hz + smoothed_rpm_units * hz_per_unit) * gear_pitch_trim
	var drive_trim: float = 0.85 if active_tunnel_drive else 0.42
	var steady_amp: float = (lerpf(gain_idle, gain_max, rpm_norm) * drive_trim) if smoothed_rpm_units >= 0.05 else 0.0
	var bus_amp: float = master_volume * engine_volume
	var total_amp: float = (steady_amp + rev_flare * flare_gain) * bus_amp
	var pulse_hz: float = (1.6 + float(gear_abs) * 0.72 + rpm_norm * 1.1) if active_tunnel_drive else 1.25
	var pulse_depth: float = (0.14 + float(gear_abs) * 0.028) if active_tunnel_drive else 0.06
	if is_dozer:
		pulse_hz *= 0.58
		pulse_depth = minf(0.48, pulse_depth * 1.9 + 0.12)
	elif is_proto:
		pulse_hz *= 1.55
		pulse_depth *= 0.55

	var abs_speed: float = absf(smoothed_speed_mps)
	var speed_norm: float = clampf(abs_speed / 27.0, 0.0, 1.0)
	var joint_rate_hz: float = abs_speed / 6.0
	var duct_rate_hz: float = abs_speed / 12.0

	var drone_hz_a: float = 46.0
	var drone_hz_b: float = 69.0
	var site_crackle: float = 0.0
	match active_env_mode:
		"title":
			drone_hz_a = 36.5
			drone_hz_b = 54.75
		"workshop", "rest":
			drone_hz_a = 50.0
			drone_hz_b = 75.0
			site_crackle = 0.16
		"upgrade":
			drone_hz_a = 60.0
			drone_hz_b = 120.0
		"event":
			drone_hz_a = 55.0
			drone_hz_b = 83.2

	var threat_active: bool = active_tunnel_drive and active_threat_tier > 0 and (active_env_mode == "combat" or active_env_mode == "enemy_turn" or active_env_mode == "shift_choice")
	var threat_step_hz: float = 2.20 if active_threat_tier >= 2 else 1.80
	var threat_amp: float = (threat_gain_cfg * (1.18 if active_threat_tier >= 2 else 0.78)) * bus_amp if threat_active else 0.0

	var turbo_hz: float = 540.0 + rpm_norm * 880.0 + rev_flare * 260.0
	var dt: float = 1.0 / sample_rate
	var rc: float = 1.0 / (TAU * cutoff_hz)
	var alpha: float = dt / (rc + dt)
	var drone_alpha: float = dt / ((1.0 / (TAU * 105.0)) + dt)
	var road_lp_alpha: float = dt / ((1.0 / (TAU * (160.0 + speed_norm * 420.0))) + dt)
	var road_hp_alpha: float = dt / ((1.0 / (TAU * 65.0)) + dt)

	if engine_buf_vec.size() != frames:
		engine_buf_vec.resize(frames)

	for fi: int in range(frames):
		phase_primary += freq * dt
		if phase_primary >= 1.0:
			phase_primary -= 1.0
		phase_sub += (freq * 0.5) * dt
		if phase_sub >= 1.0:
			phase_sub -= 1.0
		phase_pulse += pulse_hz * dt
		if phase_pulse >= 1.0:
			phase_pulse -= 1.0
		phase_drone += drone_hz_a * dt
		if phase_drone >= 1.0:
			phase_drone -= 1.0
		phase_drone_b += drone_hz_b * dt
		if phase_drone_b >= 1.0:
			phase_drone_b -= 1.0
		phase_drone_lfo += 0.37 * dt
		if phase_drone_lfo >= 1.0:
			phase_drone_lfo -= 1.0

		var warm_wave: float = 0.0
		if total_amp > 0.0001:
			var chug_env: float = 1.0 - pulse_depth + pulse_depth * (0.5 + 0.5 * sin(phase_pulse * TAU))
			if is_dozer:
				var raw_d: float = sin(phase_primary * TAU) * 1.15 + sin(phase_sub * TAU) * 0.75 + sin(phase_primary * TAU * 3.0) * 0.38
				warm_wave = (raw_d / (1.0 + absf(raw_d))) * chug_env * 1.25
			elif is_proto:
				phase_turbo += turbo_hz * dt
				if phase_turbo >= 1.0:
					phase_turbo -= 1.0
				var scream: float = sin(phase_primary * TAU) * 0.46 + sin(phase_primary * TAU * 2.0) * 0.34 + sin(phase_primary * TAU * 3.0) * 0.18
				var spool: float = sin(phase_turbo * TAU) * (0.06 + rpm_norm * 0.12 + rev_flare * 0.10)
				warm_wave = scream * chug_env + spool
			else:
				var burble: float = sin(phase_sub * TAU * 1.5) * (0.22 if active_tunnel_drive else 0.08)
				warm_wave = (sin(phase_primary * TAU) * 0.48 + sin(phase_sub * TAU) * 0.46 + burble) * chug_env
			if in_redline:
				warm_wave += sin(phase_primary * TAU * 2.0) * red_buzz * (4.0 + rev_flare * 8.0)

		lowpass_state = lowpass_state + alpha * (warm_wave - lowpass_state)

		var raw_noise: float = noise_rng.randf_range(-1.0, 1.0)
		var vent_air: float = raw_noise * (0.32 + site_crackle * (1.0 if raw_noise > 0.82 else 0.0)) + sin(phase_drone * TAU) * 0.52 + sin(phase_drone_b * TAU) * 0.28
		drone_lp_state = drone_lp_state + drone_alpha * (vent_air - drone_lp_state)
		var lfo_mod: float = 0.78 + 0.22 * sin(phase_drone_lfo * TAU)
		var ambient: float = drone_lp_state * drone_gain * lfo_mod * bus_amp

		var road_sample: float = 0.0
		if active_tunnel_drive and speed_norm > 0.02:
			phase_road_joint += joint_rate_hz * dt
			if phase_road_joint >= 1.0:
				phase_road_joint -= 1.0
			phase_duct_pass += duct_rate_hz * dt
			if phase_duct_pass >= 1.0:
				phase_duct_pass -= 1.0
			road_lp_state += road_lp_alpha * (raw_noise - road_lp_state)
			road_hp_state += road_hp_alpha * (road_lp_state - road_hp_state)
			var tire_roar: float = (road_lp_state - road_hp_state) * (0.35 + speed_norm * 0.85)
			var duct_whoosh: float = road_lp_state * (0.25 + 0.75 * pow(0.5 + 0.5 * sin(phase_duct_pass * TAU), 3.0)) * speed_norm * 0.55
			var joint_thud: float = 0.0
			if phase_road_joint < 0.09:
				joint_thud = exp(-phase_road_joint * 48.0) * sin(phase_road_joint * TAU * 42.0) * 0.65
			elif phase_road_joint > 0.11 and phase_road_joint < 0.19:
				var jt2: float = phase_road_joint - 0.11
				joint_thud = exp(-jt2 * 52.0) * sin(jt2 * TAU * 36.0) * 0.48
			road_sample = (tire_roar + duct_whoosh + joint_thud * speed_norm) * road_gain_cfg * bus_amp

		var threat_sample: float = 0.0
		if threat_amp > 0.0001:
			phase_threat_step += threat_step_hz * dt
			if phase_threat_step >= 4.0:
				phase_threat_step -= 4.0
			var step_i: int = clampi(int(phase_threat_step), 0, 3)
			var beat_frac: float = phase_threat_step - float(step_i)
			var note_hz: float = THREAT_RIFF_HZ[step_i]
			phase_threat_osc += note_hz * dt
			if phase_threat_osc >= 1.0:
				phase_threat_osc -= 1.0
			var bass_env: float = exp(-beat_frac * 4.2)
			var bass_raw: float = sin(phase_threat_osc * TAU) * 0.75 + sin(phase_threat_osc * TAU * 2.0) * 0.45
			var hat_env: float = exp(-(beat_frac - 0.5) * 26.0) if (beat_frac >= 0.5 and beat_frac < 0.72) else 0.0
			threat_sample = (bass_raw * bass_env + raw_noise * hat_env * 0.28) * threat_amp

		var sample: float = clampf(lowpass_state * total_amp + ambient + road_sample + threat_sample, -0.88, 0.88)
		engine_buf_vec[fi] = Vector2(sample, sample)
	engine_playback.push_buffer(engine_buf_vec)

func _fill_sfx_buffer(acfg: Dictionary) -> void:
	if sfx_player == null or not is_instance_valid(sfx_player) or not sfx_player.playing:
		return
	var pb_raw: AudioStreamPlayback = sfx_player.get_stream_playback()
	if not (pb_raw is AudioStreamGeneratorPlayback):
		return
	var sfx_playback: AudioStreamGeneratorPlayback = pb_raw as AudioStreamGeneratorPlayback
	var frames: int = sfx_playback.get_frames_available()
	if frames <= 0:
		return
	if sfx_buf_vec.size() != frames:
		sfx_buf_vec.resize(frames)
	if is_engine_muted() or sfx_volume <= 0.001 or not window_focused or sfx_queue.is_empty():
		if is_engine_muted() or sfx_volume <= 0.001 or not window_focused:
			sfx_queue.clear()
		sfx_buf_vec.fill(Vector2.ZERO)
		sfx_playback.push_buffer(sfx_buf_vec)
		return
	var master_gain: float = float(acfg.get("sfx_master_gain", 0.23)) * master_volume * sfx_volume
	var dt: float = 1.0 / sample_rate
	for fi: int in range(frames):
		var mix: float = 0.0
		var idx: int = sfx_queue.size() - 1
		while idx >= 0:
			var ev: Dictionary = sfx_queue[idx]
			var t: float = float(ev.get("t", 0.0))
			var dur: float = maxf(0.01, float(ev.get("dur", 0.1)))
			if t >= dur:
				sfx_queue.remove_at(idx)
			else:
				mix += _sample_sfx(str(ev.get("type", "")), t, dur) * float(ev.get("amp", 1.0))
				ev["t"] = t + dt
			idx -= 1
		var out_val: float = clampf(mix * master_gain, -0.9, 0.9)
		sfx_buf_vec[fi] = Vector2(out_val, out_val)
	sfx_playback.push_buffer(sfx_buf_vec)

func _sample_sfx(kind: String, t: float, dur: float) -> float:
	var env: float = maxf(0.0, 1.0 - (t / dur))
	match kind:
		"clack":
			var hit_a: float = exp(-t * 105.0) * (sin(t * TAU * 360.0) + noise_rng.randf_range(-0.4, 0.4))
			var t2: float = t - 0.052
			var hit_b: float = (exp(-t2 * 95.0) * (sin(t2 * TAU * 510.0) + noise_rng.randf_range(-0.35, 0.35))) if t2 > 0.0 else 0.0
			return (hit_a + hit_b) * 0.72
		"rev_match":
			var n_hz: float = 587.33 if t < 0.075 else 880.0
			var bell: float = sin(t * TAU * n_hz) * 0.55 + sin(t * TAU * n_hz * 2.0) * 0.22
			return bell * exp(-t * 11.0) * 0.78
		"clutch_kick":
			var snap: float = exp(-t * 95.0) * (sin(t * TAU * 480.0) + noise_rng.randf_range(-0.6, 0.6))
			var bark_hz: float = 95.0 + sin(clampf(t / dur, 0.0, 1.0) * PI) * 190.0
			var bark: float = (sin(t * TAU * bark_hz) * 0.65 + sin(t * TAU * bark_hz * 2.0) * 0.35) * sin(clampf(t / dur, 0.0, 1.0) * PI)
			return snap * 0.55 + bark * 0.75
		"turbo_blowoff":
			var flutter: float = 0.55 + 0.45 * sin(t * TAU * 23.0)
			var whistle_hz: float = 1350.0 - t * 2400.0
			var whistle: float = sin(t * TAU * maxf(320.0, whistle_hz)) * 0.32
			var air: float = noise_rng.randf_range(-0.75, 0.75) * flutter
			return (whistle + air * 0.68) * env * 0.80
		"coolant_vent":
			var swell: float = sin(clampf(t / dur, 0.0, 1.0) * PI)
			var hiss: float = noise_rng.randf_range(-0.85, 0.85) * 0.62 + sin(t * TAU * (620.0 - t * 900.0)) * 0.22
			return hiss * swell * 0.76
		"gun_burst":
			var burst_mod: float = fmod(t, 0.078)
			if burst_mod > 0.044:
				return 0.0
			var b_env: float = exp(-burst_mod * 65.0)
			var bang: float = sin(burst_mod * TAU * (185.0 - burst_mod * 1400.0)) * 0.72 + noise_rng.randf_range(-0.85, 0.85) * 0.65
			return bang * b_env * 0.90
		"ram_crunch":
			var sub: float = sin(t * TAU * maxf(32.0, 96.0 - t * 240.0)) * 0.82
			var metal: float = sin(t * TAU * 312.0) * exp(-t * 28.0) * 0.35 + noise_rng.randf_range(-0.75, 0.75) * exp(-t * 22.0) * 0.60
			return (sub + metal) * env * 0.95
		"steam_hiss":
			var attack_env: float = minf(1.0, t * 28.0) * exp(-t * 6.5)
			return (noise_rng.randf_range(-0.7, 0.7) * 0.68 + sin(t * TAU * 840.0) * exp(-t * 35.0) * 0.22) * attack_env * 0.55
		"weld_arc":
			var buzz: float = 1.0 if sin(t * TAU * 100.0) > 0.0 else -1.0
			var sputter: float = 1.0 if noise_rng.randf() > 0.32 else 0.15
			return (buzz * 0.32 + noise_rng.randf_range(-0.8, 0.8) * 0.68) * sputter * env * 0.42
		"forge_anvil":
			var thud: float = sin(t * TAU * maxf(38.0, 110.0 - t * 220.0)) * exp(-t * 18.0) * 0.72
			var ring: float = (sin(t * TAU * 428.0) * 0.48 + sin(t * TAU * 692.0) * 0.32 + sin(t * TAU * 1045.0) * 0.20) * exp(-t * 9.5)
			return (thud + ring) * 0.85
		"air_brake":
			var valve: float = exp(-t * 90.0) * sin(t * TAU * 520.0) * 0.45
			var release: float = noise_rng.randf_range(-0.75, 0.75) * exp(-t * 7.5) * 0.62
			return (valve + release) * 0.72
		"tire_screech":
			var squeal_hz: float = 690.0 + sin(t * 42.0) * 85.0 - t * 260.0
			var squeal: float = sin(t * TAU * squeal_hz) * 0.42 + sin(t * TAU * squeal_hz * 1.48) * 0.24
			var scrub: float = noise_rng.randf_range(-0.6, 0.6) * 0.48
			return (squeal + scrub) * sin(clampf(t / dur, 0.0, 1.0) * PI) * 0.62
		"hydraulic_servo":
			var srv_hz: float = 235.0 + (t / dur) * 185.0
			return (sin(t * TAU * srv_hz) * 0.48 + sin(t * TAU * srv_hz * 2.0) * 0.22) * sin(clampf(t / dur, 0.0, 1.0) * PI) * 0.48
		"grind":
			var grate: float = sin(t * TAU * (165.0 + sin(t * 65.0) * 45.0))
			return (grate * 0.55 + noise_rng.randf_range(-0.55, 0.55) * 0.45) * env
		"slam":
			return (sin(t * TAU * (125.0 - t * 340.0)) * 0.75 + noise_rng.randf_range(-0.3, 0.3) * exp(-t * 45.0)) * env
		"switch":
			return exp(-t * 150.0) * sin(t * TAU * 780.0) * 0.7
		"card":
			return sin(t * TAU * (300.0 + t * 950.0)) * env * 0.48
		"impact":
			return (sin(t * TAU * (88.0 - t * 190.0)) * 0.8 + noise_rng.randf_range(-0.5, 0.5) * exp(-t * 28.0)) * env
		"shield":
			return (sin(t * TAU * 440.0) * 0.45 + sin(t * TAU * 660.0) * 0.35) * env * 0.55
		"stall":
			var drop_hz: float = maxf(24.0, 115.0 - t * 210.0)
			return sin(t * TAU * drop_hz) * env * 0.70
		"blocked":
			var buzz_hz: float = 140.0 if t < dur * 0.5 else 108.0
			return sin(t * TAU * buzz_hz) * env * 0.58
		"alarm":
			var beep_hz: float = 520.0 if fmod(t, 0.12) < 0.06 else 390.0
			return sin(t * TAU * beep_hz) * env * 0.45
		"alarm_boom":
			var siren: float = sin(t * TAU * (420.0 if fmod(t, 0.12) < 0.06 else 310.0)) * 0.35
			var boom: float = noise_rng.randf_range(-0.6, 0.6) * exp(-t * 15.0) * 0.55
			return (siren + boom) * env
		"victory":
			var note: float = 440.0 if t < 0.14 else (554.37 if t < 0.28 else 659.25)
			return (sin(t * TAU * note) * 0.68 + sin(t * TAU * note * 2.0) * 0.24) * env * 0.58
		"throttle_blip":
			var blip_env: float = sin(clampf(t / dur, 0.0, 1.0) * PI)
			var sweep_hz: float = 72.0 + sin(clampf(t / dur, 0.0, 1.0) * PI) * 165.0
			var tone_a: float = sin(t * TAU * sweep_hz) * 0.65
			var tone_b: float = sin(t * TAU * sweep_hz * 1.5) * 0.35
			var intake_air: float = noise_rng.randf_range(-0.4, 0.4) * exp(-t * 24.0)
			return (tone_a + tone_b + intake_air) * blip_env * 0.92
		_:
			return 0.0
