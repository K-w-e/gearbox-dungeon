class_name MainMenuOverlay
extends CanvasLayer

signal title_action_requested(action_id: String)
signal chassis_preview_changed(chassis_id: String)
signal view_mode_changed(view_mode: String)
signal engine_audio_cycle_requested
signal sfx_audio_cycle_requested
signal mute_toggle_requested
signal fullscreen_toggle_requested
signal quality_cycle_requested
signal quit_requested
signal menu_hover_activity(boost: float, target_gear: int)

const VIEW_MAIN: String = "main"
const VIEW_CHASSIS: String = "chassis"
const VIEW_SYSTEMS: String = "systems"

var repo: GameRepository
var engine: CombatEngine

var backdrop_canvas: _MenuBackdropCanvas
var root_margin: MarginContainer
var main_column: VBoxContainer
var header_status_lbl: Label
var hgate_widget: _HGateMiniWidget
var body_host: VBoxContainer
var pilot_summary_lbl: Label
var footer_keys_lbl: Label
var flash_rect: ColorRect

var current_view: String = VIEW_MAIN
var guided_tour_requested: bool = false
var first_boot_tutorial_recommended: bool = false
var selected_chassis_id: String = "interceptor"
var selected_overdrive_level: int = 0
var chassis_stats: Dictionary = {}
var engine_audio_label: String = "100%"
var sfx_audio_label: String = "100%"
var audio_muted: bool = false
var fullscreen_active: bool = false
var quality_label: String = "HIGH"

var action_buttons: Array[Dictionary] = []
var focused_index: int = 0
var flash_alpha: float = 0.0
var is_menu_visible: bool = false

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	if repository == null or combat_engine == null:
		push_error("MainMenuOverlay.initialize received null dependencies")
		return
	repo = repository
	engine = combat_engine
	layer = 12

	var ucfg: Dictionary = _ui_cfg()
	backdrop_canvas = _MenuBackdropCanvas.new()
	backdrop_canvas.repo = repo
	backdrop_canvas.vignette_ratio = float(ucfg.get("vignette_width_ratio", 0.58))
	backdrop_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop_canvas)

	root_margin = MarginContainer.new()
	root_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	root_margin.add_theme_constant_override("margin_left", int(ucfg.get("left_margin_px", 46.0)))
	root_margin.add_theme_constant_override("margin_top", int(ucfg.get("top_margin_px", 34.0)))
	root_margin.add_theme_constant_override("margin_bottom", int(ucfg.get("bottom_margin_px", 28.0)))
	root_margin.add_theme_constant_override("margin_right", int(ucfg.get("left_margin_px", 46.0)))
	add_child(root_margin)

	var outer_vbox: VBoxContainer = VBoxContainer.new()
	outer_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	root_margin.add_child(outer_vbox)

	main_column = VBoxContainer.new()
	main_column.custom_minimum_size = Vector2(float(ucfg.get("main_panel_width_px", 540.0)), 0.0)
	main_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	main_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_column.add_theme_constant_override("separation", 14)
	outer_vbox.add_child(main_column)

	_build_brand_header()

	body_host = VBoxContainer.new()
	body_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_host.add_theme_constant_override("separation", 10)
	main_column.add_child(body_host)

	_build_footer_bar(outer_vbox)

	flash_rect = ColorRect.new()
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect.color = Color(1.0, 0.82, 0.36, 0.0)
	flash_rect.visible = false
	add_child(flash_rect)

	rebuild_view()
	set_menu_visible(false)

func _ui_cfg() -> Dictionary:
	if repo == null:
		return {}
	return repo.title_menu_cfg().get("ui", {}) as Dictionary

func _build_brand_header() -> void:
	var col_accent: Color = repo.get_palette_color("mfd_accent")
	var col_text: Color = repo.get_palette_color("mfd_text")
	var col_muted: Color = repo.get_palette_color("mfd_muted")
	var col_bg: Color = repo.get_palette_color("mfd_bg")

	var hdr_row: HBoxContainer = HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 14)
	main_column.add_child(hdr_row)

	var title_box: VBoxContainer = VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 4)
	hdr_row.add_child(title_box)

	var badge_panel: PanelContainer = PanelContainer.new()
	badge_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	badge_panel.add_theme_stylebox_override(
		"panel",
		DiegeticScreenFactory.make_panel_style(Color(col_accent.r * 0.16, col_accent.g * 0.12, col_accent.b * 0.04, 0.92), col_accent, 2, 3, 10.0, 3.0)
	)
	title_box.add_child(badge_panel)

	var badge_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("main_menu", "badge_code"),
		13,
		col_accent.lightened(0.18),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	badge_panel.add_child(badge_lbl)

	var app_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("app_title", "app_title") if repo.ui_strings.has("app_title") and typeof(repo.ui_strings["app_title"]) == TYPE_DICTIONARY else str(repo.ui_strings.get("app_title", "GEARBOX DUNGEON")),
		46,
		col_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		4,
		repo,
		"display"
	)
	title_box.add_child(app_lbl)

	var accent_rule: ColorRect = ColorRect.new()
	accent_rule.custom_minimum_size = Vector2(0.0, 3.0)
	accent_rule.color = col_accent
	title_box.add_child(accent_rule)

	header_status_lbl = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("main_menu", "status_idle"),
		14,
		col_muted.lightened(0.12),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	title_box.add_child(header_status_lbl)

	var hgate_frame: PanelContainer = PanelContainer.new()
	hgate_frame.custom_minimum_size = Vector2(118.0, 104.0)
	hgate_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hgate_frame.add_theme_stylebox_override(
		"panel",
		DiegeticScreenFactory.make_panel_style(Color(col_bg.r, col_bg.g, col_bg.b, 0.90), col_accent * 0.78, 2, 4, 6.0, 6.0)
	)
	hdr_row.add_child(hgate_frame)

	hgate_widget = _HGateMiniWidget.new()
	hgate_widget.repo = repo
	hgate_widget.gear_coords = _ui_cfg().get("hgate_gear_coords", {}) as Dictionary
	hgate_widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hgate_widget.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hgate_frame.add_child(hgate_widget)

