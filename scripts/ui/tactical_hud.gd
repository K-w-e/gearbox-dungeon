class_name TacticalHud
extends CanvasLayer

signal fullscreen_toggle_requested
signal pause_toggle_requested
signal guide_toggle_requested
signal quit_requested
signal tour_next_requested
signal tour_prev_requested
signal tour_skip_requested

var repo: GameRepository
var engine: CombatEngine
var draw_layer: Control
var reticle_dot: ColorRect
var dot_half: float = 2.5
var hud_time: float = 0.0

var tooltip_panel: PanelContainer
var tooltip_title_lbl: Label
var tooltip_desc_lbl: Label

var web_bar_layer: CanvasLayer
var web_bar: HBoxContainer
var web_guide_btn: Button
var web_fs_btn: Button
var web_pause_btn: Button
var web_quit_btn: Button

var tour_panel: PanelContainer
var tour_header_lbl: Label
var tour_keys_lbl: Label
var tour_body_lbl: Label
var tour_prev_btn: Button
var tour_next_btn: Button
var tour_skip_btn: Button
var tour_active: bool = false
var tour_primary_px: Vector2 = Vector2.ZERO
var tour_has_secondary: bool = false
var tour_secondary_px: Vector2 = Vector2.ZERO

var drag_active: bool = false
var drag_origin_px: Vector2 = Vector2.ZERO
var drag_cursor_px: Vector2 = Vector2.ZERO
var drag_ready: bool = false
var drag_blocked: bool = false
var drag_requires_enemy: bool = false
var activation_y_px: float = 450.0

func initialize(repository: GameRepository, combat_engine: CombatEngine = null) -> void:
	repo = repository
	engine = combat_engine
	layer = 10
	var hcfg: Dictionary = repo.cockpit.get("hud", {}) as Dictionary
	var dot_sz: float = maxf(2.0, float(hcfg.get("reticle_size_px", 5.0)))
	var dot_alpha: float = clampf(float(hcfg.get("reticle_alpha", 0.65)), 0.0, 1.0)
	dot_half = dot_sz * 0.5

	draw_layer = Control.new()
	draw_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	draw_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	draw_layer.draw.connect(_on_draw_overlay)
	add_child(draw_layer)

	var panel_bg: Color = repo.get_palette_color("mfd_bg")
	var brd_sel: Color = repo.get_palette_color("selected_glow")
	var col_play: Color = repo.get_palette_color("playable_glow")
	var col_red: Color = repo.get_palette_color("redline_glow")

	_build_tour_popup(panel_bg, brd_sel, col_play, col_red)
	_build_hover_tooltip(panel_bg, brd_sel)
	_build_web_quick_bar(panel_bg, brd_sel)

	reticle_dot = ColorRect.new()
	reticle_dot.custom_minimum_size = Vector2(dot_sz, dot_sz)
	reticle_dot.size = Vector2(dot_sz, dot_sz)
	var base_reticle: Color = repo.get_palette_color("selected_glow")
	reticle_dot.color = Color(base_reticle.r, base_reticle.g, base_reticle.b, dot_alpha)
	reticle_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(reticle_dot)

