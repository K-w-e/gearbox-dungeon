class_name DiegeticTerminal3D
extends Node3D

signal shift_option_selected(delta_gear: int)
signal reward_card_chosen(card_id: String)
signal workshop_action_pressed(action_id: String)
signal restart_requested
signal title_action_pressed(action_id: String)
signal pause_action_pressed(action_id: String)
signal chassis_preview_hovered(chassis_id: String)

const COLLISION_LAYER_TERMINAL: int = 16

var repo: GameRepository
var engine: CombatEngine

var hinge_pivot: Node3D
var screen_mesh: MeshInstance3D
var screen_area: Area3D
var canvas_ctrl: _TerminalCanvas

var vp_size: Vector2 = Vector2(1280.0, 680.0)
var world_size: Vector2 = Vector2(0.786, 0.418)

var is_deployed: bool = false
var external_title_menu_enabled: bool = true
var hovered_hotspot_index: int = -1
var current_pitch_deg: float = 95.0

var screen_mode: String = ""
var shift_options_data: Array = []
var reward_choices_data: Array = []
var route_choices_data: Array = []
var run_end_victory: bool = false
var run_end_summary: String = ""
var workshop_removing_card: bool = false
var reward_upgrade_selecting: bool = false
var title_selecting_chassis: bool = false
var guided_tour_requested: bool = false
var first_boot_tutorial_recommended: bool = false
var selected_overdrive_level: int = 0
var chassis_stats: Dictionary = {}
var page_offset: int = 0
var pause_audio_label: String = "100%"
var pause_engine_audio_label: String = "100%"
var pause_sfx_audio_label: String = "100%"
var pause_quality_label: String = "HIGH"
var pause_fullscreen_active: bool = false

var hotspots: Array[Dictionary] = []

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine

	var tcfg: Dictionary = repo.cockpit.get("terminal_3d", {}) as Dictionary
	position = JsonConfigLoader.to_vec3(tcfg.get("hinge_pos", []), Vector3(0.0, 1.46, -0.35))
	rotation_degrees.y = float(tcfg.get("hinge_yaw_deg", 0.0))

	current_pitch_deg = float(tcfg.get("folded_pitch_deg", 95.0))
	hinge_pivot = Node3D.new()
	hinge_pivot.rotation_degrees.x = current_pitch_deg
	add_child(hinge_pivot)

	var term_scene: PackedScene = repo.load_model_scene("drop_down_terminal")
	if term_scene != null:
		hinge_pivot.add_child(term_scene.instantiate())

	vp_size = JsonConfigLoader.to_vec2(tcfg.get("viewport_size", []), Vector2(1280.0, 680.0))
	world_size = JsonConfigLoader.to_vec2(tcfg.get("screen_size_m", []), Vector2(0.786, 0.418))
	var scr_off: Vector3 = JsonConfigLoader.to_vec3(tcfg.get("screen_offset", []), Vector3(0.0, -0.271, 0.026))

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		hinge_pivot,
		Vector2i(int(vp_size.x), int(vp_size.y)),
		world_size,
		scr_off,
		Vector3.ZERO,
		false,
		true
	)
	screen_mesh = scr["mesh"] as MeshInstance3D

	canvas_ctrl = _TerminalCanvas.new()
	canvas_ctrl.terminal = self
	canvas_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(scr["root"] as Control).add_child(canvas_ctrl)

	screen_area = Area3D.new()
	screen_area.collision_layer = COLLISION_LAYER_TERMINAL
	screen_area.collision_mask = 0
	screen_area.position = scr_off + Vector3(0.0, 0.0, 0.008)
	screen_area.set_meta("interact_type", "terminal_screen")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(world_size.x * 1.02, world_size.y * 1.02, 0.028)
	cs.shape = box
	screen_area.add_child(cs)
	hinge_pivot.add_child(screen_area)

	engine.shift_choice_requested.connect(_on_shift_choice_requested)
	engine.reward_cards_offered.connect(_on_reward_cards_offered)
	engine.route_choices_offered.connect(_on_route_choices_offered)
	engine.workshop_opened.connect(_on_workshop_opened)
	engine.run_ended.connect(_on_run_ended)
	engine.state_changed.connect(_on_engine_state_changed)

	if engine != null:
		_on_engine_state_changed()

func is_active() -> bool:
	return is_deployed

func world_pos_to_viewport(world_hit: Vector3) -> Vector2:
	if screen_mesh == null:
		return Vector2(-1.0, -1.0)
	var local: Vector3 = screen_mesh.to_local(world_hit)
	var u: float = (local.x / maxf(0.01, world_size.x)) + 0.5
	var v: float = 0.5 - (local.y / maxf(0.01, world_size.y))
	return Vector2(u * vp_size.x, v * vp_size.y)

func update_hover_world_pos(world_hit: Vector3) -> String:
	if not is_deployed or repo == null:
		return ""
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	var found: int = -1
	for i: int in range(hotspots.size()):
		var h: Dictionary = hotspots[i]
		if (h.get("rect", Rect2()) as Rect2).has_point(pt):
			found = i
			break
	set_hovered_row(found)
	if found >= 0:
		return str(hotspots[found].get("hint", ""))
	return repo.get_ui_text("hud", "hover_terminal_default")

func click_world_pos(world_hit: Vector3) -> bool:
	if not is_deployed:
		return false
	update_hover_world_pos(world_hit)
	if hovered_hotspot_index >= 0:
		activate_row(hovered_hotspot_index)
		return true
	if screen_mode == "deck_preview":
		close_deck_preview()
		return true
	if screen_mode == "reward" and reward_upgrade_selecting:
		reward_upgrade_selecting = false
		_rebuild_hotspots()
		return true
	if screen_mode == "title" and title_selecting_chassis:
		title_selecting_chassis = false
		_rebuild_hotspots()
		return true
	if screen_mode == "site_card_pick" and engine != null:
		engine.cancel_site_deck_selection()
		return true
	return false

func toggle_deck_preview() -> void:
	if engine == null or engine.mode != CombatEngine.MODE_COMBAT:
		return
	if is_deployed and screen_mode == "deck_preview":
		close_deck_preview()
		return
	if is_deployed:
		return
	screen_mode = "deck_preview"
	page_offset = 0
	is_deployed = true
	engine.sfx_requested.emit("hydraulic_servo", 0.72)
	_rebuild_hotspots()

func close_deck_preview() -> void:
	if screen_mode != "deck_preview":
		return
	is_deployed = false
	screen_mode = ""
	page_offset = 0
	hotspots.clear()
	hovered_hotspot_index = -1
	if engine != null:
		engine.sfx_requested.emit("switch_click", 0.65)
	if canvas_ctrl != null:
		DiegeticScreenFactory.request_redraw(canvas_ctrl)

func toggle_pause_menu() -> void:
	if engine == null or engine.mode == CombatEngine.MODE_TITLE or engine.mode == CombatEngine.MODE_GAME_OVER or engine.mode == CombatEngine.MODE_VICTORY:
		return
	if is_deployed and screen_mode == "pause_menu":
		close_pause_menu()
		return
	screen_mode = "pause_menu"
	is_deployed = true
	engine.sfx_requested.emit("hydraulic_servo", 0.72)
	_rebuild_hotspots()

func close_pause_menu() -> void:
	if screen_mode != "pause_menu":
		return
	screen_mode = ""
	if engine != null:
		engine.sfx_requested.emit("switch_click", 0.65)
		_on_engine_state_changed()
	if canvas_ctrl != null:
		DiegeticScreenFactory.request_redraw(canvas_ctrl)

func step_page(dir: int) -> bool:
	if not is_deployed or dir == 0:
		return false
	for h: Dictionary in hotspots:
		if str(h.get("page_nav", "")) == ("prev" if dir < 0 else "next") and bool(h.get("enabled", false)):
			var act: Callable = h.get("action", Callable()) as Callable
			if act.is_valid():
				act.call()
				return true
	return false

func set_hovered_row(index: int) -> void:
	if hovered_hotspot_index == index:
		return
	hovered_hotspot_index = index
	if index >= 0 and index < hotspots.size():
		var cid_p: String = str(hotspots[index].get("chassis_id", ""))
		if not cid_p.is_empty():
			chassis_preview_hovered.emit(cid_p)
	if canvas_ctrl != null:
		DiegeticScreenFactory.request_redraw(canvas_ctrl)

func activate_row(index: int) -> void:
	if not is_deployed or index < 0 or index >= hotspots.size():
		return
	var h: Dictionary = hotspots[index]
	if not bool(h.get("enabled", false)):
		engine.sfx_requested.emit("blocked", 0.5)
		return
	var action: Callable = h.get("action", Callable()) as Callable
	if action.is_valid():
		action.call()

func _rebuild_hotspots() -> void:
	hotspots.clear()
	hovered_hotspot_index = -1
	if canvas_ctrl != null:
		canvas_ctrl.build_layout_and_hotspots()
		DiegeticScreenFactory.request_redraw(canvas_ctrl)