func _build_footer_bar(parent: VBoxContainer) -> void:
	var col_muted: Color = repo.get_palette_color("mfd_muted")
	var col_accent: Color = repo.get_palette_color("mfd_accent")

	var footer_vbox: VBoxContainer = VBoxContainer.new()
	footer_vbox.add_theme_constant_override("separation", 4)
	footer_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(footer_vbox)

	pilot_summary_lbl = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("main_menu", "pilot_summary_fresh"),
		14,
		col_accent.lightened(0.12),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	footer_vbox.add_child(pilot_summary_lbl)

	footer_keys_lbl = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("main_menu", "footer_keys"),
		13,
		col_muted,
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	footer_vbox.add_child(footer_keys_lbl)

func set_menu_visible(show_menu: bool) -> void:
	is_menu_visible = show_menu
	visible = show_menu
	set_process(show_menu or flash_alpha > 0.01)
	if show_menu:
		current_view = VIEW_MAIN
		guided_tour_requested = false
		rebuild_view()
		view_mode_changed.emit(current_view)
		chassis_preview_changed.emit(selected_chassis_id)

func sync_settings_labels(eng_lbl: String, sfx_lbl: String, is_muted: bool, is_fs: bool, qual_lbl: String) -> void:
	engine_audio_label = eng_lbl
	sfx_audio_label = sfx_lbl
	audio_muted = is_muted
	fullscreen_active = is_fs
	quality_label = qual_lbl
	if is_menu_visible and current_view == VIEW_SYSTEMS:
		rebuild_view()

func sync_pilot_data(stats: Dictionary, _overdrive_lvl: int, recommend_tutorial: bool) -> void:
	chassis_stats = stats.duplicate(true)
	selected_overdrive_level = 0
	first_boot_tutorial_recommended = recommend_tutorial
	_update_pilot_summary_label()
	if is_menu_visible:
		rebuild_view()

func trigger_launch_flash() -> void:
	flash_alpha = 0.85
	if flash_rect != null:
		flash_rect.visible = true
		flash_rect.color.a = flash_alpha
	set_process(true)

func _update_pilot_summary_label() -> void:
	if pilot_summary_lbl == null or repo == null:
		return
	var total_runs: int = 0
	var total_wins: int = 0
	for cid: Variant in chassis_stats.keys():
		var st: Dictionary = chassis_stats[cid] as Dictionary
		total_runs += int(st.get("runs", 0))
		total_wins += int(st.get("wins", 0))
	if total_runs > 0:
		pilot_summary_lbl.text = repo.get_ui_text("main_menu", "pilot_summary_fmt") % [total_runs, total_wins]
	else:
		pilot_summary_lbl.text = repo.get_ui_text("main_menu", "pilot_summary_fresh")

func _set_view(next_view: String) -> void:
	if current_view == next_view:
		return
	current_view = next_view
	focused_index = 0
	engine.sfx_requested.emit("hydraulic_servo", 0.68)
	rebuild_view()
	view_mode_changed.emit(current_view)

func rebuild_view() -> void:
	if body_host == null or repo == null or engine == null:
		return
	for child: Node in body_host.get_children():
		child.queue_free()
	action_buttons.clear()

	var ucfg: Dictionary = _ui_cfg()
	match current_view:
		VIEW_MAIN:
			main_column.custom_minimum_size.x = float(ucfg.get("main_panel_width_px", 540.0))
			header_status_lbl.text = repo.get_ui_text("main_menu", "status_idle")
			_build_main_view()
		VIEW_CHASSIS:
			main_column.custom_minimum_size.x = float(ucfg.get("chassis_panel_width_px", 600.0))
			header_status_lbl.text = repo.get_ui_text("main_menu", "status_chassis")
			_build_chassis_view()
		VIEW_SYSTEMS:
			main_column.custom_minimum_size.x = float(ucfg.get("systems_panel_width_px", 560.0))
			header_status_lbl.text = repo.get_ui_text("main_menu", "status_systems")
			_build_systems_view()

	_update_pilot_summary_label()
	if not action_buttons.is_empty():
		focused_index = clampi(focused_index, 0, action_buttons.size() - 1)
		_apply_focus_visuals()