func _build_tour_popup(panel_bg: Color, brd_sel: Color, col_play: Color, col_red: Color) -> void:
	tour_panel = PanelContainer.new()
	tour_panel.visible = false
	var bg_op: Color = Color(panel_bg.r, panel_bg.g, panel_bg.b, 0.96)
	tour_panel.add_theme_stylebox_override("panel", DiegeticScreenFactory.make_panel_style(bg_op, col_play, 3, 6, 16.0, 12.0))
	add_child(tour_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	tour_panel.add_child(vbox)

	tour_header_lbl = Label.new()
	tour_header_lbl.add_theme_font_override("font", repo.get_font("display"))
	tour_header_lbl.add_theme_font_size_override("font_size", 18)
	tour_header_lbl.add_theme_color_override("font_color", col_play.lightened(0.20))
	tour_header_lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	tour_header_lbl.add_theme_constant_override("outline_size", 3)
	vbox.add_child(tour_header_lbl)

	var keys_box: PanelContainer = PanelContainer.new()
	keys_box.add_theme_stylebox_override(
		"panel",
		DiegeticScreenFactory.make_panel_style(Color(brd_sel.r * 0.18, brd_sel.g * 0.14, brd_sel.b * 0.06, 0.94), brd_sel, 2, 4, 10.0, 5.0)
	)
	vbox.add_child(keys_box)

	tour_keys_lbl = Label.new()
	tour_keys_lbl.add_theme_font_override("font", repo.get_font("display"))
	tour_keys_lbl.add_theme_font_size_override("font_size", 14)
	tour_keys_lbl.add_theme_color_override("font_color", brd_sel.lightened(0.25))
	tour_keys_lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	tour_keys_lbl.add_theme_constant_override("outline_size", 2)
	keys_box.add_child(tour_keys_lbl)

	tour_body_lbl = Label.new()
	tour_body_lbl.custom_minimum_size = Vector2(456.0, 0.0)
	tour_body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tour_body_lbl.add_theme_font_override("font", repo.get_font("body_bold"))
	tour_body_lbl.add_theme_font_size_override("font_size", 16)
	tour_body_lbl.add_theme_color_override("font_color", repo.get_palette_color("mfd_text"))
	tour_body_lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	tour_body_lbl.add_theme_constant_override("outline_size", 2)
	vbox.add_child(tour_body_lbl)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	tour_prev_btn = _make_hud_button(repo.get_ui_text("combat", "tour_prev_btn"), panel_bg.lightened(0.06), brd_sel * 0.85)
	tour_prev_btn.add_theme_font_size_override("font_size", 14)
	tour_prev_btn.focus_mode = Control.FOCUS_NONE
	tour_prev_btn.pressed.connect(func() -> void: tour_prev_requested.emit())
	btn_row.add_child(tour_prev_btn)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)

	tour_skip_btn = _make_hud_button(repo.get_ui_text("combat", "tour_skip_btn"), col_red.darkened(0.72), col_red * 0.90)
	tour_skip_btn.add_theme_font_size_override("font_size", 14)
	tour_skip_btn.focus_mode = Control.FOCUS_NONE
	tour_skip_btn.pressed.connect(func() -> void: tour_skip_requested.emit())
	btn_row.add_child(tour_skip_btn)

	tour_next_btn = _make_hud_button(repo.get_ui_text("combat", "tour_next_btn"), col_play.darkened(0.66), col_play)
	tour_next_btn.add_theme_font_size_override("font_size", 15)
	tour_next_btn.focus_mode = Control.FOCUS_NONE
	tour_next_btn.pressed.connect(func() -> void: tour_next_requested.emit())
	btn_row.add_child(tour_next_btn)

func show_tour_callout(step_data: Dictionary, index: int, total: int) -> void:
	if tour_panel == null or step_data.is_empty() or index < 0 or total <= 0:
		hide_tour_callout()
		return
	tour_active = true
	tour_header_lbl.text = repo.get_ui_text("combat", "tour_header_fmt") % [index + 1, total, str(step_data.get("title", ""))]
	tour_keys_lbl.text = str(step_data.get("keys", ""))
	tour_body_lbl.text = str(step_data.get("body", ""))
	tour_prev_btn.visible = (index > 0)
	var is_last: bool = (index >= total - 1)
	tour_next_btn.text = repo.get_ui_text("combat", "tour_done_btn" if is_last else "tour_next_btn")
	tour_panel.visible = true
	tour_panel.reset_size()
	draw_layer.queue_redraw()

func update_tour_targets(primary_px: Vector2, has_secondary: bool = false, secondary_px: Vector2 = Vector2.ZERO) -> void:
	if not tour_active or tour_panel == null:
		return
	tour_primary_px = primary_px
	tour_has_secondary = has_secondary
	tour_secondary_px = secondary_px
	if get_viewport() != null:
		var vp_sz: Vector2 = get_viewport().get_visible_rect().size
		var p_sz: Vector2 = tour_panel.size
		var max_w: float = maxf(320.0, vp_sz.x - 36.0)
		if tour_body_lbl != null:
			var target_min_w: float = minf(456.0, max_w - 36.0)
			if absf(tour_body_lbl.custom_minimum_size.x - target_min_w) > 2.0:
				tour_body_lbl.custom_minimum_size.x = target_min_w
				tour_panel.reset_size()
				p_sz = tour_panel.size
		var place_above: bool = (primary_px.y > vp_sz.y * 0.50)
		var clearance: float = 76.0
		var py: float = (primary_px.y - p_sz.y - clearance) if place_above else (primary_px.y + clearance)
		py = clampf(py, 48.0, maxf(48.0, vp_sz.y - p_sz.y - 18.0))
		var px: float = clampf(primary_px.x - p_sz.x * 0.5, 18.0, maxf(18.0, vp_sz.x - p_sz.x - 18.0))
		tour_panel.position = Vector2(px, py)
	draw_layer.queue_redraw()