func _on_engine_state_changed() -> void:
	if is_deployed and screen_mode == "pause_menu" and engine.mode != CombatEngine.MODE_TITLE and engine.mode != CombatEngine.MODE_GAME_OVER and engine.mode != CombatEngine.MODE_VICTORY:
		_rebuild_hotspots()
		return
	if engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ENEMY_TURN:
		if screen_mode == "deck_preview" and is_deployed:
			_rebuild_hotspots()
		else:
			is_deployed = false
			screen_mode = ""
			workshop_removing_card = false
			reward_upgrade_selecting = false
			hotspots.clear()
	elif engine.mode == CombatEngine.MODE_SHIFT_CHOICE:
		is_deployed = true
		screen_mode = "shift_choice"
		_rebuild_hotspots()
	elif engine.mode == CombatEngine.MODE_WORKSHOP:
		is_deployed = true
		screen_mode = "workshop"
		_rebuild_hotspots()
	elif engine.mode == CombatEngine.MODE_REWARD:
		is_deployed = true
		screen_mode = "reward"
		_rebuild_hotspots()
	elif engine.mode == CombatEngine.MODE_ROUTE_CHOICE or engine.mode == CombatEngine.MODE_ROUTE_TRANSITION:
		is_deployed = false
		screen_mode = ""
		hotspots.clear()
		hovered_hotspot_index = -1
	elif engine.is_site_mode():
		if not engine.site_selecting_deck_action.is_empty():
			if screen_mode != "site_card_pick":
				page_offset = 0
			is_deployed = true
			screen_mode = "site_card_pick"
			_rebuild_hotspots()
		else:
			is_deployed = false
			screen_mode = ""
			page_offset = 0
			hotspots.clear()
			hovered_hotspot_index = -1
	elif engine.mode == CombatEngine.MODE_TITLE:
		is_deployed = not external_title_menu_enabled
		screen_mode = "title"
		workshop_removing_card = false
		reward_upgrade_selecting = false
		title_selecting_chassis = false
		_rebuild_hotspots()

func _on_shift_choice_requested(_hand_index: int, options: Array) -> void:
	shift_options_data = options.duplicate()
	screen_mode = "shift_choice"
	is_deployed = true
	_rebuild_hotspots()

func _on_reward_cards_offered(choices: Array) -> void:
	reward_choices_data = choices.duplicate()
	reward_upgrade_selecting = false
	page_offset = 0
	screen_mode = "reward"
	is_deployed = true
	_rebuild_hotspots()

func _on_route_choices_offered(options: Array) -> void:
	route_choices_data = options.duplicate()
	screen_mode = ""
	is_deployed = false
	hotspots.clear()
	hovered_hotspot_index = -1

func _on_workshop_opened() -> void:
	workshop_removing_card = false
	page_offset = 0
	screen_mode = "workshop"
	is_deployed = true
	_rebuild_hotspots()

func _on_run_ended(victory: bool, summary: String) -> void:
	run_end_victory = victory
	run_end_summary = summary
	screen_mode = "run_end"
	is_deployed = true
	_rebuild_hotspots()

func _process(delta: float) -> void:
	if repo == null or hinge_pivot == null:
		return
	var tcfg: Dictionary = repo.cockpit.get("terminal_3d", {}) as Dictionary
	var folded_deg: float = float(tcfg.get("folded_pitch_deg", 95.0))
	var target_pitch: float = float(tcfg.get("deployed_pitch_deg", -10.5)) if is_deployed else folded_deg
	var spd: float = float(tcfg.get("deploy_speed", 9.5))
	current_pitch_deg = lerpf(current_pitch_deg, target_pitch, clampf(delta * spd, 0.0, 1.0))
	hinge_pivot.rotation_degrees.x = current_pitch_deg
	var vis_now: bool = is_deployed or absf(current_pitch_deg - folded_deg) > 2.5
	if hinge_pivot.visible != vis_now:
		hinge_pivot.visible = vis_now
		DiegeticScreenFactory.set_screen_enabled(canvas_ctrl, vis_now)