func _build_main_view() -> void:
	var col_play: Color = repo.get_palette_color("playable_glow")
	var col_sel: Color = repo.get_palette_color("selected_glow")
	var col_draw: Color = repo.get_palette_color("kw_draw")
	var col_shield: Color = repo.get_palette_color("kw_shield")
	var col_red: Color = repo.get_palette_color("redline_glow")

	var tagline: Label = DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("terminal", "title_tagline"),
		14,
		repo.get_palette_color("mfd_text") * 0.88,
		HORIZONTAL_ALIGNMENT_LEFT,
		true,
		2,
		repo,
		"body_bold"
	)
	body_host.add_child(tagline)

	var spacer_top: Control = Control.new()
	spacer_top.custom_minimum_size = Vector2(0.0, 6.0)
	body_host.add_child(spacer_top)

	var saved_info: Dictionary = engine.peek_saved_run_info()
	var has_save: bool = not saved_info.is_empty()
	var slot_num: int = 1

	if has_save:
		var s_cid: String = str(saved_info.get("selected_chassis_id", "interceptor"))
		var s_name: String = str(engine.get_chassis_preset(s_cid).get("name", s_cid)).to_upper()
		var s_stg: int = int(saved_info.get("stage_index", 0)) + 1
		var s_hp: int = int(saved_info.get("hp", 1))
		var s_max: int = int(saved_info.get("max_hp", 70))
		var s_od: int = int(saved_info.get("overdrive_level", 0))
		var od_tag: String = ("  •  OD %d" % s_od) if s_od > 0 else ""
		var cont_sub: String = repo.get_ui_text("terminal", "btn_continue_run_sub_fmt") % [s_name, s_stg, s_hp, s_max, od_tag]
		_add_action_plate(
			str(slot_num),
			repo.get_ui_text("terminal", "btn_continue_run"),
			cont_sub,
			col_play,
			1,
			0.85,
			func() -> void:
				trigger_launch_flash()
				title_action_requested.emit("continue"),
			s_cid
		)
		slot_num += 1

	var first_boot: bool = first_boot_tutorial_recommended
	var tut_title: String = repo.get_ui_text("terminal", "btn_tutorial_rec" if first_boot else "btn_tutorial")
	var tut_sub: String = repo.get_ui_text("terminal", "btn_tutorial_rec_sub" if first_boot else "btn_tutorial_sub")

	if first_boot:
		_add_action_plate(
			str(slot_num),
			tut_title,
			tut_sub,
			col_play,
			2,
			0.75,
			func() -> void:
				guided_tour_requested = true
				_set_view(VIEW_CHASSIS)
		)
		slot_num += 1
		_add_action_plate(
			str(slot_num),
			repo.get_ui_text("terminal", "btn_start_run"),
			repo.get_ui_text("terminal", "btn_start_run_sub"),
			col_sel,
			3,
			0.70,
			func() -> void:
				guided_tour_requested = false
				_set_view(VIEW_CHASSIS)
		)
		slot_num += 1
	else:
		_add_action_plate(
			str(slot_num),
			repo.get_ui_text("terminal", "btn_start_run"),
			repo.get_ui_text("terminal", "btn_start_run_sub"),
			col_sel if has_save else col_play,
			2,
			0.78,
			func() -> void:
				guided_tour_requested = false
				_set_view(VIEW_CHASSIS)
		)
		slot_num += 1
		_add_action_plate(
			str(slot_num),
			tut_title,
			tut_sub,
			col_draw,
			3,
			0.58,
			func() -> void:
				guided_tour_requested = true
				_set_view(VIEW_CHASSIS)
		)
		slot_num += 1

	_add_action_plate(
		str(slot_num),
		repo.get_ui_text("main_menu", "btn_systems"),
		repo.get_ui_text("main_menu", "btn_systems_sub"),
		col_shield,
		4,
		0.45,
		func() -> void:
			_set_view(VIEW_SYSTEMS)
	)
	slot_num += 1

	if not OS.has_feature("web"):
		_add_action_plate(
			str(slot_num),
			repo.get_ui_text("main_menu", "btn_exit"),
			repo.get_ui_text("main_menu", "btn_exit_sub"),
			col_red,
			-1,
			0.20,
			func() -> void:
				quit_requested.emit()
		)

