class_name TutorialController
extends Node

signal objective_changed(text: String)
signal callout_changed(step_data: Dictionary, index: int, total: int)
signal tutorial_finished

var repo: GameRepository
var engine: CombatEngine

var steps: Array[Dictionary] = []
var step_index: int = -1
var connected: bool = false
var is_quick_mode: bool = false

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine

func is_active() -> bool:
	return step_index >= 0 and step_index < steps.size()

func current_step_key() -> String:
	if not is_active():
		return ""
	return str(steps[step_index].get("key", ""))

func current_step() -> Dictionary:
	if not is_active():
		return {}
	return steps[step_index]

func start(quick_mode: bool = false) -> void:
	if repo == null or engine == null:
		return
	is_quick_mode = quick_mode
	if quick_mode:
		steps = [
			{
				"key": "cards",
				"title": repo.get_ui_text("combat", "quick_tour_step_1_title"),
				"keys": repo.get_ui_text("combat", "quick_tour_step_1_keys"),
				"body": repo.get_ui_text("combat", "quick_tour_step_1_body"),
				"yaw": 1.5,
				"pitch": -4.5
			},
			{
				"key": "shifter",
				"title": repo.get_ui_text("combat", "quick_tour_step_2_title"),
				"keys": repo.get_ui_text("combat", "quick_tour_step_2_keys"),
				"body": repo.get_ui_text("combat", "quick_tour_step_2_body"),
				"yaw": -11.5,
				"pitch": -7.5
			},
			{
				"key": "slam",
				"title": repo.get_ui_text("combat", "quick_tour_step_3_title"),
				"keys": repo.get_ui_text("combat", "quick_tour_step_3_keys"),
				"body": repo.get_ui_text("combat", "quick_tour_step_3_body"),
				"yaw": -14.0,
				"pitch": -2.0
			}
		]
	else:
		steps = [
			{
				"key": "cards",
				"title": repo.get_ui_text("combat", "tour_step_1_title"),
				"keys": repo.get_ui_text("combat", "tour_step_1_keys"),
				"body": repo.get_ui_text("combat", "tour_step_1_body"),
				"yaw": 1.5,
				"pitch": -4.5
			},
			{
				"key": "shifter",
				"title": repo.get_ui_text("combat", "tour_step_2_title"),
				"keys": repo.get_ui_text("combat", "tour_step_2_keys"),
				"body": repo.get_ui_text("combat", "tour_step_2_body"),
				"yaw": -11.5,
				"pitch": -7.5
			},
			{
				"key": "gauges",
				"title": repo.get_ui_text("combat", "tour_step_3_title"),
				"keys": repo.get_ui_text("combat", "tour_step_3_keys"),
				"body": repo.get_ui_text("combat", "tour_step_3_body"),
				"yaw": 4.0,
				"pitch": 0.5
			},
			{
				"key": "enemies",
				"title": repo.get_ui_text("combat", "tour_step_4_title"),
				"keys": repo.get_ui_text("combat", "tour_step_4_keys"),
				"body": repo.get_ui_text("combat", "tour_step_4_body"),
				"yaw": 0.0,
				"pitch": 5.5
			},
			{
				"key": "overhead",
				"title": repo.get_ui_text("combat", "tour_step_5_title"),
				"keys": repo.get_ui_text("combat", "tour_step_5_keys"),
				"body": repo.get_ui_text("combat", "tour_step_5_body"),
				"yaw": -4.0,
				"pitch": 9.0
			},
			{
				"key": "screens",
				"title": repo.get_ui_text("combat", "tour_step_6_title"),
				"keys": repo.get_ui_text("combat", "tour_step_6_keys"),
				"body": repo.get_ui_text("combat", "tour_step_6_body"),
				"yaw": 2.0,
				"pitch": -1.0
			},
			{
				"key": "slam",
				"title": repo.get_ui_text("combat", "tour_step_7_title"),
				"keys": repo.get_ui_text("combat", "tour_step_7_keys"),
				"body": repo.get_ui_text("combat", "tour_step_7_body"),
				"yaw": -14.0,
				"pitch": -2.0
			}
		]
	if not connected:
		connected = true
		engine.state_changed.connect(_on_engine_state_changed)
		engine.run_ended.connect(_on_run_ended)
	step_index = 0
	engine.sfx_requested.emit("hydraulic_servo", 0.65)
	_emit_current()

func next_step() -> void:
	if not is_active():
		return
	if step_index + 1 >= steps.size():
		engine.sfx_requested.emit("victory_chime", 0.65)
		stop()
		return
	step_index += 1
	engine.sfx_requested.emit("switch_click", 0.72)
	_emit_current()

func prev_step() -> void:
	if not is_active() or step_index <= 0:
		return
	step_index -= 1
	engine.sfx_requested.emit("switch_click", 0.65)
	_emit_current()

func stop() -> void:
	if step_index < 0:
		return
	step_index = -1
	is_quick_mode = false
	objective_changed.emit("")
	callout_changed.emit({}, -1, 0)
	tutorial_finished.emit()

func _emit_current() -> void:
	var cur: Dictionary = steps[step_index]
	var hdr: String = repo.get_ui_text("combat", "tour_header_fmt") % [step_index + 1, steps.size(), str(cur.get("title", ""))]
	objective_changed.emit(hdr)
	callout_changed.emit(cur, step_index, steps.size())

func _on_engine_state_changed() -> void:
	if is_active() and engine.mode != CombatEngine.MODE_COMBAT:
		stop()

func _on_run_ended(_victory: bool, _summary: String) -> void:
	if is_active():
		stop()
