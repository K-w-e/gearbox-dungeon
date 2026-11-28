class_name EngineAudioController
extends Node

const VOLUME_PRESETS: Array[float] = [1.0, 0.60, 0.25, 0.0]
const SILENT_DB: float = -80.0

var repo: GameRepository
var engine_player: AudioStreamPlayer
var road_player: AudioStreamPlayer
var ambient_player: AudioStreamPlayer
var threat_player: AudioStreamPlayer
var sfx_pool: Array[AudioStreamPlayer] = []
var sfx_pool_cursor: int = 0

var engine_streams: Dictionary = {}
var ambient_streams: Dictionary = {}
var road_stream: AudioStream
var threat_stream: AudioStream
var sfx_streams: Dictionary = {}
var chassis_pitch_map: Dictionary = {}
var sfx_queue: Array[Dictionary] = []

var smoothed_rpm_units: float = 2.0
var target_rpm_units: float = 2.0
var smoothed_speed_mps: float = 0.0
var target_speed_mps: float = 0.0
var current_gear_index: int = 1
var current_heat_ratio: float = 0.0
var active_tunnel_drive: bool = false
var active_chassis_id: String = "interceptor"
var active_env_mode: String = "title"
var active_ambient_key: String = ""
var active_threat_tier: int = 0
var rev_flare: float = 0.0
var in_redline: bool = false
var engine_muted: bool = false
var master_volume: float = 1.0
var pre_mute_volume: float = 1.0
var engine_volume: float = 1.0
var sfx_volume: float = 1.0
var window_focused: bool = true
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func initialize(repository: GameRepository) -> void:
	repo = repository
	rng.randomize()
	var acfg: Dictionary = repo.audio_cfg()
	chassis_pitch_map = acfg.get("engine_chassis_pitch", {})
	_preload_streams(acfg)

	engine_player = _create_loop_player(engine_streams.get(active_chassis_id, null))
	road_player = _create_loop_player(road_stream)
	ambient_player = _create_loop_player(ambient_streams.get("hangar", null))
	active_ambient_key = "hangar"
	threat_player = _create_loop_player(threat_stream)

	var pool_size: int = maxi(4, int(acfg.get("sfx_pool_size", 10)))
	sfx_pool.clear()
	for _i: int in range(pool_size):
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		add_child(p)
		sfx_pool.append(p)

func _preload_streams(acfg: Dictionary) -> void:
	var loops_cfg: Dictionary = acfg.get("loops", {})
	var eng_map: Dictionary = loops_cfg.get("engines", {})
	for cid: String in eng_map.keys():
		var stream: AudioStream = _load_audio_stream(str(eng_map[cid]), true)
		if stream != null:
			engine_streams[cid] = stream

	var hangar_stream: AudioStream = _load_audio_stream(str(loops_cfg.get("ambient_hangar", "")), true)
	if hangar_stream != null:
		ambient_streams["hangar"] = hangar_stream
	var workshop_stream: AudioStream = _load_audio_stream(str(loops_cfg.get("ambient_workshop", "")), true)
	if workshop_stream != null:
		ambient_streams["workshop"] = workshop_stream

	road_stream = _load_audio_stream(str(loops_cfg.get("road_tunnel", "")), true)
	threat_stream = _load_audio_stream(str(loops_cfg.get("threat_pulse", "")), true)

	var sfx_map: Dictionary = acfg.get("sfx_paths", {})
	for sfx_id: String in sfx_map.keys():
		var s: AudioStream = _load_audio_stream(str(sfx_map[sfx_id]), false)
		if s != null:
			sfx_streams[sfx_id] = s