func _build_chassis_view() -> void:
	var presets: Array = repo.gameplay().get("chassis_presets", []) as Array
	var col_play: Color = repo.get_palette_color("playable_glow")
	var col_sel: Color = repo.get_palette_color("selected_glow")
	var col_shield: Color = repo.get_palette_color("kw_shield")
	var col_red: Color = repo.get_palette_color("redline_glow")

	for ci: int in range(presets.size()):
		if typeof(presets[ci]) != TYPE_DICTIONARY:
			continue
		var pr: Dictionary = presets[ci] as Dictionary
		var pid: String = str(pr.get("id", "interceptor"))
		var pname: String = str(pr.get("name", pid)).to_upper()
		var pdesc: String = str(pr.get("description", ""))
		var max_hp: int = int(pr.get("max_hp", 70))
		var start_g: int = int(pr.get("starting_gear", 1))
		var start_rpm: int = int(pr.get("starting_rpm_units", 2))
		var start_scrap: int = int(pr.get("starting_scrap", 45))
		var relic_id: String = str(pr.get("starting_relic", ""))
		var relic_name: String = str(repo.get_relic(relic_id).get("name", relic_id)).to_upper()
		var cons_id: String = str(pr.get("starting_consumable", ""))
		var cons_name: String = str(repo.get_consumable(cons_id).get("short", cons_id)).to_upper()

		var g_short: String = engine.transmission.gear_short_name(start_g)
		var st: Dictionary = chassis_stats.get(pid, {}) as Dictionary
		var runs_c: int = int(st.get("runs", 0))
		var wins_c: int = int(st.get("wins", 0))
		var rec_str: String = (repo.get_ui_text("main_menu", "chassis_record_wins_fmt") % [wins_c, runs_c]) if wins_c > 0 else ((repo.get_ui_text("main_menu", "chassis_record_runs_fmt") % runs_c) if runs_c > 0 else repo.get_ui_text("main_menu", "chassis_record_new"))

		var stats_line: String = "%s  •  %s  •  %s  •  %s" % [
			repo.get_ui_text("main_menu", "chassis_hull_fmt") % max_hp,
			repo.get_ui_text("main_menu", "chassis_gear_fmt") % g_short,
			repo.get_ui_text("main_menu", "chassis_rpm_fmt") % start_rpm,
			repo.get_ui_text("main_menu", "chassis_scrap_fmt") % start_scrap
		]
		var kit_line: String = "%s%s  |  %s%s" % [
			repo.get_ui_text("main_menu", "chassis_relic_prefix"),
			relic_name,
			repo.get_ui_text("main_menu", "chassis_canister_prefix"),
			cons_name
		]
		var accent: Color = col_play if ci == 0 else (col_sel if ci == 1 else col_shield)
		var is_selected: bool = (pid == selected_chassis_id)

		_add_chassis_plate(
			str(ci + 1),
			pid,
			pname,
			rec_str,
			stats_line,
			kit_line,
			pdesc,
			accent,
			is_selected,
			start_g
		)

	var launch_row: HBoxContainer = HBoxContainer.new()
	launch_row.add_theme_constant_override("separation", 10)
	body_host.add_child(launch_row)

	var launch_title: String = repo.get_ui_text("main_menu", "btn_launch_guided" if guided_tour_requested else "btn_launch_chassis")
	var launch_sub: String = repo.get_ui_text("main_menu", "btn_launch_guided_sub" if guided_tour_requested else "btn_launch_chassis_sub")
	_add_action_plate(
		"ENTER",
		launch_title,
		launch_sub,
		col_play,
		1,
		1.0,
		func() -> void:
			_emit_launch_selected_chassis(),
		"",
		launch_row,
		true
	)

	_add_action_plate(
		"ESC",
		repo.get_ui_text("terminal", "btn_back"),
		"",
		col_red,
		0,
		0.15,
		func() -> void:
			guided_tour_requested = false
			_set_view(VIEW_MAIN),
		"",
		launch_row,
		false
	)