func hide_tour_callout() -> void:
	if not tour_active and (tour_panel == null or not tour_panel.visible):
		return
	tour_active = false
	tour_has_secondary = false
	if tour_panel != null:
		tour_panel.visible = false
	if draw_layer != null:
		draw_layer.queue_redraw()

func _build_hover_tooltip(panel_bg: Color, brd_sel: Color) -> void:
	tooltip_panel = PanelContainer.new()
	tooltip_panel.visible = false
	tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_op: Color = Color(panel_bg.r, panel_bg.g, panel_bg.b, 0.95)
	tooltip_panel.add_theme_stylebox_override("panel", DiegeticScreenFactory.make_panel_style(bg_op, brd_sel, 2, 4, 10.0, 6.0))
	add_child(tooltip_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip_panel.add_child(vbox)

	tooltip_title_lbl = Label.new()
	tooltip_title_lbl.add_theme_font_override("font", repo.get_font("display"))
	tooltip_title_lbl.add_theme_font_size_override("font_size", 15)
	tooltip_title_lbl.add_theme_color_override("font_color", brd_sel)
	tooltip_title_lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	tooltip_title_lbl.add_theme_constant_override("outline_size", 2)
	vbox.add_child(tooltip_title_lbl)

	tooltip_desc_lbl = Label.new()
	tooltip_desc_lbl.add_theme_font_override("font", repo.get_font("body_bold"))
	tooltip_desc_lbl.add_theme_font_size_override("font_size", 14)
	tooltip_desc_lbl.add_theme_color_override("font_color", repo.get_palette_color("mfd_text"))
	tooltip_desc_lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	tooltip_desc_lbl.add_theme_constant_override("outline_size", 2)
	vbox.add_child(tooltip_desc_lbl)

func show_item_tooltip(cursor_px: Vector2, title: String, desc: String, accent_col: Color) -> void:
	if tooltip_panel == null or title.is_empty():
		hide_item_tooltip()
		return
	var panel_bg: Color = repo.get_palette_color("mfd_bg")
	var bg_op: Color = Color(panel_bg.r, panel_bg.g, panel_bg.b, 0.95)
	tooltip_panel.add_theme_stylebox_override("panel", DiegeticScreenFactory.make_panel_style(bg_op, accent_col, 2, 4, 10.0, 6.0))
	tooltip_title_lbl.text = title
	tooltip_title_lbl.add_theme_color_override("font_color", accent_col.lightened(0.22))
	tooltip_desc_lbl.text = desc
	tooltip_panel.visible = true
	tooltip_panel.reset_size()
	if get_viewport() != null:
		var vp_sz: Vector2 = get_viewport().get_visible_rect().size
		var tx: float = clampf(cursor_px.x - tooltip_panel.size.x * 0.5, 12.0, maxf(12.0, vp_sz.x - tooltip_panel.size.x - 12.0))
		var ty: float = clampf(cursor_px.y + 18.0, 12.0, maxf(12.0, vp_sz.y - tooltip_panel.size.y - 12.0))
		tooltip_panel.position = Vector2(tx, ty)

func hide_item_tooltip() -> void:
	if tooltip_panel != null:
		tooltip_panel.visible = false

func _build_web_quick_bar(panel_bg: Color, brd_sel: Color) -> void:
	web_bar_layer = CanvasLayer.new()
	web_bar_layer.layer = 15
	add_child(web_bar_layer)

	web_bar = HBoxContainer.new()
	web_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	web_bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	web_bar.offset_top = 10.0
	web_bar.offset_right = -12.0
	web_bar.add_theme_constant_override("separation", 6)
	web_bar_layer.add_child(web_bar)

	web_guide_btn = _make_hud_button("[H] GUIDE", panel_bg.darkened(0.15), brd_sel * 0.80)
	web_guide_btn.add_theme_font_size_override("font_size", 13)
	web_guide_btn.focus_mode = Control.FOCUS_NONE
	web_guide_btn.visible = false
	web_guide_btn.pressed.connect(func() -> void: guide_toggle_requested.emit())
	web_bar.add_child(web_guide_btn)

	web_pause_btn = _make_hud_button("[P] PAUSE", panel_bg.darkened(0.15), brd_sel * 0.80)
	web_pause_btn.add_theme_font_size_override("font_size", 13)
	web_pause_btn.focus_mode = Control.FOCUS_NONE
	web_pause_btn.visible = false
	web_pause_btn.pressed.connect(func() -> void: pause_toggle_requested.emit())
	web_bar.add_child(web_pause_btn)

	web_fs_btn = _make_hud_button(repo.get_ui_text("terminal", "hud_btn_fullscreen"), panel_bg.darkened(0.15), brd_sel * 0.80)
	web_fs_btn.add_theme_font_size_override("font_size", 13)
	web_fs_btn.focus_mode = Control.FOCUS_NONE
	web_fs_btn.pressed.connect(func() -> void: fullscreen_toggle_requested.emit())
	web_bar.add_child(web_fs_btn)

	var col_red: Color = repo.get_palette_color("redline_glow")
	web_quit_btn = _make_hud_button(repo.get_ui_text("terminal", "hud_btn_quit"), Color(col_red.r * 0.22, col_red.g * 0.08, col_red.b * 0.08, 0.96), col_red * 0.92)
	web_quit_btn.add_theme_font_size_override("font_size", 13)
	web_quit_btn.focus_mode = Control.FOCUS_NONE
	web_quit_btn.visible = not OS.has_feature("web")
	web_quit_btn.pressed.connect(func() -> void: quit_requested.emit())
	web_bar.add_child(web_quit_btn)

func sync_web_bar_state(is_fullscreen: bool, can_pause: bool, in_combat: bool = false) -> void:
	if web_fs_btn != null:
		web_fs_btn.text = repo.get_ui_text("terminal", "hud_btn_exit_fullscreen" if is_fullscreen else "hud_btn_fullscreen")
	if web_pause_btn != null:
		web_pause_btn.visible = can_pause
	if web_guide_btn != null:
		web_guide_btn.visible = in_combat
	if web_quit_btn != null:
		web_quit_btn.visible = not OS.has_feature("web")

func _make_hud_button(text: String, bg: Color, brd: Color) -> Button:
	var btn: Button = Button.new()
	btn.text = text
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_override("font", repo.get_font("display"))
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", repo.get_palette_color("mfd_text"))
	btn.add_theme_color_override("font_outline_color", repo.get_outline_color())
	btn.add_theme_constant_override("outline_size", 2)
	var bg_opaque: Color = Color(bg.r, bg.g, bg.b, 0.96)
	btn.add_theme_stylebox_override("normal", DiegeticScreenFactory.make_panel_style(bg_opaque, brd, 2, 4, 14.0, 7.0))
	btn.add_theme_stylebox_override("hover", DiegeticScreenFactory.make_panel_style(bg_opaque.lightened(0.16), repo.get_palette_color("mfd_text"), 2, 4, 14.0, 7.0))
	btn.add_theme_stylebox_override("pressed", DiegeticScreenFactory.make_panel_style(bg_opaque.darkened(0.15), brd, 2, 4, 14.0, 7.0))
	return btn

func set_reticle_highlighted(active: bool) -> void:
	if reticle_dot == null or repo == null:
		return
	var hi_col: Color = repo.get_palette_color("playable_glow")
	var idle_col: Color = repo.get_palette_color("selected_glow")
	reticle_dot.color = Color(hi_col.r, hi_col.g, hi_col.b, 0.88) if active else Color(idle_col.r, idle_col.g, idle_col.b, 0.48)

func show_drag_feedback(origin_px: Vector2, cursor_px: Vector2, act_y: float, is_ready: bool, is_blocked: bool, needs_enemy: bool) -> void:
	drag_active = true
	drag_origin_px = origin_px
	drag_cursor_px = cursor_px
	activation_y_px = act_y
	drag_ready = is_ready
	drag_blocked = is_blocked
	drag_requires_enemy = needs_enemy
	draw_layer.queue_redraw()

func clear_drag_feedback() -> void:
	if not drag_active:
		return
	drag_active = false
	draw_layer.queue_redraw()

func _draw_target_beacon(center: Vector2, radius: float, col: Color, pulse: float) -> void:
	var r_outer: float = radius + pulse * 6.0
	draw_layer.draw_circle(center, r_outer, Color(col.r, col.g, col.b, 0.12))
	draw_layer.draw_arc(center, r_outer, 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.92), 3.0, true)
	draw_layer.draw_arc(center, radius * 0.62, 0.0, TAU, 24, Color(1.0, 1.0, 1.0, 0.78), 1.8, true)
	for dir_v: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_layer.draw_line(center + dir_v * (r_outer - 5.0), center + dir_v * (r_outer + 9.0), col.lightened(0.25), 2.5, true)