func _load_audio_stream(path: String, looping: bool) -> AudioStream:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is AudioStreamOggVorbis:
		(res as AudioStreamOggVorbis).loop = looping
	elif res is AudioStreamWAV:
		(res as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD if looping else AudioStreamWAV.LOOP_DISABLED
	return res as AudioStream

func _create_loop_player(stream: AudioStream) -> AudioStreamPlayer:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.volume_db = SILENT_DB
	if stream != null:
		p.stream = stream
	add_child(p)
	if stream != null:
		p.play()
	return p

func _exit_tree() -> void:
	for p: AudioStreamPlayer in [engine_player, road_player, ambient_player, threat_player]:
		if p != null and is_instance_valid(p):
			p.stop()
	for sp: AudioStreamPlayer in sfx_pool:
		if sp != null and is_instance_valid(sp):
			sp.stop()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		window_focused = false
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		window_focused = true
		ensure_playback_active()

func _input(event: InputEvent) -> void:
	if (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) or (event is InputEventKey and (event as InputEventKey).pressed):
		ensure_playback_active()

func ensure_playback_active() -> void:
	for p: AudioStreamPlayer in [engine_player, road_player, ambient_player, threat_player]:
		if p != null and is_instance_valid(p) and p.stream != null and not p.playing:
			p.play()

func set_chassis_profile(chassis_id: String) -> void:
	if chassis_id.is_empty() or chassis_id == active_chassis_id:
		return
	active_chassis_id = chassis_id
	if engine_player != null and engine_streams.has(chassis_id):
		var next_stream: AudioStream = engine_streams[chassis_id] as AudioStream
		if engine_player.stream != next_stream:
			engine_player.stream = next_stream
			engine_player.play()

func set_environment_context(env_mode: String, tunnel_speed_mps: float = 0.0, threat_tier: int = 0) -> void:
	active_env_mode = env_mode
	target_speed_mps = clampf(tunnel_speed_mps, -12.0, 35.0)
	active_threat_tier = clampi(threat_tier, 0, 2)
	var desired_amb: String = "workshop" if (env_mode == "workshop" or env_mode == "rest" or env_mode == "upgrade") else "hangar"
	if desired_amb != active_ambient_key and ambient_player != null and ambient_streams.has(desired_amb):
		active_ambient_key = desired_amb
		ambient_player.stream = ambient_streams[desired_amb] as AudioStream
		ambient_player.play()

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
		_stop_sfx_pool()

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
		_stop_sfx_pool()
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
		_stop_sfx_pool()

func _stop_sfx_pool() -> void:
	sfx_queue.clear()
	for sp: AudioStreamPlayer in sfx_pool:
		if sp != null and is_instance_valid(sp):
			sp.stop()

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
	if is_engine_muted() or sfx_volume <= 0.001 or not window_focused or repo == null:
		return
	var acfg: Dictionary = repo.audio_cfg()
	var clean_intensity: float = clampf(intensity, 0.08, 1.35)
	if sfx_id == "shift_clack" or sfx_id == "grind":
		rev_flare = clampf(rev_flare + 0.45, 0.0, 1.0)
	elif sfx_id == "clutch_kick" or sfx_id == "turbo_blowoff":
		rev_flare = clampf(rev_flare + 0.65 * clean_intensity, 0.0, 1.35)
	elif sfx_id == "throttle_blip":
		var blip_flare: float = float(acfg.get("throttle_blip_flare", 0.95))
		rev_flare = clampf(rev_flare + blip_flare * clean_intensity, 0.0, 1.6)

	var stream: AudioStream = sfx_streams.get(sfx_id, sfx_streams.get("switch_click", null)) as AudioStream
	if stream == null or sfx_pool.is_empty():
		return

	var player: AudioStreamPlayer = _acquire_sfx_player()
	var base_db: float = float(acfg.get("sfx_volume_db", -3.0))
	var jitter: float = float(acfg.get("sfx_pitch_jitter", 0.04))
	player.stream = stream
	player.volume_db = base_db + linear_to_db(clampf(clean_intensity * master_volume * sfx_volume, 0.0001, 2.0))
	player.pitch_scale = 1.0 + rng.randf_range(-jitter, jitter)
	player.play()
	if sfx_queue.size() >= sfx_pool.size():
		sfx_queue.pop_front()
	sfx_queue.append({"id": sfx_id, "intensity": clean_intensity})

func _acquire_sfx_player() -> AudioStreamPlayer:
	for i: int in range(sfx_pool.size()):
		var idx: int = (sfx_pool_cursor + i) % sfx_pool.size()
		if not sfx_pool[idx].playing:
			sfx_pool_cursor = (idx + 1) % sfx_pool.size()
			return sfx_pool[idx]
	var chosen: AudioStreamPlayer = sfx_pool[sfx_pool_cursor]
	sfx_pool_cursor = (sfx_pool_cursor + 1) % sfx_pool.size()
	return chosen

func _process(delta: float) -> void:
	if repo == null:
		return
	var acfg: Dictionary = repo.audio_cfg()
	smoothed_rpm_units = lerpf(smoothed_rpm_units, target_rpm_units, clampf(delta * 6.5, 0.0, 1.0))
	var target_spd: float = target_speed_mps if active_tunnel_drive else 0.0
	smoothed_speed_mps = lerpf(smoothed_speed_mps, target_spd, clampf(delta * 4.5, 0.0, 1.0))
	rev_flare = maxf(0.0, rev_flare - delta * float(acfg.get("engine_rev_flare_decay", 1.85)))

	var bus_linear: float = master_volume * engine_volume
	if is_engine_muted() or bus_linear <= 0.001 or not window_focused:
		_silence_loops()
		return

	var bus_db: float = linear_to_db(bus_linear)
	_update_engine_player(acfg, bus_db)
	_update_road_player(acfg, bus_db)
	_update_ambient_player(acfg, bus_db)
	_update_threat_player(acfg, bus_db)

func _silence_loops() -> void:
	for p: AudioStreamPlayer in [engine_player, road_player, ambient_player, threat_player]:
		if p != null and is_instance_valid(p):
			p.volume_db = SILENT_DB

func _update_engine_player(acfg: Dictionary, bus_db: float) -> void:
	if engine_player == null or engine_player.stream == null:
		return
	if smoothed_rpm_units < 0.05 and rev_flare < 0.02:
		engine_player.volume_db = SILENT_DB
		return
	var rpm_norm: float = clampf(smoothed_rpm_units / 8.0, 0.0, 1.0)
	var pitch_min: float = float(acfg.get("engine_pitch_min", 0.78))
	var pitch_max: float = float(acfg.get("engine_pitch_max", 1.58))
	var flare_pitch: float = float(acfg.get("engine_rev_flare_pitch", 0.22))
	var chassis_pitch: float = float(chassis_pitch_map.get(active_chassis_id, 1.0))
	var gear_trim: float = 1.0 + float(maxi(0, absi(current_gear_index) - 1)) * 0.025
	engine_player.pitch_scale = clampf((lerpf(pitch_min, pitch_max, rpm_norm) + rev_flare * flare_pitch) * gear_trim * chassis_pitch, 0.45, 2.4)

	var idle_db: float = float(acfg.get("engine_idle_db", -16.0))
	var max_db: float = float(acfg.get("engine_max_db", -8.0))
	var drive_trim_db: float = 0.0 if active_tunnel_drive else -4.5
	var flare_db: float = minf(4.0, rev_flare * 3.5)
	engine_player.volume_db = clampf(lerpf(idle_db, max_db, rpm_norm) + drive_trim_db + flare_db + bus_db, SILENT_DB, 0.0)

func _update_road_player(acfg: Dictionary, bus_db: float) -> void:
	if road_player == null or road_player.stream == null:
		return
	var speed_norm: float = clampf(absf(smoothed_speed_mps) / 27.0, 0.0, 1.0)
	if not active_tunnel_drive or speed_norm <= 0.02:
		road_player.volume_db = SILENT_DB
		return
	var road_max_db: float = float(acfg.get("road_max_db", -14.0))
	road_player.pitch_scale = lerpf(0.75, 1.35, speed_norm)
	road_player.volume_db = clampf(road_max_db + linear_to_db(speed_norm) + bus_db, SILENT_DB, 0.0)

func _update_ambient_player(acfg: Dictionary, bus_db: float) -> void:
	if ambient_player == null or ambient_player.stream == null:
		return
	var amb_db: float = float(acfg.get("ambient_db", -20.0))
	var heat_boost_db: float = current_heat_ratio * 2.5
	ambient_player.volume_db = clampf(amb_db + heat_boost_db + bus_db, SILENT_DB, 0.0)

func _update_threat_player(acfg: Dictionary, bus_db: float) -> void:
	if threat_player == null or threat_player.stream == null:
		return
	var threat_active: bool = active_tunnel_drive and active_threat_tier > 0 and (active_env_mode == "combat" or active_env_mode == "enemy_turn" or active_env_mode == "shift_choice")
	if not threat_active:
		threat_player.volume_db = SILENT_DB
		return
	var target_db: float = float(acfg.get("threat_db_boss", -15.0)) if active_threat_tier >= 2 else float(acfg.get("threat_db_elite", -20.0))
	threat_player.pitch_scale = 1.12 if active_threat_tier >= 2 else 0.96
	threat_player.volume_db = clampf(target_db + bus_db, SILENT_DB, 0.0)