func _build_systems_view() -> void:
	var col_sel: Color = repo.get_palette_color("selected_glow")
	var col_accent: Color = repo.get_palette_color("mfd_accent")
	var col_shield: Color = repo.get_palette_color("kw_shield")
	var col_draw: Color = repo.get_palette_color("kw_draw")
	var col_red: Color = repo.get_palette_color("redline_glow")
	var col_bg: Color = repo.get_palette_color("mfd_bg")

	_add_action_plate(
		"1",
		repo.get_ui_text("terminal", "pause_engine_audio_fmt") % engine_audio_label,
		repo.get_ui_text("terminal", "pause_engine_audio_sub"),
		col_sel,
		2,
		0.40,
		func() -> void: engine_audio_cycle_requested.emit()
	)
	_add_action_plate(
		"2",
		repo.get_ui_text("terminal", "pause_sfx_audio_fmt") % sfx_audio_label,
		repo.get_ui_text("terminal", "pause_sfx_audio_sub"),
		col_accent,
		3,
		0.40,
		func() -> void: sfx_audio_cycle_requested.emit()
	)
	var mute_lbl: String = repo.get_ui_text("main_menu", "mute_on" if audio_muted else "mute_off")
	_add_action_plate(
		"3",
		repo.get_ui_text("main_menu", "mute_title_fmt") % mute_lbl,
		repo.get_ui_text("main_menu", "mute_sub"),
		col_red if audio_muted else col_shield,
		0,
		0.25,
		func() -> void: mute_toggle_requested.emit()
	)
	var disp_lbl: String = repo.get_ui_text("terminal", "pause_mode_fullscreen" if fullscreen_active else "pause_mode_windowed")
	_add_action_plate(
		"4",
		repo.get_ui_text("terminal", "pause_display_title_fmt") % disp_lbl,
		repo.get_ui_text("terminal", "pause_display_sub"),
		col_shield,
		4,
		0.35,
		func() -> void: fullscreen_toggle_requested.emit()
	)
	_add_action_plate(
		"5",
		repo.get_ui_text("terminal", "pause_quality_title_fmt") % quality_label,
		repo.get_ui_text("terminal", "pause_quality_sub"),
		col_draw,
		5,
		0.45,
		func() -> void: quality_cycle_requested.emit()
	)

	var ctrl_panel: PanelContainer = PanelContainer.new()
	ctrl_panel.add_theme_stylebox_override(
		"panel",
		DiegeticScreenFactory.make_panel_style(Color(col_bg.r, col_bg.g, col_bg.b, 0.88), col_accent * 0.55, 2, 4, 12.0, 9.0)
	)
	body_host.add_child(ctrl_panel)

	var ctrl_vbox: VBoxContainer = VBoxContainer.new()
	ctrl_vbox.add_theme_constant_override("separation", 4)
	ctrl_panel.add_child(ctrl_vbox)

	ctrl_vbox.add_child(DiegeticScreenFactory.make_crisp_label(
		repo.get_ui_text("main_menu", "controls_heading"),
		13,
		col_accent,
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	))
	var rows_val: Variant = (repo.ui_strings.get("main_menu", {}) as Dictionary).get("controls_rows", [])
	if typeof(rows_val) == TYPE_ARRAY:
		for r_val: Variant in (rows_val as Array):
			ctrl_vbox.add_child(DiegeticScreenFactory.make_crisp_label(
				str(r_val),
				13,
				repo.get_palette_color("mfd_text") * 0.92,
				HORIZONTAL_ALIGNMENT_LEFT,
				true,
				2,
				repo,
				"body_bold"
			))

	_add_action_plate(
		"ESC",
		repo.get_ui_text("terminal", "btn_back"),
		repo.get_ui_text("terminal", "btn_back_sub"),
		col_red,
		0,
		0.15,
		func() -> void: _set_view(VIEW_MAIN)
	)

func _add_action_plate(
	shortcut_txt: String,
	title_txt: String,
	sub_txt: String,
	accent: Color,
	gear_slot: int,
	boost_amt: float,
	callback: Callable,
	preview_cid: String = "",
	target_parent: Control = null,
	expand_x: bool = true
) -> void:
	var btn: Button = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.custom_minimum_size = Vector2(156.0 if not expand_x else 0.0, 68.0)
	if expand_x:
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col_bg: Color = repo.get_palette_color("mfd_panel_bg")
	var normal_style: StyleBoxFlat = DiegeticScreenFactory.make_panel_style(
		Color(col_bg.r, col_bg.g, col_bg.b, 0.90),
		accent * 0.72,
		2,
		4,
		14.0,
		8.0
	)
	normal_style.border_width_left = 6
	var hover_style: StyleBoxFlat = DiegeticScreenFactory.make_panel_style(
		Color(col_bg.r + accent.r * 0.14, col_bg.g + accent.g * 0.14, col_bg.b + accent.b * 0.14, 0.96),
		accent.lightened(0.28),
		2,
		4,
		18.0,
		8.0
	)
	hover_style.border_width_left = 8
	var pressed_style: StyleBoxFlat = DiegeticScreenFactory.make_panel_style(
		Color(col_bg.r + accent.r * 0.08, col_bg.g + accent.g * 0.08, col_bg.b + accent.b * 0.08, 0.98),
		Color.WHITE,
		2,
		4,
		16.0,
		8.0
	)
	pressed_style.border_width_left = 8

	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	var pad: MarginContainer = MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 6)
	btn.add_child(pad)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 12)
	pad.add_child(hbox)

	var key_badge: PanelContainer = PanelContainer.new()
	key_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	key_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	key_badge.custom_minimum_size = Vector2(46.0 if shortcut_txt.length() <= 2 else 62.0, 34.0)
	key_badge.add_theme_stylebox_override(
		"panel",
		DiegeticScreenFactory.make_panel_style(Color(accent.r * 0.22, accent.g * 0.22, accent.b * 0.22, 0.92), accent, 2, 3, 6.0, 2.0)
	)
	hbox.add_child(key_badge)

	var key_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		shortcut_txt,
		15,
		accent.lightened(0.32),
		HORIZONTAL_ALIGNMENT_CENTER,
		false,
		2,
		repo,
		"mono"
	)
	key_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	key_badge.add_child(key_lbl)

	var txt_vbox: VBoxContainer = VBoxContainer.new()
	txt_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	txt_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	txt_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	txt_vbox.add_theme_constant_override("separation", 1)
	hbox.add_child(txt_vbox)

	var t_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		title_txt,
		19,
		repo.get_palette_color("mfd_text"),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		3,
		repo,
		"display"
	)
	t_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	txt_vbox.add_child(t_lbl)

	if not sub_txt.is_empty() and expand_x:
		var s_lbl: Label = DiegeticScreenFactory.make_crisp_label(
			sub_txt,
			13,
			repo.get_palette_color("mfd_muted").lightened(0.14),
			HORIZONTAL_ALIGNMENT_LEFT,
			false,
			2,
			repo,
			"body_bold"
		)
		s_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		s_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		txt_vbox.add_child(s_lbl)

	var idx: int = action_buttons.size()
	action_buttons.append({
		"button": btn,
		"normal_style": normal_style,
		"hover_style": hover_style,
		"callback": callback,
		"gear": gear_slot,
		"boost": boost_amt,
		"chassis_id": preview_cid
	})

	btn.mouse_entered.connect(func() -> void:
		focused_index = idx
		_apply_focus_visuals()
		engine.sfx_requested.emit("switch_click", 0.36)
		if hgate_widget != null:
			hgate_widget.set_target_gear(gear_slot)
		menu_hover_activity.emit(boost_amt, gear_slot)
		if not preview_cid.is_empty():
			chassis_preview_changed.emit(preview_cid)
	)
	btn.pressed.connect(func() -> void:
		engine.sfx_requested.emit("switch_click", 0.72)
		if callback.is_valid():
			callback.call()
	)

	var container: Control = target_parent if target_parent != null else body_host
	container.add_child(btn)