func _on_draw_overlay() -> void:
	if repo == null:
		return
	var c_play: Color = repo.get_palette_color("playable_glow")
	var c_red: Color = repo.get_palette_color("redline_glow")
	var c_sel: Color = repo.get_palette_color("selected_glow")

	if tour_active and tour_panel != null and tour_panel.visible:
		var pulse: float = 0.5 + 0.5 * sin(hud_time * 6.5)
		_draw_target_beacon(tour_primary_px, 34.0, c_play, pulse)
		if tour_has_secondary:
			_draw_target_beacon(tour_secondary_px, 28.0, c_sel, pulse)
		var p_rect: Rect2 = Rect2(tour_panel.position, tour_panel.size)
		var anchor_x: float = clampf(tour_primary_px.x, p_rect.position.x + 28.0, p_rect.end.x - 28.0)
		var anchor_y: float = p_rect.end.y if (tour_primary_px.y >= p_rect.get_center().y) else p_rect.position.y
		var anchor_pt: Vector2 = Vector2(anchor_x, anchor_y)
		var to_target: Vector2 = tour_primary_px - anchor_pt
		var dist: float = to_target.length()
		if dist > 42.0:
			var ring_edge: Vector2 = tour_primary_px - (to_target / dist) * (36.0 + pulse * 6.0)
			draw_layer.draw_line(anchor_pt, ring_edge, Color(0.0, 0.0, 0.0, 0.72), 6.0, true)
			draw_layer.draw_line(anchor_pt, ring_edge, c_play.lightened(0.18), 3.0, true)
			draw_layer.draw_circle(anchor_pt, 5.5, c_play.lightened(0.25))

	if not drag_active:
		return
	var hcfg: Dictionary = repo.cockpit.get("hud", {}) as Dictionary
	var segs: int = maxi(8, int(hcfg.get("arc_segments", 24)))
	var width_px: float = maxf(2.0, float(hcfg.get("arc_width_px", 4.0)))
	var col: Color = c_red if drag_blocked else (c_play if drag_ready else c_sel)

	if not drag_requires_enemy and not drag_blocked and get_viewport() != null:
		var vp_w: float = get_viewport().get_visible_rect().size.x
		var line_col: Color = Color(col.r, col.g, col.b, 0.55 if drag_ready else 0.32)
		var dash_w: float = 22.0
		var gap_w: float = 14.0
		var x: float = 120.0
		while x < vp_w - 120.0:
			draw_layer.draw_line(Vector2(x, activation_y_px), Vector2(minf(x + dash_w, vp_w - 120.0), activation_y_px), line_col, 2.5)
			x += dash_w + gap_w

	var p0: Vector2 = drag_origin_px
	var p2: Vector2 = drag_cursor_px
	var mid: Vector2 = (p0 + p2) * 0.5 + Vector2(0.0, -90.0)
	var prev: Vector2 = p0
	for i: int in range(1, segs + 1):
		var t: float = float(i) / float(segs)
		var omt: float = 1.0 - t
		var pt: Vector2 = omt * omt * p0 + 2.0 * omt * t * mid + t * t * p2
		if i % 2 == 1:
			draw_layer.draw_line(prev, pt, col, width_px, true)
		prev = pt

	draw_layer.draw_arc(p2, 16.0, 0.0, TAU, 24, col, 3.0, true)
	draw_layer.draw_circle(p2, 4.5, col)

func _process(delta: float) -> void:
	hud_time += delta
	if reticle_dot != null and get_viewport() != null:
		var mp: Vector2 = get_viewport().get_mouse_position()
		reticle_dot.position = mp - Vector2(dot_half, dot_half)
	if tour_active and draw_layer != null:
		draw_layer.queue_redraw()