class _TerminalCanvas extends Control:
	var terminal: DiegeticTerminal3D

	func build_layout_and_hotspots() -> void:
		if terminal == null or terminal.repo == null or terminal.engine == null:
			return
		var sz: Vector2 = terminal.vp_size
		var eng: CombatEngine = terminal.engine
		var rep: GameRepository = terminal.repo

		match terminal.screen_mode:
			"reward":
				var has_elite_banner: bool = not eng.last_elite_relic_reward.is_empty()
				var count: int = mini(3, terminal.reward_choices_data.size())
				var card_w: float = 344.0
				var card_h: float = 486.0 if has_elite_banner else 510.0
				var gap_x: float = 38.0
				var total_w: float = float(count) * card_w + float(maxi(0, count - 1)) * gap_x
				var start_x: float = (sz.x - total_w) * 0.5
				var card_y: float = 144.0 if has_elite_banner else 120.0

				var bonus_upg: int = 1 if eng.reward_cards_pre_upgraded else 0
				for i: int in range(count):
					var cid: String = str(terminal.reward_choices_data[i])
					var cdata: Dictionary = rep.get_card(cid)
					var crect: Rect2 = Rect2(start_x + float(i) * (card_w + gap_x), card_y, card_w, card_h)
					terminal.hotspots.append({
						"rect": crect,
						"kind": "reward_card",
						"card_id": cid,
						"shortcut": str(i + 1),
						"enabled": true,
						"hint": "%s [%d]: %s — %s" % [rep.get_ui_text("terminal", "reward_install_hover"), i + 1, str(cdata.get("name", cid)), CardEffectFormatter.format_inline_summary(rep, eng, cdata, bonus_upg)],
						"action": func() -> void:
							terminal.is_deployed = false
							terminal.reward_upgrade_selecting = false
							terminal.reward_card_chosen.emit(cid)
					})

			"title":
				var screen_half: float = sz.x * 0.5
				var pod_w_t: float = 580.0
				if terminal.title_selecting_chassis:
					var presets: Array = rep.gameplay().get("chassis_presets", []) as Array
					for ci: int in range(presets.size()):
						var pr: Dictionary = presets[ci] as Dictionary
						var pid: String = str(pr.get("id", "interceptor"))
						var pname: String = str(pr.get("name", pid))
						var psub: String = str(pr.get("subtitle", ""))
						var pdesc: String = str(pr.get("description", ""))
						var st: Dictionary = terminal.chassis_stats.get(pid, {}) as Dictionary
						var runs_c: int = int(st.get("runs", 0))
						var wins_c: int = int(st.get("wins", 0))
						var best_od: int = int(st.get("best_od", 0))
						var rec_str: String = ("WINS %d/%d (BEST OD%d)" % [wins_c, runs_c, best_od]) if wins_c > 0 else (("RUNS %d • 0 WINS" % runs_c) if runs_c > 0 else "UNDRIVEN")
						var py: float = 190.0 + float(ci) * 92.0
						var pcol: Color = rep.get_palette_color("playable_glow") if ci == 0 else (rep.get_palette_color("kw_shield") if ci == 1 else rep.get_palette_color("selected_glow"))
						terminal.hotspots.append({
							"rect": Rect2(screen_half - 440.0, py, 880.0, 82.0),
							"kind": "medallion_action",
							"icon": "chassis_" + pid,
							"chassis_id": pid,
							"title": "%s   [%s]" % [pname, rec_str],
							"subtitle": "%s  •  %s" % [psub, pdesc] if not pdesc.is_empty() else psub,
							"shortcut": str(ci + 1),
							"color": pcol,
							"enabled": true,
							"hint": "[%d] %s (%s) — %s" % [ci + 1, pname, rec_str, pdesc],
							"action": func() -> void:
								var tour_sfx: String = ":tour" if terminal.guided_tour_requested else ""
								terminal.guided_tour_requested = false
								terminal.title_selecting_chassis = false
								terminal.is_deployed = false
								terminal.title_action_pressed.emit("run:%s:%d%s" % [pid, terminal.selected_overdrive_level, tour_sfx])
						})
					var od: int = terminal.selected_overdrive_level
					var od_lbl: String = rep.get_ui_text("terminal", "btn_overdrive_std") if od <= 0 else (rep.get_ui_text("terminal", "btn_overdrive_lvl_fmt") % od)
					var od_title: String = rep.get_ui_text("terminal", "btn_overdrive_fmt") % od_lbl
					var od_sub: String = _describe_overdrive_modifiers(od)
					var od_col: Color = rep.get_palette_color("playable_glow") if od == 0 else (rep.get_palette_color("selected_glow") if od <= 2 else rep.get_palette_color("redline_glow"))
					terminal.hotspots.append({
						"rect": Rect2(screen_half - 440.0, 470.0, 880.0, 74.0),
						"kind": "medallion_action",
						"icon": "reroll",
						"title": od_title,
						"subtitle": od_sub,
						"shortcut": "4",
						"color": od_col,
						"enabled": true,
						"hint": "[4] %s — %s" % [od_title, od_sub],
						"action": func() -> void:
							terminal.selected_overdrive_level = (terminal.selected_overdrive_level + 1) % 6
							eng.sfx_requested.emit("switch_click", 0.75)
							terminal._rebuild_hotspots()
					})
					terminal.hotspots.append({
						"rect": Rect2(screen_half - 210.0, 558.0, 420.0, 68.0),
						"kind": "medallion_action",
						"icon": "cancel",
						"title": rep.get_ui_text("terminal", "btn_back"),
						"subtitle": rep.get_ui_text("terminal", "btn_back_sub"),
						"shortcut": "ESC",
						"color": rep.get_palette_color("redline_glow"),
						"enabled": true,
						"hint": rep.get_ui_text("terminal", "btn_back_sub"),
						"action": func() -> void:
							terminal.guided_tour_requested = false
							terminal.title_selecting_chassis = false
							terminal._rebuild_hotspots()
					})
				else:
					var first_boot: bool = terminal.first_boot_tutorial_recommended
					var saved_info: Dictionary = eng.peek_saved_run_info()
					var has_save: bool = not saved_info.is_empty()
					var entries: Array[Dictionary] = []
					if has_save:
						var s_cid: String = str(saved_info.get("selected_chassis_id", "interceptor"))
						var s_name: String = str(eng.get_chassis_preset(s_cid).get("name", s_cid)).to_upper()
						var s_stg: int = int(saved_info.get("stage_index", 0)) + 1
						var s_hp: int = int(saved_info.get("hp", 1))
						var s_max: int = int(saved_info.get("max_hp", 70))
						var s_od: int = int(saved_info.get("overdrive_level", 0))
						var od_tag: String = ("  •  OD %d" % s_od) if s_od > 0 else ""
						var cont_sub: String = rep.get_ui_text("terminal", "btn_continue_run_sub_fmt") % [s_name, s_stg, s_hp, s_max, od_tag]
						entries.append({
							"icon": "chassis_" + s_cid,
							"chassis_id": s_cid,
							"title": rep.get_ui_text("terminal", "btn_continue_run"),
							"subtitle": cont_sub,
							"color": rep.get_palette_color("playable_glow"),
							"hint": cont_sub,
							"w": pod_w_t,
							"action": func() -> void:
								terminal.is_deployed = false
								terminal.title_action_pressed.emit("continue")
						})
					var tut_title: String = rep.get_ui_text("terminal", "btn_tutorial_rec" if first_boot else "btn_tutorial")
					var tut_sub: String = rep.get_ui_text("terminal", "btn_tutorial_rec_sub" if first_boot else "btn_tutorial_sub")
					var run_item: Dictionary = {
						"icon": "launch",
						"title": rep.get_ui_text("terminal", "btn_start_run"),
						"subtitle": rep.get_ui_text("terminal", "btn_start_run_sub"),
						"color": rep.get_palette_color("selected_glow" if (first_boot or has_save) else "playable_glow"),
						"hint": rep.get_ui_text("terminal", "btn_start_run_sub"),
						"w": pod_w_t,
						"action": func() -> void:
							terminal.guided_tour_requested = false
							terminal.title_selecting_chassis = true
							terminal._rebuild_hotspots()
					}
					var tut_item: Dictionary = {
						"icon": "chassis",
						"title": tut_title,
						"subtitle": tut_sub,
						"color": rep.get_palette_color("playable_glow" if first_boot else "kw_draw"),
						"hint": tut_sub,
						"w": pod_w_t,
						"action": func() -> void:
							terminal.guided_tour_requested = true
							terminal.title_selecting_chassis = true
							terminal._rebuild_hotspots()
					}
					if first_boot:
						entries.append(tut_item)
						entries.append(run_item)
					else:
						entries.append(run_item)
						entries.append(tut_item)
					var row_h_t: float = 76.0 if entries.size() >= 4 else 92.0
					var gap_t: float = 10.0 if entries.size() >= 4 else 14.0
					var cur_ty: float = 296.0 if entries.size() >= 4 else 304.0
					for ei: int in range(entries.size()):
						var ed: Dictionary = entries[ei]
						var ew: float = float(ed.get("w", pod_w_t))
						var h_dict: Dictionary = {
							"rect": Rect2(screen_half - ew * 0.5, cur_ty, ew, row_h_t),
							"kind": "medallion_action",
							"icon": str(ed["icon"]),
							"title": str(ed["title"]),
							"subtitle": str(ed["subtitle"]),
							"shortcut": str(ei + 1),
							"color": ed["color"] as Color,
							"enabled": true,
							"hint": str(ed["hint"]),
							"action": ed["action"]
						}
						if ed.has("chassis_id"):
							h_dict["chassis_id"] = str(ed["chassis_id"])
						terminal.hotspots.append(h_dict)
						cur_ty += row_h_t + gap_t

			"route_choice":
				var r_opts: Array = terminal.route_choices_data
				var rn: int = maxi(1, r_opts.size())
				var rw: float = 540.0
				var rh: float = 430.0
				var rgap: float = 44.0
				var rtot: float = float(rn) * rw + float(rn - 1) * rgap
				var rsx: float = (sz.x - rtot) * 0.5
				var rsy: float = 132.0
				for ri: int in range(r_opts.size()):
					var ropt: Dictionary = r_opts[ri] as Dictionary
					var rtitle: String = str(ropt.get("title", rep.get_ui_text("fork", "fallback_lane_title")))
					var b_sc: int = int(ropt.get("bonus_scrap", 0))
					var b_hl: int = int(ropt.get("bonus_heal", 0))
					var bonus_txt: String = (rep.get_ui_text("fork", "bonus_scrap_fmt") % b_sc) if b_sc > 0 else ((rep.get_ui_text("fork", "bonus_heal_fmt") % b_hl) if b_hl > 0 else rep.get_ui_text("fork", "bonus_standard"))
					var e_names: PackedStringArray = PackedStringArray()
					for sp: Variant in (ropt.get("enemies", []) as Array):
						if typeof(sp) == TYPE_DICTIONARY:
							var eid: String = str((sp as Dictionary).get("enemy_id", ""))
							var etmpl: Dictionary = rep.get_enemy(eid)
							e_names.append(str(etmpl.get("name", eid)))
					var r_idx: int = ri
					terminal.hotspots.append({
						"rect": Rect2(rsx + float(ri) * (rw + rgap), rsy, rw, rh),
						"kind": "route_pod",
						"title": rtitle,
						"enemies_text": " • ".join(e_names),
						"bonus_text": bonus_txt,
						"is_elite": bool(ropt.get("is_elite", false)),
						"shortcut": str(ri + 1),
						"enabled": true,
						"hint": "[%d] %s (%s) — %s" % [ri + 1, rtitle, bonus_txt, ", ".join(e_names)],
						"action": func() -> void:
							terminal.is_deployed = false
							eng.select_route_option(r_idx)
					})

			"workshop":
				if terminal.workshop_removing_card:
					_build_workshop_remove_hotspots(sz, rep, eng)
				else:
					_build_workshop_main_hotspots(sz, rep, eng)

			"shift_choice":
				var opts: Array = terminal.shift_options_data
				var n: int = maxi(1, opts.size())
				var dial_w: float = 250.0
				var dial_h: float = 360.0
				var gap: float = 28.0
				var tot_w: float = float(n) * dial_w + float(n - 1) * gap
				var sx: float = (sz.x - tot_w) * 0.5
				var sy: float = 165.0

				for i: int in range(opts.size()):
					var delta_g: int = int(opts[i])
					var target_g: int = eng.transmission.clamp_gear(eng.current_gear + delta_g, eng.gear_lock_max, eng.gear_lock_min)
					var gd: Dictionary = rep.get_gear(target_g)
					var drect: Rect2 = Rect2(sx + float(i) * (dial_w + gap), sy, dial_w, dial_h)
					terminal.hotspots.append({
						"rect": drect,
						"kind": "shift_dial",
						"delta_g": delta_g,
						"target_g": target_g,
						"shortcut": str(i + 1),
						"enabled": true,
						"hint": "[%d] %s (%s) — %s" % [i + 1, str(gd.get("short_name", "")), str(gd.get("role", "")), str(gd.get("description", ""))],
						"action": func() -> void:
							terminal.is_deployed = false
							terminal.shift_option_selected.emit(delta_g)
					})

			"run_end":
				var btn_rect: Rect2 = Rect2((sz.x - 480.0) * 0.5, 520.0, 480.0, 96.0)
				terminal.hotspots.append({
					"rect": btn_rect,
					"kind": "medallion_action",
					"icon": "launch",
					"title": rep.get_ui_text("hud", "restart_button"),
					"subtitle": rep.get_ui_text("terminal", "run_end_restart_sub"),
					"shortcut": "1",
					"color": rep.get_palette_color("playable_glow"),
					"enabled": true,
					"hint": rep.get_ui_text("terminal", "run_end_restart_sub"),
					"action": func() -> void:
						terminal.is_deployed = false
						terminal.restart_requested.emit()
				})

			"deck_preview":
				var unique_cnt: int = _unique_draw_pile_ids(eng).size()
				_clamp_page_offset(unique_cnt, 6)
				var close_rect: Rect2 = Rect2((sz.x - 440.0) * 0.5, 570.0, 440.0, 78.0)
				terminal.hotspots.append({
					"rect": close_rect,
					"kind": "medallion_action",
					"icon": "cancel",
					"title": rep.get_ui_text("terminal", "deck_fold_title"),
					"subtitle": rep.get_ui_text("terminal", "deck_fold_sub"),
					"shortcut": "ESC",
					"color": rep.get_palette_color("selected_glow"),
					"enabled": true,
					"hint": rep.get_ui_text("terminal", "deck_fold_sub"),
					"action": func() -> void:
						terminal.close_deck_preview()
				})
				_append_pagination_hotspots(sz, rep, unique_cnt, 6, 570.0)

			"site_card_pick":
				_build_site_card_pick_hotspots(sz, rep, eng)

			"pause_menu":
				var col_w: float = 560.0
				var btn_x: float = (sz.x - col_w) * 0.5
				var btn_h: float = 98.0
				var gap_y: float = 20.0
				var start_y: float = 148.0
				terminal.hotspots.append({
					"rect": Rect2(btn_x, start_y, col_w, btn_h),
					"kind": "medallion_action",
					"icon": "launch",
					"title": rep.get_ui_text("terminal", "pause_resume_title"),
					"subtitle": rep.get_ui_text("terminal", "pause_resume_sub"),
					"shortcut": "1",
					"color": rep.get_palette_color("playable_glow"),
					"enabled": true,
					"hint": rep.get_ui_text("terminal", "pause_resume_sub"),
					"action": func() -> void:
						terminal.close_pause_menu()
				})
				terminal.hotspots.append({
					"rect": Rect2(btn_x, start_y + (btn_h + gap_y), col_w, btn_h),
					"kind": "medallion_action",
					"icon": "reroll",
					"title": rep.get_ui_text("terminal", "pause_restart_title"),
					"subtitle": rep.get_ui_text("terminal", "pause_restart_sub"),
					"shortcut": "2",
					"color": rep.get_palette_color("kw_ram"),
					"enabled": true,
					"hint": rep.get_ui_text("terminal", "pause_restart_sub"),
					"action": func() -> void:
						terminal.screen_mode = ""
						terminal.is_deployed = false
						terminal.pause_action_pressed.emit("restart_run")
				})
				var aud_title: String = rep.get_ui_text("terminal", "pause_audio_title_fmt") % terminal.pause_audio_label
				terminal.hotspots.append({
					"rect": Rect2(btn_x, start_y + 2.0 * (btn_h + gap_y), col_w, btn_h),
					"kind": "medallion_action",
					"icon": "scrap",
					"title": aud_title,
					"subtitle": rep.get_ui_text("terminal", "pause_audio_sub"),
					"shortcut": "3",
					"color": rep.get_palette_color("selected_glow"),
					"enabled": true,
					"hint": "%s — %s" % [aud_title, rep.get_ui_text("terminal", "pause_audio_sub")],
					"action": func() -> void:
						terminal.pause_action_pressed.emit("cycle_audio")
				})
				terminal.hotspots.append({
					"rect": Rect2(btn_x, start_y + 3.0 * (btn_h + gap_y), col_w, btn_h),
					"kind": "medallion_action",
					"icon": "cancel",
					"title": rep.get_ui_text("terminal", "pause_hangar_title"),
					"subtitle": rep.get_ui_text("terminal", "pause_hangar_sub"),
					"shortcut": "4",
					"color": rep.get_palette_color("redline_glow"),
					"enabled": true,
					"hint": rep.get_ui_text("terminal", "pause_hangar_sub"),
					"action": func() -> void:
						terminal.screen_mode = ""
						terminal.is_deployed = false
						terminal.pause_action_pressed.emit("hangar")
				})

	func _build_workshop_main_hotspots(sz: Vector2, rep: GameRepository, eng: CombatEngine) -> void:
		var card_w: float = 232.0
		var card_h: float = 368.0
		var gap_x: float = 14.0
		var left_x: float = 26.0
		var card_y: float = 114.0

		for i: int in range(eng.workshop_card_offers.size()):
			var offer: Dictionary = eng.workshop_card_offers[i]
			var cid: String = str(offer.get("card_id", ""))
			var cost: int = int(offer.get("cost", 34))
			var sold: bool = bool(offer.get("sold", false))
			var sale: bool = bool(offer.get("on_sale", false))
			var can_buy: bool = (not sold) and eng.scrap >= cost and not cid.is_empty()
			var cdata: Dictionary = rep.get_card(cid)
			var crect: Rect2 = Rect2(left_x + float(i) * (card_w + gap_x), card_y, card_w, card_h)
			var idx_cap: int = i
			terminal.hotspots.append({
				"rect": crect,
				"kind": "shop_card",
				"card_id": cid,
				"cost": cost,
				"on_sale": sale,
				"sold": sold,
				"shortcut": str(i + 1),
				"enabled": can_buy,
				"hint": "[%d] %s (%d %s) — %s" % [i + 1, str(cdata.get("name", cid)), cost, rep.get_ui_text("terminal", "stat_scrap"), CardEffectFormatter.format_inline_summary(rep, eng, cdata)],
				"action": func() -> void:
					eng.workshop_buy_card_at(idx_cap)
			})

		var right_x: float = 762.0
		var right_w: float = sz.x - right_x - 26.0
		var rel_w: float = (right_w - 14.0) * 0.5
		var rel_h: float = 172.0

		for ri: int in range(eng.workshop_relic_offers.size()):
			var roffer: Dictionary = eng.workshop_relic_offers[ri]
			var rid: String = str(roffer.get("relic_id", ""))
			var rcost: int = int(roffer.get("cost", 42))
			var rsold: bool = bool(roffer.get("sold", false))
			var rdata: Dictionary = rep.get_relic(rid)
			var can_r: bool = (not rsold) and eng.scrap >= rcost and not rid.is_empty()
			var rrect: Rect2 = Rect2(right_x + float(ri) * (rel_w + 14.0), card_y, rel_w, rel_h)
			var r_cap: int = ri
			terminal.hotspots.append({
				"rect": rrect,
				"kind": "shop_relic",
				"relic_id": rid,
				"cost": rcost,
				"sold": rsold,
				"shortcut": str(4 + ri),
				"enabled": can_r,
				"hint": "[%d] %s (%d %s) — %s" % [4 + ri, str(rdata.get("name", rid)), rcost, rep.get_ui_text("terminal", "stat_scrap"), str(rdata.get("description", ""))],
				"action": func() -> void:
					eng.workshop_buy_relic_at(r_cap)
			})

		var srv_y: float = card_y + rel_h + 14.0
		var srv_w: float = (right_w - 14.0) * 0.5
		var srv_h: float = 85.0
		var wcfg: Dictionary = rep.workshop()

		var rep_cost: int = int(wcfg.get("repair_cost", 20))
		var rep_amt: int = int(wcfg.get("repair_amount", 25))
		var rep_sub: String = rep.get_ui_text("terminal", "ws_repair_sub_fmt") % [rep_amt, rep_cost]
		terminal.hotspots.append({
			"rect": Rect2(right_x, srv_y, srv_w, srv_h),
			"kind": "medallion_action",
			"icon": "repair",
			"title": rep.get_ui_text("terminal", "ws_repair_title"),
			"subtitle": rep_sub,
			"shortcut": "6",
			"color": rep.get_palette_color("playable_glow"),
			"enabled": eng.scrap >= rep_cost and eng.hp < eng.max_hp,
			"hint": "[6] %s — %s" % [rep.get_ui_text("terminal", "ws_repair_title"), rep_sub],
			"action": func() -> void: terminal.workshop_action_pressed.emit("repair")
		})

		var tune_cost: int = int(wcfg.get("tune_cost", 30))
		var tune_hp: int = int(wcfg.get("tune_max_hp_bonus", 12))
		var tune_sub: String = rep.get_ui_text("terminal", "ws_reinforce_sub_fmt") % [tune_hp, tune_cost]
		terminal.hotspots.append({
			"rect": Rect2(right_x + srv_w + 14.0, srv_y, srv_w, srv_h),
			"kind": "medallion_action",
			"icon": "chassis",
			"title": rep.get_ui_text("terminal", "ws_reinforce_title"),
			"subtitle": tune_sub,
			"shortcut": "7",
			"color": rep.get_palette_color("kw_shield"),
			"enabled": eng.scrap >= tune_cost,
			"hint": "[7] %s — %s" % [rep.get_ui_text("terminal", "ws_reinforce_title"), tune_sub],
			"action": func() -> void: terminal.workshop_action_pressed.emit("reinforce")
		})

		var rem_cost: int = eng.workshop_current_remove_cost()
		var can_rem: bool = eng.scrap >= rem_cost and eng.master_deck.size() > 4
		var rem_sub: String = rep.get_ui_text("terminal", "ws_dismantle_sub_fmt") % rem_cost
		terminal.hotspots.append({
			"rect": Rect2(right_x, srv_y + srv_h + 12.0, srv_w, srv_h),
			"kind": "medallion_action",
			"icon": "scrap_card",
			"title": rep.get_ui_text("terminal", "ws_dismantle_title"),
			"subtitle": rem_sub,
			"shortcut": "8",
			"color": rep.get_palette_color("kw_ram"),
			"enabled": can_rem,
			"hint": "[8] %s — %s" % [rep.get_ui_text("terminal", "ws_dismantle_title"), rem_sub],
			"action": func() -> void:
				terminal.workshop_removing_card = true
				terminal.page_offset = 0
				terminal._rebuild_hotspots()
		})

		var reroll_cost: int = eng.workshop_current_reroll_cost()
		var rr_sub: String = rep.get_ui_text("terminal", "ws_restock_sub_fmt") % reroll_cost
		terminal.hotspots.append({
			"rect": Rect2(right_x + srv_w + 14.0, srv_y + srv_h + 12.0, srv_w, srv_h),
			"kind": "medallion_action",
			"icon": "reroll",
			"title": rep.get_ui_text("terminal", "ws_restock_title"),
			"subtitle": rr_sub,
			"shortcut": "9",
			"color": rep.get_palette_color("selected_glow"),
			"enabled": eng.scrap >= reroll_cost,
			"hint": "[9] %s — %s" % [rep.get_ui_text("terminal", "ws_restock_title"), rr_sub],
			"action": func() -> void:
				eng.workshop_reroll_offers()
		})

		var launch_rect: Rect2 = Rect2(left_x, 566.0, sz.x - left_x * 2.0, 84.0)
		terminal.hotspots.append({
			"rect": launch_rect,
			"kind": "medallion_action",
			"icon": "launch",
			"title": rep.get_ui_text("hud", "continue_run"),
			"subtitle": rep.get_ui_text("terminal", "ws_leave_sub"),
			"shortcut": "SPACE",
			"color": rep.get_palette_color("playable_glow"),
			"enabled": true,
			"hint": rep.get_ui_text("terminal", "ws_leave_sub"),
			"action": func() -> void:
				terminal.is_deployed = false
				terminal.workshop_action_pressed.emit("leave")
		})

	static func _describe_overdrive_modifiers(od: int) -> String:
		match od:
			0: return "Baseline Megadungeon calibration — click to cycle Overdrive 1-5"
			1: return "OD 1: Hostile vehicles gain +8% Hull HP"
			2: return "OD 2: Hostile vehicles +16% HP & +1 Attack Strength"
			3: return "OD 3: +24% Enemy HP, +1 STR • Max Heat -1 & Overheat +3 DMG"
			4: return "OD 4: +32% Enemy HP, +1 STR, Tight Heat • Stall deals 4 HP & -2 Draw"
			_: return "OD 5 (MAX): +40% Enemy HP, +2 STR, Tight Heat & Lethal Stall"

	static func _unique_draw_pile_ids(eng: CombatEngine) -> Array:
		var counts: Dictionary = {}
		for cid: String in eng.draw_pile:
			counts[cid] = true
		var unique_ids: Array = counts.keys()
		unique_ids.sort()
		return unique_ids

	func _clamp_page_offset(total_items: int, per_page: int = 6) -> int:
		var max_off: int = maxi(0, ((maxi(1, total_items) - 1) / per_page) * per_page)
		terminal.page_offset = clampi(terminal.page_offset, 0, max_off)
		return terminal.page_offset

	func _append_pagination_hotspots(sz: Vector2, rep: GameRepository, total_items: int, per_page: int = 6, btn_y: float = 570.0) -> void:
		if total_items <= per_page:
			return
		var total_pages: int = maxi(1, int(ceil(float(total_items) / float(per_page))))
		var cur_page: int = (terminal.page_offset / per_page) + 1
		var sub_txt: String = rep.get_ui_text("terminal", "page_status_fmt") % [cur_page, total_pages]
		var can_prev: bool = terminal.page_offset > 0
		var can_next: bool = (terminal.page_offset + per_page) < total_items
		var nav_w: float = 228.0
		var prev_x: float = (sz.x - 440.0) * 0.5 - nav_w - 20.0
		var next_x: float = (sz.x + 440.0) * 0.5 + 20.0
		terminal.hotspots.append({
			"rect": Rect2(prev_x, btn_y, nav_w, 78.0),
			"kind": "medallion_action",
			"page_nav": "prev",
			"icon": "reroll",
			"title": rep.get_ui_text("terminal", "page_prev_title"),
			"subtitle": sub_txt,
			"shortcut": "<",
			"color": rep.get_palette_color("selected_glow"),
			"enabled": can_prev,
			"hint": "[<] %s (%s)" % [rep.get_ui_text("terminal", "page_prev_title"), sub_txt],
			"action": func() -> void:
				terminal.page_offset = maxi(0, terminal.page_offset - per_page)
				terminal.engine.sfx_requested.emit("switch_click", 0.65)
				terminal._rebuild_hotspots()
		})
		terminal.hotspots.append({
			"rect": Rect2(next_x, btn_y, nav_w, 78.0),
			"kind": "medallion_action",
			"page_nav": "next",
			"icon": "launch",
			"title": rep.get_ui_text("terminal", "page_next_title"),
			"subtitle": sub_txt,
			"shortcut": ">",
			"color": rep.get_palette_color("selected_glow"),
			"enabled": can_next,
			"hint": "[>] %s (%s)" % [rep.get_ui_text("terminal", "page_next_title"), sub_txt],
			"action": func() -> void:
				terminal.page_offset += per_page
				terminal.engine.sfx_requested.emit("switch_click", 0.65)
				terminal._rebuild_hotspots()
		})

	func _build_workshop_remove_hotspots(sz: Vector2, rep: GameRepository, eng: CombatEngine) -> void:
		var total_deck: int = eng.master_deck.size()
		var off: int = _clamp_page_offset(total_deck, 6)
		var max_shown: int = clampi(total_deck - off, 0, 6)
		var cw: float = 192.0
		var ch: float = 420.0
		var gx: float = 12.0
		var total_w: float = float(max_shown) * cw + float(maxi(0, max_shown - 1)) * gx
		var start_x: float = (sz.x - total_w) * 0.5
		var start_y: float = 108.0

		for i: int in range(max_shown):
			var deck_idx: int = off + i
			var cid: String = eng.master_deck[deck_idx]
			var cdata: Dictionary = rep.get_card(cid)
			var crect: Rect2 = Rect2(start_x + float(i) * (cw + gx), start_y, cw, ch)
			terminal.hotspots.append({
				"rect": crect,
				"kind": "deck_remove_tile",
				"card_id": cid,
				"shortcut": str(i + 1),
				"enabled": true,
				"hint": rep.get_ui_text("sites", "site_remove_hint_fmt") % [i + 1, str(cdata.get("name", cid))],
				"action": func() -> void:
					terminal.workshop_removing_card = false
					terminal.page_offset = 0
					eng.workshop_remove_deck_card(deck_idx)
			})

		var back_rect: Rect2 = Rect2((sz.x - 440.0) * 0.5, 570.0, 440.0, 78.0)
		terminal.hotspots.append({
			"rect": back_rect,
			"kind": "medallion_action",
			"icon": "cancel",
			"title": rep.get_ui_text("terminal", "ws_cancel_remove"),
			"subtitle": rep.get_ui_text("terminal", "ws_cancel_remove_sub"),
			"shortcut": "ESC",
			"color": rep.get_palette_color("redline_glow"),
			"enabled": true,
			"hint": rep.get_ui_text("terminal", "ws_cancel_remove_sub"),
			"action": func() -> void:
				terminal.workshop_removing_card = false
				terminal.page_offset = 0
				terminal._rebuild_hotspots()
		})
		_append_pagination_hotspots(sz, rep, total_deck, 6, 570.0)

	func _build_reward_upgrade_hotspots(sz: Vector2, rep: GameRepository, eng: CombatEngine) -> void:
		var upg_ids: Array[String] = eng.upgradeable_card_ids()
		var off: int = _clamp_page_offset(upg_ids.size(), 6)
		var max_shown: int = clampi(upg_ids.size() - off, 0, 6)
		var cw: float = 192.0
		var ch: float = 420.0
		var gx: float = 12.0
		var total_w: float = float(max_shown) * cw + float(maxi(0, max_shown - 1)) * gx
		var start_x: float = (sz.x - total_w) * 0.5
		var start_y: float = 108.0

		for i: int in range(max_shown):
			var cid: String = upg_ids[off + i]
			var cdata: Dictionary = rep.get_card(cid)
			var lvl: int = int(eng.upgrade_levels.get(cid, 0))
			var cnt: int = eng.master_deck.count(cid)
			var crect: Rect2 = Rect2(start_x + float(i) * (cw + gx), start_y, cw, ch)
			terminal.hotspots.append({
				"rect": crect,
				"kind": "deck_upgrade_tile",
				"card_id": cid,
				"upgrade_level": lvl,
				"copies": cnt,
				"shortcut": str(i + 1),
				"enabled": true,
				"hint": rep.get_ui_text("sites", "site_upgrade_hint_fmt") % [
					i + 1, str(cdata.get("name", cid)),
					int(rep.gameplay().get("card_upgrade_damage_bonus", 2)),
					int(rep.gameplay().get("card_upgrade_block_bonus", 3)) if int(cdata.get("block", 0)) > 0 else 0, lvl, cnt
				],
				"action": func() -> void:
					terminal.reward_upgrade_selecting = false
					terminal.page_offset = 0
					eng.upgrade_reward_card(cid)
			})

		var back_rect: Rect2 = Rect2((sz.x - 440.0) * 0.5, 570.0, 440.0, 78.0)
		terminal.hotspots.append({
			"rect": back_rect,
			"kind": "medallion_action",
			"icon": "cancel",
			"title": rep.get_ui_text("terminal", "rw_cancel_upgrade"),
			"subtitle": rep.get_ui_text("terminal", "rw_cancel_upgrade_sub"),
			"shortcut": "ESC",
			"color": rep.get_palette_color("redline_glow"),
			"enabled": true,
			"hint": rep.get_ui_text("terminal", "rw_cancel_upgrade_sub"),
			"action": func() -> void:
				terminal.reward_upgrade_selecting = false
				terminal.page_offset = 0
				terminal._rebuild_hotspots()
		})
		_append_pagination_hotspots(sz, rep, upg_ids.size(), 6, 570.0)

	func _build_site_card_pick_hotspots(sz: Vector2, rep: GameRepository, eng: CombatEngine) -> void:
		var cw: float = 192.0
		var ch: float = 420.0
		var gx: float = 12.0
		var start_y: float = 108.0
		var total_items: int = 0

		if eng.site_selecting_deck_action == "upgrade":
			var upg_ids: Array[String] = eng.upgradeable_card_ids()
			total_items = upg_ids.size()
			var off_u: int = _clamp_page_offset(total_items, 6)
			var max_shown: int = clampi(total_items - off_u, 0, 6)
			var total_w: float = float(max_shown) * cw + float(maxi(0, max_shown - 1)) * gx
			var start_x: float = (sz.x - total_w) * 0.5
			for i: int in range(max_shown):
				var cid: String = upg_ids[off_u + i]
				var cdata: Dictionary = rep.get_card(cid)
				var lvl: int = int(eng.upgrade_levels.get(cid, 0))
				var cnt: int = eng.master_deck.count(cid)
				var crect: Rect2 = Rect2(start_x + float(i) * (cw + gx), start_y, cw, ch)
				terminal.hotspots.append({
					"rect": crect,
					"kind": "deck_upgrade_tile",
					"card_id": cid,
					"upgrade_level": lvl,
					"copies": cnt,
					"shortcut": str(i + 1),
					"enabled": true,
					"hint": rep.get_ui_text("sites", "site_upgrade_hint_fmt") % [
						i + 1, str(cdata.get("name", cid)),
						int(rep.gameplay().get("card_upgrade_damage_bonus", 2)),
						int(rep.gameplay().get("card_upgrade_block_bonus", 3)) if int(cdata.get("block", 0)) > 0 else 0, lvl, cnt
					],
					"action": func() -> void:
						terminal.page_offset = 0
						eng.resolve_site_deck_upgrade(cid)
				})
		else:
			total_items = eng.master_deck.size()
			var off_r: int = _clamp_page_offset(total_items, 6)
			var max_rem: int = clampi(total_items - off_r, 0, 6)
			var total_w_r: float = float(max_rem) * cw + float(maxi(0, max_rem - 1)) * gx
			var start_x_r: float = (sz.x - total_w_r) * 0.5
			for i: int in range(max_rem):
				var deck_idx: int = off_r + i
				var cid_r: String = eng.master_deck[deck_idx]
				var cdata_r: Dictionary = rep.get_card(cid_r)
				var crect_r: Rect2 = Rect2(start_x_r + float(i) * (cw + gx), start_y, cw, ch)
				terminal.hotspots.append({
					"rect": crect_r,
					"kind": "deck_remove_tile",
					"card_id": cid_r,
					"shortcut": str(i + 1),
					"enabled": true,
					"hint": rep.get_ui_text("sites", "site_remove_hint_fmt") % [i + 1, str(cdata_r.get("name", cid_r))],
					"action": func() -> void:
						terminal.page_offset = 0
						eng.resolve_site_deck_remove(deck_idx)
				})

		var cancel_rect: Rect2 = Rect2((sz.x - 440.0) * 0.5, 570.0, 440.0, 78.0)
		terminal.hotspots.append({
			"rect": cancel_rect,
			"kind": "medallion_action",
			"icon": "cancel",
			"title": rep.get_ui_text("sites", "cancel_card_pick"),
			"subtitle": rep.get_ui_text("sites", "cancel_card_pick_sub"),
			"shortcut": "ESC",
			"color": rep.get_palette_color("redline_glow"),
			"enabled": true,
			"hint": rep.get_ui_text("sites", "cancel_card_pick_hint"),
			"action": func() -> void:
				terminal.page_offset = 0
				eng.cancel_site_deck_selection()
		})
		_append_pagination_hotspots(sz, rep, total_items, 6, 570.0)

	func _draw() -> void:
		if terminal == null or terminal.repo == null or terminal.engine == null:
			return
		var sz: Vector2 = size
		var rep: GameRepository = terminal.repo
		var eng: CombatEngine = terminal.engine
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var frame_col: Color = rep.get_palette_color("mfd_border")

		var outer_r: Rect2 = Rect2(4.0, 4.0, sz.x - 8.0, sz.y - 8.0)
		DiegeticScreenFactory.draw_industrial_plate(self, outer_r, rep, frame_col, 18.0, 3.2, true, 0.0, false)

		var g_col: Color = Color(frame_col.r, frame_col.g, frame_col.b, 0.06)
		for gx: int in range(1, 8):
			var x: float = sz.x * (float(gx) / 8.0)
			draw_line(Vector2(x, 16.0), Vector2(x, sz.y - 16.0), g_col, 1.0)
		for gy: int in range(1, 5):
			var y: float = sz.y * (float(gy) / 5.0)
			draw_line(Vector2(16.0, y), Vector2(sz.x - 16.0, y), g_col, 1.0)

		var hdr_r: Rect2 = Rect2(26.0, 14.0, sz.x - 52.0, 62.0)
		DiegeticScreenFactory.draw_industrial_plate(self, hdr_r, rep, frame_col, 10.0, 2.2, false, 62.0, true)

		var title_txt: String = ""
		match terminal.screen_mode:
			"reward":
				title_txt = rep.get_ui_text("hud", "reward_foundry_title" if terminal.reward_upgrade_selecting else "reward_title")
			"workshop":
				title_txt = rep.get_ui_text("hud", "workshop_remove_title" if terminal.workshop_removing_card else "workshop_title")
			"shift_choice":
				title_txt = rep.get_ui_text("hud", "shift_choice_title")
			"run_end":
				title_txt = rep.get_ui_text("hud", "victory_title" if terminal.run_end_victory else "defeat_title")
			"deck_preview":
				title_txt = rep.get_ui_text("hud", "deck_preview_title_fmt") % [eng.draw_pile.size(), eng.discard_pile.size()]
			"route_choice":
				title_txt = rep.get_ui_text("hud", "route_choice_title_fmt") % (eng.stage_index + 1)
			"site_card_pick":
				title_txt = rep.get_ui_text("hud", "site_card_upgrade_title" if eng.site_selecting_deck_action == "upgrade" else "site_card_remove_title")
			"pause_menu":
				title_txt = rep.get_ui_text("hud", "pause_menu_title")
			"title":
				title_txt = rep.get_ui_text("hud", "title_hangar_header" if terminal.title_selecting_chassis else "title_cold_header")

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(44.0, 54.0),
			title_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			sz.x - 455.0,
			25,
			rep.get_palette_color("mfd_accent"),
			out_col,
			3,
			15
		)

		_draw_header_stat_gauge(rep, Vector2(sz.x - 342.0, 45.0), rep.get_ui_text("terminal", "stat_hull"), "%d/%d" % [eng.hp, eng.max_hp], rep.get_palette_color("enemy_hp"))
		_draw_header_stat_gauge(rep, Vector2(sz.x - 214.0, 45.0), rep.get_ui_text("terminal", "stat_scrap"), str(eng.scrap), rep.get_palette_color("selected_glow"))
		_draw_header_stat_gauge(rep, Vector2(sz.x - 92.0, 45.0), rep.get_ui_text("terminal", "stat_deck"), str(eng.master_deck.size()), rep.get_palette_color("kw_shield"))

		if terminal.screen_mode == "reward" and not terminal.reward_upgrade_selecting and not eng.last_elite_relic_reward.is_empty():
			var er_col: Color = rep.get_palette_color("node_elite")
			var er_rect: Rect2 = Rect2(46.0, 82.0, sz.x - 92.0, 32.0)
			DiegeticScreenFactory.draw_chamfer_rect(self, er_rect, 7.0, Color(er_col.r * 0.22, er_col.g * 0.08, er_col.b * 0.06, 0.96), er_col, 2.0)
			var er_name: String = str(rep.get_relic(eng.last_elite_relic_reward).get("name", eng.last_elite_relic_reward)).to_upper()
			var er_txt: String = rep.get_ui_text("hud", "elite_relic_banner") % er_name
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(er_rect.position.x + 16.0, er_rect.position.y + 23.0), er_txt, HORIZONTAL_ALIGNMENT_CENTER, er_rect.size.x - 32.0, 17, rep.get_palette_color("selected_glow").lightened(0.2), out_col, 2, 12)

		if terminal.screen_mode == "workshop" and not terminal.workshop_removing_card:
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(28.0, 104.0), rep.get_ui_text("terminal", "workshop_cards_hdr"), HORIZONTAL_ALIGNMENT_LEFT, 700.0, 19, txt_col, out_col, 2, 13)
			DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(764.0, 104.0), rep.get_ui_text("terminal", "workshop_bay_hdr"), HORIZONTAL_ALIGNMENT_LEFT, 480.0, 19, rep.get_palette_color("mfd_accent"), out_col, 2, 13)

		if terminal.screen_mode == "run_end":
			_draw_run_end_telemetry(sz, rep)
		elif terminal.screen_mode == "deck_preview":
			_draw_deck_preview_cards(sz, rep, eng)
		elif terminal.screen_mode == "title":
			_draw_title_screen(sz, rep)

		for i: int in range(terminal.hotspots.size()):
			var h: Dictionary = terminal.hotspots[i]
			var is_hov: bool = (i == terminal.hovered_hotspot_index)
			var kind: String = str(h.get("kind", ""))
			var hrect: Rect2 = h.get("rect", Rect2()) as Rect2
			if is_hov and bool(h.get("enabled", true)):
				hrect = hrect.grow(4.0)

			match kind:
				"reward_card":
					var cid: String = str(h.get("card_id", ""))
					var cdata: Dictionary = rep.get_card(cid)
					var pre_upg: bool = eng.reward_cards_pre_upgraded
					var f_lbl: String = rep.get_ui_text("hud", "reward_pre_upgraded_badge") if pre_upg else rep.get_ui_text("terminal", "reward_install_hover" if is_hov else "reward_select_idle")
					CardEmblemCanvas.draw_full_card_cartridge(
						self,
						hrect,
						rep,
						eng,
						cdata,
						str(h.get("shortcut", "")),
						true,
						f_lbl,
						rep.get_palette_color("selected_glow") if (is_hov or pre_upg) else rep.get_palette_color("playable_glow"),
						is_hov,
						"",
						false,
						false,
						1 if pre_upg else 0
					)
				"shop_card":
					var cid_s: String = str(h.get("card_id", ""))
					var cdata_s: Dictionary = rep.get_card(cid_s)
					var cost_s: int = int(h.get("cost", 34))
					var sold_s: bool = bool(h.get("sold", false))
					var sale_s: bool = bool(h.get("on_sale", false))
					var can_s: bool = bool(h.get("enabled", false))
					var p_txt: String = rep.get_ui_text("terminal", "shop_installed") if sold_s else (rep.get_ui_text("terminal", "shop_scrap_fmt") % cost_s)
					var p_col: Color = rep.get_palette_color("playable_glow") if can_s else rep.get_palette_color("redline_glow")
					CardEmblemCanvas.draw_full_card_cartridge(
						self,
						hrect,
						rep,
						eng,
						cdata_s,
						str(h.get("shortcut", "")),
						can_s,
						p_txt,
						p_col,
						is_hov and can_s,
						p_txt,
						sale_s,
						sold_s
					)
				"shop_relic":
					_draw_relic_pod(hrect, h, is_hov, rep)
				"medallion_action":
					_draw_action_medallion_pod(hrect, h, is_hov, rep)
				"shift_dial":
					_draw_shift_dial_pod(hrect, h, is_hov, rep, eng)
				"deck_remove_tile":
					_draw_deck_remove_cartridge(hrect, h, is_hov, rep, eng)
				"deck_upgrade_tile":
					_draw_deck_upgrade_cartridge(hrect, h, is_hov, rep, eng)
				"route_pod":
					_draw_route_pod(hrect, h, is_hov, rep)

	func _draw_header_stat_gauge(rep: GameRepository, c: Vector2, label: String, val: String, col: Color) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var bg_col: Color = rep.get_palette_color("mfd_bg")
		var poly: PackedVector2Array = PackedVector2Array([
			c + Vector2(-54.0, -22.0),
			c + Vector2(46.0, -22.0),
			c + Vector2(54.0, 0.0),
			c + Vector2(46.0, 22.0),
			c + Vector2(-54.0, 22.0),
			c + Vector2(-46.0, 0.0)
		])
		draw_colored_polygon(poly, bg_col)
		poly.append(poly[0])
		draw_polyline(poly, col * 0.9, 2.0, true)
		DiegeticScreenFactory.draw_fitted_text(self, f_body, c + Vector2(-46.0, -4.0), label, HORIZONTAL_ALIGNMENT_CENTER, 92.0, 13, col.lightened(0.28), out_col, 2, 10)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, c + Vector2(-46.0, 16.0), val, HORIZONTAL_ALIGNMENT_CENTER, 92.0, 19, txt_col, out_col, 2, 12)

	func _draw_relic_pod(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var dis_col: Color = rep.get_palette_color("disabled_tint")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")

		var rid: String = str(h.get("relic_id", ""))
		var rdata: Dictionary = rep.get_relic(rid)
		var cost: int = int(h.get("cost", 42))
		var sold: bool = bool(h.get("sold", false))
		var enabled: bool = bool(h.get("enabled", false))

		var accent: Color = rep.get_palette_color("selected_glow") if enabled else dis_col
		if is_hov and enabled:
			accent = txt_col
		var bg: Color = panel_bg if enabled else mfd_bg
		CardEmblemCanvas.draw_chamfer_plate(self, rect, 12.0, bg, accent, 2.8 if (is_hov and enabled) else 2.0, true)

		var icon_c: Vector2 = Vector2(rect.position.x + 30.0, rect.position.y + 38.0)
		draw_circle(icon_c, 20.0, mfd_bg)
		CardEmblemCanvas.draw_relic_blueprint(self, icon_c, 19.0, rid, accent, Color(accent.r, accent.g, accent.b, 0.22))

		var key_str: String = "[%s] " % str(h.get("shortcut", ""))
		var name_line: String = (key_str + str(rdata.get("name", rid))).to_upper()
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(rect.position.x + 56.0, rect.position.y + 32.0),
			name_line,
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 66.0,
			17,
			txt_col if enabled else dis_col.lightened(0.28),
			out_col,
			3,
			11
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(rect.position.x + 56.0, rect.position.y + 52.0),
			rep.get_ui_text("terminal", "relic_perm_tag"),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 66.0,
			13,
			accent.lightened(0.18),
			out_col,
			2,
			10
		)

		var desc_col: Color = txt_col if enabled else dis_col.lightened(0.22)
		draw_multiline_string_outline(
			f_body,
			Vector2(rect.position.x + 12.0, rect.position.y + 80.0),
			str(rdata.get("description", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 24.0,
			15,
			3,
			2,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(rect.position.x + 12.0, rect.position.y + 80.0),
			str(rdata.get("description", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 24.0,
			15,
			3,
			desc_col
		)

		var bmp_r: Rect2 = Rect2(rect.position.x + 14.0, rect.end.y - 32.0, rect.size.x - 28.0, 24.0)
		var p_col: Color = rep.get_palette_color("playable_glow") if enabled else rep.get_palette_color("redline_glow")
		CardEmblemCanvas.draw_chamfer_plate(self, bmp_r, 5.0, mfd_bg, p_col * 0.88, 1.6, false)
		var p_txt: String = rep.get_ui_text("terminal", "shop_installed") if sold else (rep.get_ui_text("terminal", "shop_scrap_fmt") % cost)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(bmp_r.position.x + 6.0, bmp_r.position.y + 18.0), p_txt, HORIZONTAL_ALIGNMENT_CENTER, bmp_r.size.x - 12.0, 15, p_col.lightened(0.25), out_col, 2, 10)

	func _draw_action_medallion_pod(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var dis_col: Color = rep.get_palette_color("disabled_tint")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")

		var enabled: bool = bool(h.get("enabled", false))
		var col: Color = h.get("color", txt_col) as Color
		var stroke: Color = (txt_col if is_hov else col) if enabled else dis_col
		var bg: Color = Color(col.r * 0.18, col.g * 0.16, col.b * 0.10, 0.96) if enabled else mfd_bg

		CardEmblemCanvas.draw_chamfer_plate(self, rect, 12.0, bg, stroke, 3.0 if (is_hov and enabled) else 2.0, true)

		var ic: Vector2 = Vector2(rect.position.x + 32.0, rect.position.y + rect.size.y * 0.5)
		var ir: float = minf(21.0, rect.size.y * 0.30)
		draw_circle(ic, ir, mfd_bg)
		draw_arc(ic, ir, 0.0, TAU, 18, stroke, 2.2, true)

		var icon_type: String = str(h.get("icon", "launch"))
		match icon_type:
			"repair":
				draw_line(ic + Vector2(-ir * 0.5, 0.0), ic + Vector2(ir * 0.5, 0.0), stroke, 3.5)
				draw_line(ic + Vector2(0.0, -ir * 0.5), ic + Vector2(0.0, ir * 0.5), stroke, 3.5)
			"chassis":
				CardEmblemCanvas._s_draw_shield_shape(self, ic, ir * 0.72, stroke, Color(stroke.r, stroke.g, stroke.b, 0.25))
			"chassis_interceptor":
				var coupe: PackedVector2Array = PackedVector2Array([
					ic + Vector2(-ir * 0.72, ir * 0.22),
					ic + Vector2(-ir * 0.55, -ir * 0.22),
					ic + Vector2(ir * 0.08, -ir * 0.28),
					ic + Vector2(ir * 0.72, ir * 0.02),
					ic + Vector2(ir * 0.72, ir * 0.28)
				])
				draw_colored_polygon(coupe, Color(stroke.r, stroke.g, stroke.b, 0.30))
				coupe.append(coupe[0])
				draw_polyline(coupe, stroke, 2.2, true)
				draw_rect(Rect2(ic + Vector2(ir * 0.12, -ir * 0.42), Vector2(ir * 0.26, ir * 0.22)), stroke, true)
			"chassis_bulldozer":
				var dozer: PackedVector2Array = PackedVector2Array([
					ic + Vector2(-ir * 0.65, ir * 0.30),
					ic + Vector2(-ir * 0.65, -ir * 0.36),
					ic + Vector2(ir * 0.15, -ir * 0.36),
					ic + Vector2(ir * 0.45, -ir * 0.08),
					ic + Vector2(ir * 0.45, ir * 0.30)
				])
				draw_colored_polygon(dozer, Color(stroke.r, stroke.g, stroke.b, 0.30))
				dozer.append(dozer[0])
				draw_polyline(dozer, stroke, 2.2, true)
				draw_line(ic + Vector2(ir * 0.58, -ir * 0.42), ic + Vector2(ir * 0.74, ir * 0.36), stroke, 3.6)
			"chassis_turbo_proto":
				var wedge: PackedVector2Array = PackedVector2Array([
					ic + Vector2(-ir * 0.76, ir * 0.24),
					ic + Vector2(-ir * 0.38, -ir * 0.24),
					ic + Vector2(ir * 0.18, -ir * 0.16),
					ic + Vector2(ir * 0.78, ir * 0.18),
					ic + Vector2(ir * 0.78, ir * 0.26)
				])
				draw_colored_polygon(wedge, Color(stroke.r, stroke.g, stroke.b, 0.30))
				wedge.append(wedge[0])
				draw_polyline(wedge, stroke, 2.2, true)
				draw_circle(ic + Vector2(ir * 0.22, -ir * 0.24), ir * 0.14, stroke)
			"scrap", "reroll":
				CardEmblemCanvas._s_draw_gear_wheel(self, ic, ir * 0.76, stroke, 7)
			"scrap_card":
				CardEmblemCanvas._s_draw_flame_tongue(self, ic, ir * 0.76, stroke, Color(stroke.r, stroke.g, stroke.b, 0.25))
			"cancel":
				draw_line(ic + Vector2(-ir * 0.45, -ir * 0.45), ic + Vector2(ir * 0.45, ir * 0.45), stroke, 3.2)
				draw_line(ic + Vector2(ir * 0.45, -ir * 0.45), ic + Vector2(-ir * 0.45, ir * 0.45), stroke, 3.2)
			_:
				var tri: PackedVector2Array = PackedVector2Array([
					ic + Vector2(-ir * 0.35, -ir * 0.52),
					ic + Vector2(ir * 0.58, 0.0),
					ic + Vector2(-ir * 0.35, ir * 0.52)
				])
				draw_colored_polygon(tri, stroke)

		var tx: float = rect.position.x + 60.0
		var tw: float = maxf(40.0, rect.size.x - 72.0)
		var sc_txt: String = str(h.get("shortcut", ""))
		var title_line: String = ("[%s] %s" % [sc_txt, str(h.get("title", "")).to_upper()]) if not sc_txt.is_empty() else str(h.get("title", "")).to_upper()
		var t_col: Color = txt_col if enabled else dis_col.lightened(0.28)
		var s_col: Color = col.lightened(0.28) if enabled else dis_col.lightened(0.18)

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(tx, rect.position.y + rect.size.y * 0.44),
			title_line,
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			20,
			t_col,
			out_col,
			3,
			12
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(tx, rect.position.y + rect.size.y * 0.77),
			str(h.get("subtitle", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			17,
			s_col,
			out_col,
			2,
			11
		)

	func _draw_shift_dial_pod(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository, eng: CombatEngine) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")

		var delta_g: int = int(h.get("delta_g", 0))
		var target_g: int = int(h.get("target_g", 1))
		var gd: Dictionary = rep.get_gear(target_g)
		var col: Color = rep.get_palette_color("selected_glow") if is_hov else rep.get_palette_color("slot_active")

		CardEmblemCanvas.draw_chamfer_plate(self, rect, 16.0, panel_bg, col, 3.2 if is_hov else 2.2, true)

		var dial_c: Vector2 = Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 124.0)
		var dial_r: float = 72.0
		draw_circle(dial_c, dial_r, mfd_bg)
		draw_arc(dial_c, dial_r, PI * 0.75, PI * 2.25, 28, col, 4.5, true)
		draw_arc(dial_c, dial_r * 0.82, 0.0, TAU, 24, Color(col.r, col.g, col.b, 0.30), 1.8, true)

		var g_short: String = eng.transmission.gear_short_name(target_g)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rect.position.x + 12.0, dial_c.y + 15.0), g_short, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 24.0, 44, txt_col, out_col, 4, 24)

		var d_str: String = rep.get_ui_text("terminal", "shift_dial_fmt") % [str(h.get("shortcut", "")), delta_g]
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rect.position.x + 12.0, rect.position.y + 36.0), d_str, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 24.0, 20, col.lightened(0.2), out_col, 3, 13)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rect.position.x + 12.0, dial_c.y + dial_r + 30.0), str(gd.get("role", "")).to_upper(), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 24.0, 21, rep.get_palette_color("playable_glow"), out_col, 3, 13)

		draw_multiline_string_outline(
			f_body,
			Vector2(rect.position.x + 16.0, dial_c.y + dial_r + 60.0),
			str(gd.get("description", "")),
			HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x - 32.0,
			17,
			4,
			2,
			out_col
		)
		draw_multiline_string(
			f_body,
			Vector2(rect.position.x + 16.0, dial_c.y + dial_r + 60.0),
			str(gd.get("description", "")),
			HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x - 32.0,
			17,
			4,
			txt_col
		)

	func _draw_route_pod(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")
		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")

		var is_elite: bool = bool(h.get("is_elite", false))
		var col: Color = rep.get_palette_color("selected_glow") if is_hov else (rep.get_palette_color("redline_glow") if is_elite else rep.get_palette_color("playable_glow"))
		CardEmblemCanvas.draw_chamfer_plate(self, rect, 18.0, panel_bg, col, 3.2 if is_hov else 2.2, true)
		var sc_txt: String = rep.get_ui_text("terminal", "route_lane_fmt") % str(h.get("shortcut", "1"))
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rect.position.x + 20.0, rect.position.y + 42.0), sc_txt, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 40.0, 20, col, out_col, 3, 14)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(rect.position.x + 24.0, rect.position.y + 88.0), str(h.get("title", "")).to_upper(), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 48.0, 26, txt_col, out_col, 3, 16)
		var ic: Vector2 = Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 185.0)
		draw_circle(ic, 54.0, mfd_bg)
		draw_arc(ic, 54.0, 0.0, TAU, 28, col, 3.5, true)
		CardEmblemCanvas._s_draw_gear_wheel(self, ic, 36.0, col, 8)
		DiegeticScreenFactory.draw_fitted_text(self, f_body, Vector2(rect.position.x + 24.0, rect.position.y + 276.0), rep.get_ui_text("terminal", "route_hostiles_hdr"), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 48.0, 17, rep.get_palette_color("mfd_muted").lightened(0.2), out_col, 2, 12)
		draw_multiline_string(f_body, Vector2(rect.position.x + 28.0, rect.position.y + 306.0), str(h.get("enemies_text", "")), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 56.0, 20, 2, rep.get_palette_color("mfd_accent"))
		var b_rect: Rect2 = Rect2(rect.position.x + 36.0, rect.end.y - 68.0, rect.size.x - 72.0, 44.0)
		CardEmblemCanvas.draw_chamfer_plate(self, b_rect, 8.0, mfd_bg, rep.get_palette_color("playable_glow"), 1.8, false)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(b_rect.position.x + 10.0, b_rect.position.y + 29.0), rep.get_ui_text("terminal", "route_bonus_prefix") + str(h.get("bonus_text", "")), HORIZONTAL_ALIGNMENT_CENTER, b_rect.size.x - 20.0, 18, rep.get_palette_color("playable_glow").lightened(0.25), out_col, 2, 12)

	func _draw_deck_remove_cartridge(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository, eng: CombatEngine) -> void:
		var cid: String = str(h.get("card_id", ""))
		var card: Dictionary = rep.get_card(cid)
		CardEmblemCanvas.draw_full_card_cartridge(
			self,
			rect,
			rep,
			eng,
			card,
			str(h.get("shortcut", "")),
			true,
			rep.get_ui_text("terminal", "dismantle_footer"),
			rep.get_palette_color("redline_glow"),
			is_hov,
			rep.get_ui_text("terminal", "dismantle_footer")
		)

	func _draw_run_end_telemetry(sz: Vector2, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")

		var c: Vector2 = Vector2(sz.x * 0.5, 272.0)
		var col: Color = rep.get_palette_color("playable_glow") if terminal.run_end_victory else rep.get_palette_color("redline_glow")

		draw_circle(c, 104.0, mfd_bg)
		draw_arc(c, 104.0, 0.0, TAU, 36, col, 4.5, true)
		CardEmblemCanvas._s_draw_gear_wheel(self, c, 72.0, col, 10)

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(72.0, 438.0),
			terminal.run_end_summary,
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 144.0,
			26,
			txt_col,
			out_col,
			3,
			15
		)

	func _draw_deck_upgrade_cartridge(rect: Rect2, h: Dictionary, is_hov: bool, rep: GameRepository, eng: CombatEngine) -> void:
		var cid: String = str(h.get("card_id", ""))
		var card: Dictionary = rep.get_card(cid)
		var lvl: int = int(h.get("upgrade_level", 0))
		var cnt: int = int(h.get("copies", 0))
		var badge_str: String = "x%d • PWR %d -> %d" % [cnt, lvl, lvl + 1]
		CardEmblemCanvas.draw_full_card_cartridge(
			self,
			rect,
			rep,
			eng,
			card,
			str(h.get("shortcut", "")),
			true,
			badge_str,
			rep.get_palette_color("playable_glow"),
			is_hov,
			badge_str,
			false,
			false,
			1
		)

	func _draw_title_screen(sz: Vector2, rep: GameRepository) -> void:
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()
		var txt_col: Color = rep.get_palette_color("mfd_text")
		var mfd_bg: Color = rep.get_palette_color("mfd_bg")
		var cx: float = sz.x * 0.5

		if terminal.title_selecting_chassis:
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(60.0, 136.0),
				rep.get_ui_text("terminal", "title_select_heading"),
				HORIZONTAL_ALIGNMENT_CENTER,
				sz.x - 120.0,
				38,
				rep.get_palette_color("mfd_accent"),
				out_col,
				4,
				22
			)
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_body,
				Vector2(60.0, 176.0),
				rep.get_ui_text("terminal", "title_select_sub"),
				HORIZONTAL_ALIGNMENT_CENTER,
				sz.x - 120.0,
				20,
				txt_col,
				out_col,
				3,
				14
			)
			return

		var c: Vector2 = Vector2(cx, 142.0)
		var sel_col: Color = rep.get_palette_color("selected_glow")
		var play_col: Color = rep.get_palette_color("playable_glow")
		draw_circle(c, 52.0, mfd_bg)
		draw_arc(c, 52.0, 0.0, TAU, 36, sel_col, 4.0, true)
		CardEmblemCanvas._s_draw_gear_wheel(self, c, 36.0, play_col, 10)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			c + Vector2(-70.0, 8.0),
			rep.get_ui_text("terminal", "title_emblem_code"),
			HORIZONTAL_ALIGNMENT_CENTER,
			140.0,
			20,
			txt_col,
			out_col,
			4,
			12
		)

		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(60.0, 250.0),
			rep.get_ui_text("app_title", "app_title") if rep.ui_strings.get("app_title") is Dictionary else str(rep.ui_strings.get("app_title", "")),
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 120.0,
			56,
			rep.get_palette_color("mfd_accent"),
			out_col,
			5,
			28
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(60.0, 286.0),
			rep.get_ui_text("terminal", "title_tagline"),
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 120.0,
			19,
			txt_col,
			out_col,
			3,
			13
		)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(54.0, 646.0),
			rep.get_ui_text("terminal", "title_controls"),
			HORIZONTAL_ALIGNMENT_CENTER,
			sz.x - 108.0,
			16,
			rep.get_palette_color("mfd_muted").lightened(0.18),
			out_col,
			2,
			11
		)

	func _draw_deck_preview_cards(sz: Vector2, rep: GameRepository, eng: CombatEngine) -> void:
		var f_disp: Font = rep.get_font("display")
		var out_col: Color = rep.get_outline_color()
		if eng.draw_pile.is_empty():
			DiegeticScreenFactory.draw_fitted_text(
				self,
				f_disp,
				Vector2(80.0, 324.0),
				rep.get_ui_text("terminal", "deck_empty_msg"),
				HORIZONTAL_ALIGNMENT_CENTER,
				sz.x - 160.0,
				26,
				rep.get_palette_color("selected_glow"),
				out_col,
				3,
				15
			)
			return

		var counts: Dictionary = {}
		for cid: String in eng.draw_pile:
			counts[cid] = int(counts.get(cid, 0)) + 1
		var unique_ids: Array = counts.keys()
		unique_ids.sort()

		var off: int = _clamp_page_offset(unique_ids.size(), 6)
		var max_shown: int = clampi(unique_ids.size() - off, 0, 6)
		var cw: float = 192.0
		var ch: float = 438.0
		var gx: float = 12.0
		var total_w: float = float(max_shown) * cw + float(maxi(0, max_shown - 1)) * gx
		var start_x: float = (sz.x - total_w) * 0.5
		var start_y: float = 102.0

		for i: int in range(max_shown):
			var cid: String = str(unique_ids[off + i])
			var qty: int = int(counts[cid])
			var cdata: Dictionary = rep.get_card(cid)
			var crect: Rect2 = Rect2(start_x + float(i) * (cw + gx), start_y, cw, ch)
			var allowed: Array = cdata.get("allowed_gears", []) as Array
			var gear_ok: bool = CardEffectFormatter.contains_gear(allowed, eng.current_gear)
			var qty_txt: String = rep.get_ui_text("terminal", "deck_queued_fmt") % qty
			CardEmblemCanvas.draw_full_card_cartridge(
				self,
				crect,
				rep,
				eng,
				cdata,
				"",
				gear_ok,
				qty_txt,
				rep.get_palette_color("playable_glow") if gear_ok else rep.get_palette_color("selected_glow"),
				false,
				qty_txt
			)