func _add_chassis_plate(
	shortcut_txt: String,
	cid: String,
	title_txt: String,
	record_txt: String,
	stats_txt: String,
	kit_txt: String,
	desc_txt: String,
	accent: Color,
	is_selected: bool,
	start_gear: int
) -> void:
	var btn: Button = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.custom_minimum_size = Vector2(0.0, 108.0)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col_bg: Color = repo.get_palette_color("mfd_panel_bg")
	var base_fill: Color = Color(col_bg.r + accent.r * 0.14, col_bg.g + accent.g * 0.14, col_bg.b + accent.b * 0.14, 0.96) if is_selected else Color(col_bg.r, col_bg.g, col_bg.b, 0.88)
	var normal_style: StyleBoxFlat = DiegeticScreenFactory.make_panel_style(
		base_fill,
		accent.lightened(0.26) if is_selected else accent * 0.65,
		2,
		4,
		14.0,
		8.0
	)
	normal_style.border_width_left = 8 if is_selected else 5
	var hover_style: StyleBoxFlat = DiegeticScreenFactory.make_panel_style(
		Color(col_bg.r + accent.r * 0.18, col_bg.g + accent.g * 0.18, col_bg.b + accent.b * 0.18, 0.97),
		accent.lightened(0.38),
		2,
		4,
		16.0,
		8.0
	)
	hover_style.border_width_left = 8

	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)

	var pad_c: MarginContainer = MarginContainer.new()
	pad_c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_c.add_theme_constant_override("margin_left", 16)
	pad_c.add_theme_constant_override("margin_right", 14)
	pad_c.add_theme_constant_override("margin_top", 8)
	pad_c.add_theme_constant_override("margin_bottom", 8)
	btn.add_child(pad_c)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 3)
	pad_c.add_child(vbox)

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_theme_constant_override("separation", 8)
	vbox.add_child(top_row)

	var key_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		"[%s]" % shortcut_txt,
		15,
		accent.lightened(0.30),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	key_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(key_lbl)

	var name_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		title_txt,
		20,
		Color.WHITE if is_selected else repo.get_palette_color("mfd_text"),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		3,
		repo,
		"display"
	)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(name_lbl)

	var rec_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		record_txt,
		13,
		accent.lightened(0.24),
		HORIZONTAL_ALIGNMENT_RIGHT,
		false,
		2,
		repo,
		"mono"
	)
	rec_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(rec_lbl)

	var st_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		stats_txt,
		14,
		accent.lightened(0.20),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"mono"
	)
	st_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(st_lbl)

	var kit_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		kit_txt,
		13,
		repo.get_palette_color("mfd_text") * 0.92,
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"body_bold"
	)
	kit_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(kit_lbl)

	var desc_lbl: Label = DiegeticScreenFactory.make_crisp_label(
		desc_txt,
		13,
		repo.get_palette_color("mfd_muted").lightened(0.12),
		HORIZONTAL_ALIGNMENT_LEFT,
		false,
		2,
		repo,
		"body"
	)
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vbox.add_child(desc_lbl)

	var idx: int = action_buttons.size()
	var select_cb: Callable = func() -> void:
		if selected_chassis_id == cid:
			_emit_launch_selected_chassis()
		else:
			selected_chassis_id = cid
			chassis_preview_changed.emit(cid)
			rebuild_view()

	action_buttons.append({
		"button": btn,
		"normal_style": normal_style,
		"hover_style": hover_style,
		"callback": select_cb,
		"gear": start_gear,
		"boost": 0.72,
		"chassis_id": cid
	})

	btn.mouse_entered.connect(func() -> void:
		focused_index = idx
		_apply_focus_visuals()
		engine.sfx_requested.emit("switch_click", 0.36)
		if hgate_widget != null:
			hgate_widget.set_target_gear(start_gear)
		menu_hover_activity.emit(0.72, start_gear)
		chassis_preview_changed.emit(cid)
	)
	btn.pressed.connect(func() -> void:
		engine.sfx_requested.emit("rev_match" if selected_chassis_id == cid else "switch_click", 0.72)
		select_cb.call()
	)

	body_host.add_child(btn)

func _emit_launch_selected_chassis() -> void:
	var tour_sfx: String = ":tour" if guided_tour_requested else ""
	guided_tour_requested = false
	trigger_launch_flash()
	title_action_requested.emit("run:%s:0%s" % [selected_chassis_id, tour_sfx])

func _apply_focus_visuals() -> void:
	for i: int in range(action_buttons.size()):
		var entry: Dictionary = action_buttons[i]
		var btn: Button = entry["button"] as Button
		if btn == null or not is_instance_valid(btn):
			continue
		var st: StyleBoxFlat = (entry["hover_style"] if i == focused_index else entry["normal_style"]) as StyleBoxFlat
		btn.add_theme_stylebox_override("normal", st)

func handle_key_input(kev: InputEventKey) -> bool:
	if not is_menu_visible:
		return false
	if kev.keycode == KEY_ESCAPE:
		if current_view != VIEW_MAIN:
			guided_tour_requested = false
			_set_view(VIEW_MAIN)
			return true
		return false
	if kev.keycode == KEY_UP or kev.keycode == KEY_W:
		if not action_buttons.is_empty():
			focused_index = (focused_index - 1 + action_buttons.size()) % action_buttons.size()
			_on_keyboard_focus_moved()
		return true
	if kev.keycode == KEY_DOWN or kev.keycode == KEY_S:
		if not action_buttons.is_empty():
			focused_index = (focused_index + 1) % action_buttons.size()
			_on_keyboard_focus_moved()
		return true
	if kev.keycode == KEY_ENTER or kev.keycode == KEY_KP_ENTER or kev.keycode == KEY_SPACE:
		if current_view == VIEW_CHASSIS:
			_emit_launch_selected_chassis()
			return true
		if focused_index >= 0 and focused_index < action_buttons.size():
			var cb: Callable = action_buttons[focused_index].get("callback", Callable()) as Callable
			if cb.is_valid():
				engine.sfx_requested.emit("switch_click", 0.72)
				cb.call()
			return true
	if kev.keycode >= KEY_1 and kev.keycode <= KEY_9:
		var slot_i: int = int(kev.keycode - KEY_1)
		if slot_i >= 0 and slot_i < action_buttons.size():
			var cb_n: Callable = action_buttons[slot_i].get("callback", Callable()) as Callable
			if cb_n.is_valid():
				engine.sfx_requested.emit("switch_click", 0.72)
				cb_n.call()
			return true
	return false

func _on_keyboard_focus_moved() -> void:
	_apply_focus_visuals()
	engine.sfx_requested.emit("switch_click", 0.36)
	var entry: Dictionary = action_buttons[focused_index]
	var g_slot: int = int(entry.get("gear", 0))
	if hgate_widget != null:
		hgate_widget.set_target_gear(g_slot)
	menu_hover_activity.emit(float(entry.get("boost", 0.35)), g_slot)
	var cid: String = str(entry.get("chassis_id", ""))
	if not cid.is_empty():
		chassis_preview_changed.emit(cid)

func _process(delta: float) -> void:
	if flash_alpha > 0.0:
		var dur: float = maxf(0.1, float(_ui_cfg().get("transition_flash_duration_s", 0.32)))
		flash_alpha = maxf(0.0, flash_alpha - delta / dur)
		if flash_rect != null:
			flash_rect.color.a = flash_alpha
			flash_rect.visible = flash_alpha > 0.01
		if flash_alpha <= 0.01 and not is_menu_visible:
			set_process(false)
	if is_menu_visible and backdrop_canvas != null:
		backdrop_canvas.anim_time += delta
		backdrop_canvas.queue_redraw()
	if is_menu_visible and hgate_widget != null:
		hgate_widget.step_anim(delta)


class _MenuBackdropCanvas extends Control:
	var repo: GameRepository
	var vignette_ratio: float = 0.58
	var anim_time: float = 0.0

	func _draw() -> void:
		if repo == null:
			return
		var sz: Vector2 = size
		var bg: Color = repo.get_palette_color("mfd_bg")
		var acc: Color = repo.get_palette_color("mfd_accent")
		var scrim_w: float = sz.x * clampf(vignette_ratio, 0.35, 0.85)
		var steps: int = 64
		var step_w: float = scrim_w / float(steps)
		for i: int in range(steps):
			var frac: float = float(i) / float(steps)
			var alpha: float = pow(1.0 - frac, 1.65) * 0.86
			draw_rect(Rect2(float(i) * step_w, 0.0, step_w + 1.0, sz.y), Color(bg.r, bg.g, bg.b, alpha))

		draw_line(Vector2(18.0, 26.0), Vector2(18.0, sz.y - 26.0), Color(acc.r, acc.g, acc.b, 0.36), 2.0)
		var tick_y: float = 42.0
		var tick_idx: int = 0
		while tick_y < sz.y - 42.0:
			var t_len: float = 10.0 if (tick_idx % 4 == 0) else 5.0
			draw_line(Vector2(18.0, tick_y), Vector2(18.0 + t_len, tick_y), Color(acc.r, acc.g, acc.b, 0.42), 1.5)
			tick_y += 22.0
			tick_idx += 1

		var pulse_y: float = fmod(anim_time * 95.0, maxf(100.0, sz.y - 84.0)) + 42.0
		draw_circle(Vector2(18.0, pulse_y), 3.6, Color(acc.r, acc.g, acc.b, 0.82))

		var b_len: float = 22.0
		var b_col: Color = Color(acc.r, acc.g, acc.b, 0.55)
		draw_line(Vector2(sz.x - 24.0 - b_len, 24.0), Vector2(sz.x - 24.0, 24.0), b_col, 2.0)
		draw_line(Vector2(sz.x - 24.0, 24.0), Vector2(sz.x - 24.0, 24.0 + b_len), b_col, 2.0)
		draw_line(Vector2(sz.x - 24.0 - b_len, sz.y - 24.0), Vector2(sz.x - 24.0, sz.y - 24.0), b_col, 2.0)
		draw_line(Vector2(sz.x - 24.0, sz.y - 24.0 - b_len), Vector2(sz.x - 24.0, sz.y - 24.0), b_col, 2.0)


class _HGateMiniWidget extends Control:
	var repo: GameRepository
	var gear_coords: Dictionary = {}
	var target_gear: int = 0
	var knob_norm: Vector2 = Vector2(0.5, 0.5)
	var pulse_t: float = 0.0

	func set_target_gear(gear_idx: int) -> void:
		target_gear = gear_idx

	func step_anim(delta: float) -> void:
		pulse_t += delta
		var goal: Vector2 = _gear_norm(target_gear)
		knob_norm = knob_norm.lerp(goal, clampf(delta * 11.0, 0.0, 1.0))
		queue_redraw()

	func _gear_norm(g: int) -> Vector2:
		var key: String = str(g)
		if gear_coords.has(key):
			return JsonConfigLoader.to_vec2(gear_coords[key], Vector2(0.5, 0.5))
		return Vector2(0.5, 0.5)

	func _draw() -> void:
		if repo == null:
			return
		var sz: Vector2 = size
		var acc: Color = repo.get_palette_color("mfd_accent")
		var play: Color = repo.get_palette_color("playable_glow")
		var red: Color = repo.get_palette_color("redline_glow")
		var track_col: Color = Color(acc.r, acc.g, acc.b, 0.36)

		var pad_x: float = 14.0
		var pad_y: float = 16.0
		var inner_w: float = maxf(20.0, sz.x - pad_x * 2.0)
		var inner_h: float = maxf(20.0, sz.y - pad_y * 2.0)

		var mid_y: float = pad_y + inner_h * 0.5
		var c1_x: float = pad_x + inner_w * 0.22
		var c2_x: float = pad_x + inner_w * 0.50
		var c3_x: float = pad_x + inner_w * 0.78
		var top_y: float = pad_y + inner_h * 0.18
		var bot_y: float = pad_y + inner_h * 0.82

		draw_line(Vector2(c1_x, mid_y), Vector2(c3_x, mid_y), track_col, 3.0)
		draw_line(Vector2(c1_x, top_y), Vector2(c1_x, bot_y), track_col, 3.0)
		draw_line(Vector2(c2_x, top_y), Vector2(c2_x, bot_y), track_col, 3.0)
		draw_line(Vector2(c3_x, top_y), Vector2(c3_x, bot_y), track_col, 3.0)

		var fnt: Font = repo.get_font("mono")
		var labels: Dictionary = {1: "1", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 0: "N"}
		for gk: int in labels.keys():
			var gn: Vector2 = _gear_norm(gk)
			var gp: Vector2 = Vector2(pad_x + gn.x * inner_w, pad_y + gn.y * inner_h)
			var is_cur: bool = (gk == target_gear)
			var dot_col: Color = play if is_cur else Color(acc.r, acc.g, acc.b, 0.55)
			draw_circle(gp, 3.5 if is_cur else 2.2, dot_col)
			if fnt != null and gk != 0:
				draw_string(fnt, gp + Vector2(-4.0, -7.0 if gn.y < 0.5 else 15.0), str(labels[gk]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, dot_col)

		var kp: Vector2 = Vector2(pad_x + knob_norm.x * inner_w, pad_y + knob_norm.y * inner_h)
		var knob_col: Color = red if target_gear < 0 else (play if target_gear > 0 else acc)
		var ring_r: float = 9.0 + sin(pulse_t * 5.0) * 1.4
		draw_arc(kp, ring_r, 0.0, TAU, 24, Color(knob_col.r, knob_col.g, knob_col.b, 0.72), 2.0, true)
		draw_circle(kp, 5.5, knob_col.lightened(0.25))
