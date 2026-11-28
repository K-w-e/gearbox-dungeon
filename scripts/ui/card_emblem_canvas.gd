class_name CardEmblemCanvas
extends Control

var icon_id: String = ""
var primary_color: Color = Color.WHITE
var active_state: bool = true

var repo: GameRepository = null
var engine: CombatEngine = null
var card_data: Dictionary = {}
var shortcut_badge: String = ""
var footer_text: String = ""
var footer_color: Color = Color.WHITE
var is_card_highlighted: bool = false
var full_cartridge_mode: bool = false
var last_render_sig: String = ""

func invalidate_cache() -> void:
	last_render_sig = ""

func _compute_render_sig() -> String:
	if not full_cartridge_mode or repo == null or engine == null or card_data.is_empty():
		return "emb|%s|%d|%d" % [icon_id, primary_color.to_rgba32(), 1 if active_state else 0]
	var eval_gear: int = engine.effective_gear()
	var in_red: bool = engine.transmission.is_redline(eval_gear, engine.rpm_units)
	var prev: Dictionary = engine.calculate_card_preview(card_data)
	return "%s|%s|%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%d|%d" % [
		str(card_data.get("id", "")),
		shortcut_badge,
		1 if active_state else 0,
		engine.mode,
		eval_gear,
		1 if in_red else 0,
		engine.heat,
		engine.shifts_this_turn,
		int(prev.get("damage", 0)),
		int(prev.get("hits", 1)),
		int(prev.get("block", 0)),
		int(prev.get("rpm_delta_units", 0)),
		int(prev.get("upgrade_level", 0)),
		footer_text,
		footer_color.to_rgba32(),
		1 if is_card_highlighted else 0
	]

func configure(new_icon_id: String, accent_color: Color, is_playable: bool) -> void:
	full_cartridge_mode = false
	icon_id = new_icon_id
	primary_color = accent_color
	active_state = is_playable
	var sig: String = _compute_render_sig()
	if sig == last_render_sig:
		return
	last_render_sig = sig
	DiegeticScreenFactory.request_redraw(self)

func configure_full_card(repository: GameRepository, combat_engine: CombatEngine, card: Dictionary, key_txt: String, playable: bool, f_txt: String, f_col: Color, highlighted: bool = false) -> void:
	full_cartridge_mode = true
	repo = repository
	engine = combat_engine
	card_data = card
	shortcut_badge = key_txt
	active_state = playable
	footer_text = f_txt
	footer_color = f_col
	is_card_highlighted = highlighted
	var sig: String = _compute_render_sig()
	if sig == last_render_sig:
		return
	last_render_sig = sig
	DiegeticScreenFactory.request_redraw(self)

func update_footer(f_txt: String, f_col: Color, highlighted: bool = false) -> void:
	if footer_text == f_txt and footer_color == f_col and is_card_highlighted == highlighted:
		return
	footer_text = f_txt
	footer_color = f_col
	is_card_highlighted = highlighted
	var sig: String = _compute_render_sig()
	if sig == last_render_sig:
		return
	last_render_sig = sig
	DiegeticScreenFactory.request_redraw(self)

func _draw() -> void:
	if full_cartridge_mode and repo != null and engine != null and not card_data.is_empty():
		draw_full_card_cartridge(
			self,
			Rect2(Vector2.ZERO, size),
			repo,
			engine,
			card_data,
			shortcut_badge,
			active_state,
			footer_text,
			footer_color,
			is_card_highlighted
		)
		return
	draw_card_emblem(self, Rect2(Vector2.ZERO, size), icon_id, primary_color, active_state)

static func make_chamfer_poly(rect: Rect2, cut_tl: float, cut_tr: float, cut_br: float, cut_bl: float) -> PackedVector2Array:
	var max_c: float = maxf(0.5, minf(rect.size.x, rect.size.y) * 0.45)
	var ctl: float = minf(cut_tl, max_c)
	var ctr: float = minf(cut_tr, max_c)
	var cbr: float = minf(cut_br, max_c)
	var cbl: float = minf(cut_bl, max_c)
	var x0: float = rect.position.x
	var y0: float = rect.position.y
	var x1: float = rect.end.x
	var y1: float = rect.end.y
	return PackedVector2Array([
		Vector2(x0 + ctl, y0),
		Vector2(x1 - ctr, y0),
		Vector2(x1, y0 + ctr),
		Vector2(x1, y1 - cbr),
		Vector2(x1 - cbr, y1),
		Vector2(x0 + cbl, y1),
		Vector2(x0, y1 - cbl),
		Vector2(x0, y0 + ctl)
	])

static func draw_chamfer_plate(canvas: CanvasItem, rect: Rect2, cut: float, fill_col: Color, border_col: Color, border_w: float = 2.5, bolts: bool = false) -> void:
	var poly: PackedVector2Array = make_chamfer_poly(rect, cut, cut, cut, cut)
	canvas.draw_colored_polygon(poly, fill_col)
	var closed: PackedVector2Array = poly.duplicate()
	closed.append(poly[0])
	canvas.draw_polyline(closed, border_col, border_w, true)
	if bolts:
		var b_off: float = maxf(6.0, cut * 0.72)
		var bolt_col: Color = border_col.lightened(0.22)
		var pts: Array[Vector2] = [
			rect.position + Vector2(b_off, b_off),
			Vector2(rect.end.x - b_off, rect.position.y + b_off),
			rect.end - Vector2(b_off, b_off),
			Vector2(rect.position.x + b_off, rect.end.y - b_off)
		]
		for pt: Vector2 in pts:
			canvas.draw_circle(pt, 3.2, Color(0.06, 0.05, 0.04, 0.95))
			canvas.draw_arc(pt, 3.2, 0.0, TAU, 8, bolt_col, 1.4, true)

static func draw_full_card_cartridge(
	canvas: CanvasItem,
	rect: Rect2,
	repository: GameRepository,
	combat_engine: CombatEngine,
	card: Dictionary,
	shortcut_text: String,
	playable: bool,
	f_text: String,
	f_col: Color,
	is_highlighted: bool,
	price_tag: String = "",
	on_sale: bool = false,
	is_sold: bool = false,
	bonus_upgrade_level: int = 0
) -> void:
	if rect.size.x < 80.0 or rect.size.y < 110.0 or repository == null or combat_engine == null:
		return
	var f_disp: Font = repository.get_font("display")
	var f_body: Font = repository.get_font("body_bold")
	var out_col: Color = repository.get_outline_color()
	var txt_col: Color = repository.get_palette_color("mfd_text")
	var dis_col: Color = repository.get_palette_color("disabled_tint")
	var mfd_bg: Color = repository.get_palette_color("mfd_bg")
	var panel_bg: Color = repository.get_palette_color("mfd_panel_bg")
	var brd_base: Color = repository.get_palette_color("mfd_border")

	var scale_f: float = clampf(rect.size.x / 340.0, 0.52, 1.25)
	var cat: String = str(card.get("category", "Utility"))
	var cat_col: Color = repository.get_category_color(cat)
	var c_play: Color = repository.get_palette_color("playable_glow")
	var c_sel: Color = repository.get_palette_color("selected_glow")
	var c_red: Color = repository.get_palette_color("redline_glow")

	var outer_rect: Rect2 = rect.grow(-3.0 * scale_f)
	var cut: float = 16.0 * scale_f
	var body_bg: Color = panel_bg if playable else mfd_bg
	var rim_col: Color = c_sel if is_highlighted else (c_play if playable else dis_col)
	if on_sale and not is_sold:
		rim_col = txt_col if is_highlighted else c_sel

	draw_chamfer_plate(canvas, outer_rect, cut, body_bg, rim_col, (3.8 if (playable or is_highlighted) else 2.4) * scale_f, true)

	var stripe_col: Color = Color(cat_col.r, cat_col.g, cat_col.b, 0.08 if playable else 0.03)
	for s: int in range(6):
		var sy: float = outer_rect.position.y + 36.0 * scale_f + float(s) * 78.0 * scale_f
		if sy + 24.0 * scale_f < outer_rect.end.y:
			canvas.draw_line(
				Vector2(outer_rect.position.x + 10.0 * scale_f, sy),
				Vector2(outer_rect.end.x - 10.0 * scale_f, sy - 18.0 * scale_f),
				stripe_col,
				2.0 * scale_f
			)

	var grip_col: Color = Color(rim_col.r, rim_col.g, rim_col.b, 0.55)
	for g: int in range(4):
		var gy: float = outer_rect.position.y + outer_rect.size.y * 0.44 + float(g) * 11.0 * scale_f
		canvas.draw_line(Vector2(outer_rect.position.x + 2.0, gy), Vector2(outer_rect.position.x + 8.0 * scale_f, gy), grip_col, 2.2 * scale_f)
		canvas.draw_line(Vector2(outer_rect.end.x - 8.0 * scale_f, gy), Vector2(outer_rect.end.x - 2.0, gy), grip_col, 2.2 * scale_f)

	var pad: float = 10.0 * scale_f
	var inner_x: float = outer_rect.position.x + pad
	var inner_w: float = outer_rect.size.x - pad * 2.0
	var cur_y: float = outer_rect.position.y + pad

	var in_combat_ctx: bool = (combat_engine.mode == CombatEngine.MODE_COMBAT or combat_engine.mode == CombatEngine.MODE_ENEMY_TURN)
	var allowed: Array = card.get("allowed_gears", []) as Array
	var eval_gear: int = combat_engine.effective_gear() if combat_engine.has_method("effective_gear") else combat_engine.current_gear
	var gear_compatible: bool = CardEffectFormatter.contains_gear(allowed, eval_gear) if in_combat_ctx else true

	var hdr_h: float = 54.0 * scale_f
	var hdr_rect: Rect2 = Rect2(inner_x, cur_y, inner_w, hdr_h)
	var hdr_fill: Color = (cat_col * 0.84) if playable else (cat_col * 0.36)
	hdr_fill.a = 0.98
	var hdr_brd: Color = cat_col.lightened(0.42) if playable else (cat_col * 0.72)
	draw_chamfer_plate(canvas, hdr_rect, 9.0 * scale_f, hdr_fill, hdr_brd, 2.4 * scale_f, false)

	var visual_model: Dictionary = CardEffectFormatter.build_card_visual_model(repository, combat_engine, card, bonus_upgrade_level)
	var upg_lvl: int = int(visual_model.get("upgrade_level", 0))

	var badge_c: Vector2 = Vector2(hdr_rect.position.x + 25.0 * scale_f, hdr_rect.position.y + hdr_h * 0.5)
	var badge_r: float = 17.5 * scale_f
	canvas.draw_circle(badge_c, badge_r, mfd_bg)
	canvas.draw_arc(badge_c, badge_r, 0.0, TAU, 20, hdr_brd, 2.2 * scale_f, true)
	draw_category_icon(
		canvas,
		badge_c,
		badge_r * 0.76,
		cat,
		cat_col.lightened(0.48) if playable else cat_col.lightened(0.22),
		Color(cat_col.r, cat_col.g, cat_col.b, 0.35 if playable else 0.18)
	)

	var right_tag: String = shortcut_text if not shortcut_text.is_empty() else (("+%d" % upg_lvl) if upg_lvl > 0 else "")
	var has_right_tag: bool = not right_tag.is_empty()
	var key_reserve: float = (40.0 * scale_f) if has_right_tag else (8.0 * scale_f)
	var title_x: float = hdr_rect.position.x + 48.0 * scale_f
	var title_w: float = maxf(40.0, hdr_rect.size.x - 50.0 * scale_f - key_reserve)
	var title_str: String = str(card.get("name", "")).to_upper()
	var max_t_sz: int = maxi(16, roundi(25.0 * scale_f))
	var min_t_sz: int = maxi(12, roundi(14.0 * scale_f))
	DiegeticScreenFactory.draw_fitted_text(
		canvas,
		f_disp,
		Vector2(title_x, hdr_rect.position.y + hdr_h * 0.66),
		title_str,
		HORIZONTAL_ALIGNMENT_CENTER,
		title_w,
		max_t_sz,
		txt_col if playable else dis_col.lightened(0.32),
		out_col,
		maxi(2, roundi(3.5 * scale_f)),
		min_t_sz
	)

	if has_right_tag:
		var kw: float = 34.0 * scale_f
		var kh: float = 28.0 * scale_f
		var kr: Rect2 = Rect2(hdr_rect.end.x - kw - 6.0 * scale_f, hdr_rect.position.y + (hdr_h - kh) * 0.5, kw, kh)
		var tag_brd: Color = c_sel if shortcut_text.is_empty() else hdr_brd
		draw_chamfer_plate(canvas, kr, 4.0 * scale_f, mfd_bg, tag_brd, 1.8 * scale_f, false)
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(kr.position.x, kr.position.y + kh * 0.72),
			right_tag,
			HORIZONTAL_ALIGNMENT_CENTER,
			kr.size.x,
			maxi(11, roundi(16.0 * scale_f)),
			c_sel.lightened(0.24) if shortcut_text.is_empty() else txt_col,
			out_col,
			2,
			9
		)

	cur_y += hdr_h + 7.0 * scale_f

	var gear_strip_h: float = 36.0 * scale_f
	var gear_strip_r: Rect2 = Rect2(inner_x, cur_y, inner_w, gear_strip_h)
	_draw_card_gear_strip(canvas, gear_strip_r, allowed, eval_gear, in_combat_ctx, gear_compatible, scale_f, repository)

	cur_y += gear_strip_h + 7.0 * scale_f

	var has_price: bool = not price_tag.is_empty()
	var show_footer: bool = has_price or not f_text.is_empty()
	var footer_h: float = (36.0 * scale_f) if show_footer else 0.0
	var chips: Array[Dictionary] = visual_model.get("chips", []) as Array[Dictionary]
	var chip_rows: int = 0 if chips.is_empty() else (1 if chips.size() <= 2 else (2 if chips.size() <= 4 else 3))
	var chip_area_h: float = (float(chip_rows) * 48.0 * scale_f + 12.0 * scale_f) if chip_rows > 0 else 0.0
	var bottom_reserved: float = pad + footer_h + (6.0 * scale_f if show_footer else 0.0) + chip_area_h + (7.0 * scale_f if chip_rows > 0 else 0.0)
	var hero_h: float = maxf(116.0 * scale_f, outer_rect.end.y - bottom_reserved - cur_y)
	var hero_rect: Rect2 = Rect2(inner_x, cur_y, inner_w, hero_h)
	var hero_data: Dictionary = visual_model.get("hero", {}) as Dictionary
	_draw_card_hero_panel(canvas, hero_rect, hero_data, cat_col, playable, scale_f, repository)

	cur_y += hero_h + 7.0 * scale_f

	if chip_rows > 0:
		var chips_rect: Rect2 = Rect2(inner_x, cur_y, inner_w, maxf(46.0 * scale_f, outer_rect.end.y - pad - footer_h - (6.0 * scale_f if show_footer else 0.0) - cur_y))
		_draw_card_chip_grid(canvas, chips_rect, chips, playable, scale_f, repository)

	if show_footer:
		var bmp_rect: Rect2 = Rect2(inner_x, outer_rect.end.y - pad - footer_h, inner_w, footer_h)
		var bmp_txt: String = price_tag if has_price else f_text
		var bmp_col: Color = c_sel if on_sale else f_col
		var bmp_bg: Color = Color(bmp_col.r * 0.22, bmp_col.g * 0.14, bmp_col.b * 0.08, 0.96)
		draw_chamfer_plate(canvas, bmp_rect, 7.0 * scale_f, bmp_bg, bmp_col * 0.94, 2.2 * scale_f, false)

		var f_sz: int = maxi(14, roundi(21.0 * scale_f))
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_body,
			Vector2(bmp_rect.position.x + 6.0 * scale_f, bmp_rect.position.y + footer_h * 0.68),
			bmp_txt,
			HORIZONTAL_ALIGNMENT_CENTER,
			bmp_rect.size.x - 12.0 * scale_f,
			f_sz,
			bmp_col.lightened(0.32),
			out_col,
			maxi(2, roundi(3.0 * scale_f)),
			12
		)

	if on_sale and not is_sold:
		var sale_rect: Rect2 = Rect2(outer_rect.end.x - 114.0 * scale_f, outer_rect.position.y + 72.0 * scale_f, 102.0 * scale_f, 24.0 * scale_f)
		draw_chamfer_plate(canvas, sale_rect, 5.0 * scale_f, Color(c_red.r * 0.85, c_red.g * 0.25, c_red.b * 0.14, 0.98), c_sel, 2.0 * scale_f, false)
		var s_sz: int = maxi(9, roundi(13.0 * scale_f))
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(sale_rect.position.x + 4.0, sale_rect.position.y + 17.0 * scale_f),
			repository.get_ui_text("terminal", "shop_sale_tag"),
			HORIZONTAL_ALIGNMENT_CENTER,
			sale_rect.size.x - 8.0,
			s_sz,
			txt_col,
			out_col,
			2,
			8
		)
	elif bonus_upgrade_level > 0 and not is_sold:
		var tune_rect: Rect2 = Rect2(outer_rect.end.x - 126.0 * scale_f, outer_rect.position.y + 72.0 * scale_f, 114.0 * scale_f, 24.0 * scale_f)
		draw_chamfer_plate(canvas, tune_rect, 5.0 * scale_f, Color(c_play.r * 0.22, c_play.g * 0.34, c_play.b * 0.14, 0.98), c_sel, 2.0 * scale_f, false)
		var t_sz: int = maxi(9, roundi(13.0 * scale_f))
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(tune_rect.position.x + 4.0, tune_rect.position.y + 17.0 * scale_f),
			repository.get_ui_text("hud", "reward_pre_upgraded_tag"),
			HORIZONTAL_ALIGNMENT_CENTER,
			tune_rect.size.x - 8.0,
			t_sz,
			c_sel.lightened(0.25),
			out_col,
			2,
			8
		)

	if is_sold:
		var shutter: PackedVector2Array = make_chamfer_poly(outer_rect, cut, cut, cut, cut)
		canvas.draw_colored_polygon(shutter, Color(mfd_bg.r, mfd_bg.g, mfd_bg.b, 0.84))
		var stamp_r: Rect2 = Rect2(outer_rect.position.x + 24.0 * scale_f, outer_rect.position.y + outer_rect.size.y * 0.44, outer_rect.size.x - 48.0 * scale_f, 44.0 * scale_f)
		draw_chamfer_plate(canvas, stamp_r, 8.0 * scale_f, Color(c_red.r * 0.22, c_red.g * 0.08, c_red.b * 0.06, 0.96), c_red, 2.5 * scale_f, false)
		var st_sz: int = maxi(12, roundi(20.0 * scale_f))
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(stamp_r.position.x + 6.0, stamp_r.position.y + 30.0 * scale_f),
			repository.get_ui_text("terminal", "shop_installed"),
			HORIZONTAL_ALIGNMENT_CENTER,
			stamp_r.size.x - 12.0,
			st_sz,
			c_red.lightened(0.28),
			out_col,
			3,
			10
		)

static func _draw_card_gear_strip(
	canvas: CanvasItem,
	rect: Rect2,
	allowed: Array,
	eval_gear: int,
	in_combat_ctx: bool,
	gear_compatible: bool,
	scale_f: float,
	repository: GameRepository
) -> void:
	var f_disp: Font = repository.get_font("display")
	var out_col: Color = repository.get_outline_color()
	var mfd_bg: Color = repository.get_palette_color("mfd_bg")
	var txt_col: Color = repository.get_palette_color("mfd_text")
	var muted_col: Color = repository.get_palette_color("mfd_muted")
	var c_play: Color = repository.get_palette_color("playable_glow")
	var c_sel: Color = repository.get_palette_color("selected_glow")
	var c_red: Color = repository.get_palette_color("redline_glow")

	var strip_brd: Color = c_play if gear_compatible else c_red
	draw_chamfer_plate(canvas, rect, 6.0 * scale_f, mfd_bg, strip_brd * 0.85, 2.0 * scale_f, false)

	var gear_indices: Array[int] = [-1, 0, 1, 2, 3, 4, 5, 6]
	var gear_tokens: Array[String] = ["R", "N", "1", "2", "3", "4", "5", "6"]
	var pad_x: float = 6.0 * scale_f
	var pad_y: float = 4.0 * scale_f
	var gap_x: float = 3.5 * scale_f
	var cell_w: float = (rect.size.x - pad_x * 2.0 - gap_x * 7.0) / 8.0
	var cell_h: float = rect.size.y - pad_y * 2.0

	for i: int in range(8):
		var g_idx: int = gear_indices[i]
		var is_allowed: bool = CardEffectFormatter.contains_gear(allowed, g_idx)
		var is_cur: bool = in_combat_ctx and (g_idx == eval_gear)
		var cr: Rect2 = Rect2(rect.position.x + pad_x + float(i) * (cell_w + gap_x), rect.position.y + pad_y, cell_w, cell_h)

		var fill_c: Color = Color(0.06, 0.055, 0.048, 0.92)
		var brd_c: Color = Color(muted_col.r, muted_col.g, muted_col.b, 0.22)
		var fg_c: Color = Color(muted_col.r, muted_col.g, muted_col.b, 0.34)
		var brd_w: float = 1.2 * scale_f

		if is_cur and is_allowed:
			fill_c = Color(c_play.r * 0.34, c_play.g * 0.44, c_play.b * 0.20, 0.98)
			brd_c = c_sel
			fg_c = txt_col
			brd_w = 2.4 * scale_f
		elif is_cur and not is_allowed:
			fill_c = Color(c_red.r * 0.36, c_red.g * 0.12, c_red.b * 0.08, 0.98)
			brd_c = c_red
			fg_c = c_red.lightened(0.35)
			brd_w = 2.4 * scale_f
		elif is_allowed:
			fill_c = Color(c_play.r * 0.18, c_play.g * 0.28, c_play.b * 0.12, 0.94) if gear_compatible else Color(c_sel.r * 0.20, c_sel.g * 0.16, c_sel.b * 0.07, 0.94)
			brd_c = c_play * 0.85 if gear_compatible else c_sel * 0.85
			fg_c = txt_col if gear_compatible else c_sel.lightened(0.24)
			brd_w = 1.6 * scale_f

		draw_chamfer_plate(canvas, cr, 3.0 * scale_f, fill_c, brd_c, brd_w, false)
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(cr.position.x, cr.position.y + cr.size.y * 0.76),
			gear_tokens[i],
			HORIZONTAL_ALIGNMENT_CENTER,
			cr.size.x,
			maxi(10, roundi(17.0 * scale_f)),
			fg_c,
			out_col,
			2,
			9
		)
		if is_cur:
			var mark_y: float = cr.position.y - 2.0 * scale_f
			canvas.draw_line(Vector2(cr.position.x + 3.0 * scale_f, mark_y), Vector2(cr.end.x - 3.0 * scale_f, mark_y), brd_c, 2.4 * scale_f)

static func _draw_card_hero_panel(
	canvas: CanvasItem,
	rect: Rect2,
	hero: Dictionary,
	cat_col: Color,
	playable: bool,
	scale_f: float,
	repository: GameRepository
) -> void:
	var f_disp: Font = repository.get_font("display")
	var f_body: Font = repository.get_font("body_bold")
	var out_col: Color = repository.get_outline_color()
	var mfd_bg: Color = repository.get_palette_color("mfd_bg")
	var txt_col: Color = repository.get_palette_color("mfd_text")
	var c_sel: Color = repository.get_palette_color("selected_glow")

	var h_kind: String = str(hero.get("kind", "damage"))
	var h_val: String = str(hero.get("value", ""))
	var h_sub: String = str(hero.get("sublabel", ""))
	var h_col: Color = hero.get("color", cat_col) as Color
	var boosted: bool = bool(hero.get("boosted", false))
	var bonus_txt: String = str(hero.get("bonus_text", ""))
	var bonus_act: bool = bool(hero.get("bonus_active", false))
	var bonus_col: Color = hero.get("bonus_color", c_sel) as Color

	var accent: Color = (c_sel if boosted else h_col) if playable else (h_col * 0.62)
	var bg_col: Color = mfd_bg.lerp(Color(accent.r, accent.g, accent.b, 0.98), 0.14 if playable else 0.06)
	draw_chamfer_plate(canvas, rect, 10.0 * scale_f, bg_col, accent * (0.92 if playable else 0.52), 2.2 * scale_f, false)

	var center: Vector2 = rect.position + rect.size * 0.5
	var has_bonus: bool = not bonus_txt.is_empty()
	var wm_c: Vector2 = Vector2(center.x, rect.position.y + rect.size.y * (0.42 if has_bonus else 0.48))
	var wm_r: float = minf(rect.size.x * 0.34, rect.size.y * (0.36 if has_bonus else 0.42))
	var wm_stroke: Color = Color(accent.r, accent.g, accent.b, 0.22 if playable else 0.11)
	var wm_fill: Color = Color(accent.r, accent.g, accent.b, 0.10 if playable else 0.05)

	canvas.draw_arc(wm_c, wm_r * 1.12, 0.0, TAU, 32, Color(accent.r, accent.g, accent.b, 0.14), 1.6 * scale_f, true)
	match h_kind:
		"shield":
			_s_draw_shield_shape(canvas, wm_c, wm_r, wm_stroke, wm_fill)
		"ram":
			_s_draw_spiked_ram(canvas, wm_c, wm_r, wm_stroke, wm_fill)
		"damage", "damage_aoe":
			_s_draw_impact_burst(canvas, wm_c, wm_r * 1.05, wm_stroke)
		"heat_down":
			_s_draw_droplet(canvas, wm_c, wm_r, wm_stroke, wm_fill)
		"rpm_gain":
			canvas.draw_arc(wm_c, wm_r * 0.92, PI * 0.82, PI * 2.18, 22, wm_stroke, 4.0 * scale_f, true)
			canvas.draw_line(wm_c, wm_c + Vector2(cos(PI * 1.92), sin(PI * 1.92)) * (wm_r * 0.84), wm_stroke, 4.0 * scale_f)
		"draw":
			_s_draw_chevron_stack(canvas, wm_c, wm_r * 0.92, wm_stroke, wm_fill, 2)
		_:
			_s_draw_gear_wheel(canvas, wm_c, wm_r * 0.88, wm_stroke, 8)

	var val_str: String = (h_val + "+") if boosted else h_val
	var val_y: float = rect.position.y + rect.size.y * (0.48 if has_bonus else 0.56)
	var val_col: Color = c_sel.lightened(0.18) if (playable and boosted) else (txt_col if playable else h_col.lightened(0.10))
	DiegeticScreenFactory.draw_fitted_text(
		canvas,
		f_disp,
		Vector2(rect.position.x + 10.0 * scale_f, val_y),
		val_str,
		HORIZONTAL_ALIGNMENT_CENTER,
		rect.size.x - 20.0 * scale_f,
		maxi(26, roundi(58.0 * scale_f)),
		val_col,
		out_col,
		maxi(3, roundi(5.0 * scale_f)),
		20
	)

	var sub_y: float = val_y + (24.0 * scale_f)
	DiegeticScreenFactory.draw_fitted_text(
		canvas,
		f_disp,
		Vector2(rect.position.x + 12.0 * scale_f, sub_y),
		h_sub,
		HORIZONTAL_ALIGNMENT_CENTER,
		rect.size.x - 24.0 * scale_f,
		maxi(14, roundi(23.0 * scale_f)),
		accent.lightened(0.30) if playable else accent.lightened(0.10),
		out_col,
		maxi(2, roundi(3.0 * scale_f)),
		13
	)

	if has_bonus:
		var bp_h: float = 24.0 * scale_f
		var bp_w: float = minf(rect.size.x - 24.0 * scale_f, 210.0 * scale_f)
		var bp_r: Rect2 = Rect2(center.x - bp_w * 0.5, rect.end.y - bp_h - 6.0 * scale_f, bp_w, bp_h)
		var b_rim: Color = bonus_col.lightened(0.18) if bonus_act else (bonus_col * 0.65)
		var b_bg: Color = Color(bonus_col.r * 0.30, bonus_col.g * 0.18, bonus_col.b * 0.08, 0.96) if bonus_act else mfd_bg
		draw_chamfer_plate(canvas, bp_r, 5.0 * scale_f, b_bg, b_rim, (2.2 if bonus_act else 1.4) * scale_f, false)
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_body,
			Vector2(bp_r.position.x + 6.0 * scale_f, bp_r.position.y + bp_h * 0.74),
			bonus_txt,
			HORIZONTAL_ALIGNMENT_CENTER,
			bp_r.size.x - 12.0 * scale_f,
			maxi(10, roundi(15.0 * scale_f)),
			txt_col if bonus_act else bonus_col.lightened(0.24),
			out_col,
			2,
			9
		)

static func _draw_card_chip_grid(
	canvas: CanvasItem,
	rect: Rect2,
	chips: Array[Dictionary],
	playable: bool,
	scale_f: float,
	repository: GameRepository
) -> void:
	if chips.is_empty():
		return
	var f_disp: Font = repository.get_font("display")
	var out_col: Color = repository.get_outline_color()
	var mfd_bg: Color = repository.get_palette_color("mfd_bg")
	var c_sel: Color = repository.get_palette_color("selected_glow")
	var muted_txt: Color = repository.get_palette_color("mfd_muted").lightened(0.18)

	var total: int = chips.size()
	var cols: int = 1 if total == 1 else 2
	var rows: int = int(ceil(float(total) / float(cols)))
	var gap_x: float = 6.0 * scale_f
	var gap_y: float = 6.0 * scale_f
	var cell_h: float = (rect.size.y - gap_y * float(rows - 1)) / float(rows)

	for i: int in range(total):
		var row_i: int = i / cols
		var col_i: int = i % cols
		var items_in_row: int = mini(cols, total - row_i * cols)
		var cell_w: float = (rect.size.x - gap_x * float(items_in_row - 1)) / float(items_in_row)
		var cr: Rect2 = Rect2(
			rect.position.x + float(col_i) * (cell_w + gap_x),
			rect.position.y + float(row_i) * (cell_h + gap_y),
			cell_w,
			cell_h
		)
		var chip: Dictionary = chips[i]
		var kw_id: String = str(chip.get("keyword_id", ""))
		var val_txt: String = str(chip.get("value", ""))
		var ecol: Color = chip.get("color", Color.WHITE) as Color
		var boosted: bool = bool(chip.get("boosted", false))
		var stroke: Color = (c_sel if boosted else ecol.lightened(0.22)) if playable else (ecol * 0.65)
		var fill_c: Color = Color(stroke.r * 0.14, stroke.g * 0.12, stroke.b * 0.09, 0.96) if playable else mfd_bg

		draw_chamfer_plate(canvas, cr, 6.0 * scale_f, fill_c, stroke * (0.90 if playable else 0.55), 1.8 * scale_f, false)

		var icon_r: float = clampf(cr.size.y * 0.30, 8.0 * scale_f, 13.0 * scale_f)
		var icon_c: Vector2 = Vector2(cr.position.x + icon_r + 8.0 * scale_f, cr.position.y + cr.size.y * 0.5)
		_draw_compact_chip_icon(canvas, icon_c, icon_r, kw_id, stroke, scale_f)

		var tx: float = icon_c.x + icon_r + 6.0 * scale_f
		var tw: float = maxf(20.0, cr.end.x - tx - 6.0 * scale_f)
		var max_sz: int = maxi(14, roundi(23.0 * scale_f))
		var min_sz: int = maxi(12, roundi(13.0 * scale_f))
		var fit_sz: int = DiegeticScreenFactory.fit_font_size(f_disp, val_txt, tw, max_sz, min_sz)
		DiegeticScreenFactory.draw_fitted_text(
			canvas,
			f_disp,
			Vector2(tx, cr.position.y + cr.size.y * 0.5 + float(fit_sz) * 0.36),
			val_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			tw,
			fit_sz,
			stroke.lightened(0.26) if playable else muted_txt,
			out_col,
			maxi(2, roundi(3.0 * scale_f)),
			min_sz
		)

static func _draw_compact_chip_icon(canvas: CanvasItem, c: Vector2, r: float, kw_id: String, stroke: Color, scale_f: float) -> void:
	var fill_soft: Color = Color(stroke.r, stroke.g, stroke.b, 0.28)
	if kw_id == "shield" or kw_id == "retain_block":
		_s_draw_shield_shape(canvas, c, r * 0.88, stroke, fill_soft)
	elif kw_id == "rpm_gain" or kw_id == "rpm_cost" or kw_id == "rpm_consume_all" or kw_id == "req_redline":
		canvas.draw_arc(c, r * 0.84, PI * 0.8, PI * 2.2, 12, stroke, 2.2 * scale_f, true)
		var nang: float = PI * 1.95 if kw_id == "rpm_gain" else PI * 1.10
		canvas.draw_line(c, c + Vector2(cos(nang), sin(nang)) * (r * 0.76), stroke.lightened(0.3), 2.2 * scale_f)
	elif kw_id == "shift" or kw_id == "shift_choice" or kw_id == "set_gear" or kw_id == "sync_reset":
		_s_draw_gear_wheel(canvas, c, r * 0.84, stroke, 6)
	elif kw_id == "heat_up" or kw_id == "heat_vent":
		_s_draw_flame_tongue(canvas, c, r * 0.88, stroke, fill_soft)
	elif kw_id == "heat_down":
		_s_draw_droplet(canvas, c, r * 0.88, stroke, fill_soft)
	elif kw_id == "draw":
		_s_draw_chevron_stack(canvas, c, r * 0.80, stroke, fill_soft, 2)
	elif kw_id == "weakness" or kw_id == "weakness_aoe" or kw_id == "vulnerable" or kw_id == "vulnerable_aoe":
		_s_draw_impact_burst(canvas, c, r * 0.84, stroke)
	else:
		canvas.draw_circle(c, r * 0.60, fill_soft)
		canvas.draw_arc(c, r * 0.60, 0.0, TAU, 12, stroke, 2.0 * scale_f, true)

static func draw_clear_effect_row(canvas: CanvasItem, rect: Rect2, eff: Dictionary, playable: bool, scale_f: float = 1.0, repository: GameRepository = null) -> void:
	var font: Font = repository.get_font("display") if repository != null else ThemeDB.fallback_font
	var out_col: Color = repository.get_outline_color() if repository != null else Color.BLACK
	var kw_id: String = str(eff.get("keyword_id", ""))
	var val_txt: String = str(eff.get("value", ""))
	var headline: String = str(eff.get("headline", "%s %s" % [str(eff.get("label", "")), val_txt]))
	var ecol: Color = eff.get("color", Color.WHITE) as Color
	var boosted: bool = bool(eff.get("boosted", false))
	var boost_col: Color = repository.get_palette_color("selected_glow") if repository != null else ecol.lightened(0.3)
	var muted_txt: Color = repository.get_palette_color("mfd_muted").lightened(0.18) if repository != null else ecol.lightened(0.1)

	var stroke: Color = (boost_col if boosted else ecol.lightened(0.24)) if playable else (ecol * 0.72)

	var badge_r: float = clampf(rect.size.y * 0.34, 12.0 * scale_f, 18.0 * scale_f)
	var badge_c: Vector2 = Vector2(rect.position.x + badge_r + 4.0 * scale_f, rect.position.y + rect.size.y * 0.5)
	canvas.draw_circle(badge_c, badge_r, Color(stroke.r * 0.18, stroke.g * 0.16, stroke.b * 0.12, 0.95))
	canvas.draw_arc(badge_c, badge_r, 0.0, TAU, 16, stroke, 2.0 * scale_f, true)

	if kw_id == "shield" or kw_id == "scale_block":
		_s_draw_shield_shape(canvas, badge_c, badge_r * 0.72, stroke, Color(stroke.r, stroke.g, stroke.b, 0.28))
	elif kw_id == "ram":
		_s_draw_spiked_ram(canvas, badge_c, badge_r * 0.70, stroke, Color(stroke.r, stroke.g, stroke.b, 0.28))
	elif kw_id == "damage" or kw_id == "damage_aoe" or kw_id == "scale_rpm" or kw_id == "bonus_redline":
		_s_draw_impact_burst(canvas, badge_c, badge_r * 0.76, stroke)
	elif kw_id == "rpm_gain" or kw_id == "rpm_cost" or kw_id == "rpm_consume_all" or kw_id == "req_redline":
		canvas.draw_arc(badge_c, badge_r * 0.72, PI * 0.8, PI * 2.2, 12, stroke, 2.2 * scale_f, true)
		var nang: float = PI * 1.95 if kw_id == "rpm_gain" else PI * 1.10
		canvas.draw_line(badge_c, badge_c + Vector2(cos(nang), sin(nang)) * (badge_r * 0.65), stroke.lightened(0.3), 2.2 * scale_f)
	elif kw_id == "shift" or kw_id == "shift_choice" or kw_id == "set_gear":
		_s_draw_gear_wheel(canvas, badge_c, badge_r * 0.72, stroke, 6)
	elif kw_id == "heat_up":
		_s_draw_flame_tongue(canvas, badge_c, badge_r * 0.74, stroke, Color(stroke.r, stroke.g, stroke.b, 0.28))
	elif kw_id == "heat_down":
		_s_draw_droplet(canvas, badge_c, badge_r * 0.72, stroke, Color(stroke.r, stroke.g, stroke.b, 0.28))
	elif kw_id == "draw":
		_s_draw_chevron_stack(canvas, badge_c, badge_r * 0.68, stroke, Color(stroke.r, stroke.g, stroke.b, 0.28), 2)
	else:
		_s_draw_gear_wheel(canvas, badge_c, badge_r * 0.66, stroke, 6)

	var text_x: float = badge_c.x + badge_r + 10.0 * scale_f
	var text_w: float = rect.end.x - text_x - 4.0 * scale_f
	var head_str: String = (headline + " +") if boosted else headline
	var h_col: Color = boost_col.lightened(0.18) if (playable and boosted) else (stroke.lightened(0.28) if playable else muted_txt)

	var max_h_sz: int = maxi(13, roundi(26.0 * scale_f))
	var min_h_sz: int = maxi(10, roundi(12.0 * scale_f))
	var fitted_sz: int = DiegeticScreenFactory.fit_font_size(font, head_str, text_w, max_h_sz, min_h_sz)
	var text_y: float = rect.position.y + rect.size.y * 0.5 + float(fitted_sz) * 0.36
	DiegeticScreenFactory.draw_fitted_text(
		canvas,
		font,
		Vector2(text_x, text_y),
		head_str,
		HORIZONTAL_ALIGNMENT_LEFT,
		text_w,
		fitted_sz,
		h_col,
		out_col,
		maxi(2, roundi(3.5 * scale_f)),
		min_h_sz
	)

static func draw_card_emblem(canvas: CanvasItem, rect: Rect2, emblem_id: String, accent_col: Color, is_active: bool) -> void:
	if rect.size.x < 16.0 or rect.size.y < 16.0:
		return
	var c: Vector2 = rect.position + rect.size * 0.5
	var r: float = minf(rect.size.x, rect.size.y) * 0.40
	var stroke: Color = accent_col.lightened(0.30) if is_active else (accent_col * 0.62)
	var fill_soft: Color = Color(stroke.r, stroke.g, stroke.b, 0.25 if is_active else 0.12)
	var grid_col: Color = Color(stroke.r, stroke.g, stroke.b, 0.15 if is_active else 0.07)

	canvas.draw_line(Vector2(rect.position.x + 8.0, c.y), Vector2(rect.end.x - 8.0, c.y), grid_col, 1.0)
	canvas.draw_line(Vector2(c.x, rect.position.y + 6.0), Vector2(c.x, rect.end.y - 6.0), grid_col, 1.0)
	canvas.draw_arc(c, r * 1.08, 0.0, TAU, 32, grid_col, 1.5, true)
	canvas.draw_arc(c, r * 0.82, -0.4, 0.9, 12, grid_col * 1.4, 2.0, true)
	canvas.draw_arc(c, r * 0.82, PI - 0.4, PI + 0.9, 12, grid_col * 1.4, 2.0, true)

	match emblem_id:
		"pedal_boost":
			_s_draw_chevron_stack(canvas, c, r, stroke, fill_soft, 2)
		"low_range_gear":
			_s_draw_shield_shape(canvas, c + Vector2(0.0, 2.0), r * 0.94, stroke, fill_soft)
			_s_draw_gear_wheel(canvas, c, r * 0.44, stroke, 6)
		"spiked_bumper":
			_s_draw_spiked_ram(canvas, c, r, stroke, fill_soft)
		"shield_slam":
			_s_draw_shield_shape(canvas, c - Vector2(r * 0.22, 0.0), r * 0.78, stroke, fill_soft)
			_s_draw_impact_burst(canvas, c + Vector2(r * 0.38, 0.0), r * 0.58, stroke)
		"burnout_wheel":
			_s_draw_gear_wheel(canvas, c - Vector2(r * 0.18, 0.0), r * 0.68, stroke, 8)
			_s_draw_smoke_waves(canvas, c + Vector2(r * 0.48, 0.0), r * 0.65, stroke)
		"reverse_shield":
			_s_draw_shield_shape(canvas, c, r * 0.95, stroke, fill_soft)
			_s_draw_down_arrow(canvas, c, r * 0.48, stroke)
		"twin_clutch":
			_s_draw_gear_wheel(canvas, c - Vector2(r * 0.42, 0.0), r * 0.54, stroke, 7)
			_s_draw_gear_wheel(canvas, c + Vector2(r * 0.42, 0.0), r * 0.54, stroke, 7)
		"heel_toe":
			_s_draw_gear_wheel(canvas, c - Vector2(r * 0.45, 0.0), r * 0.48, stroke, 6)
			_s_draw_chevron_stack(canvas, c + Vector2(r * 0.35, 0.0), r * 0.68, stroke, fill_soft, 2)
		"twin_bullets":
			_s_draw_projectile(canvas, c + Vector2(-r * 0.36, 0.0), r * 0.78, stroke, fill_soft)
			_s_draw_projectile(canvas, c + Vector2(r * 0.36, 0.0), r * 0.78, stroke, fill_soft)
		"water_coolant":
			_s_draw_droplet(canvas, c, r * 0.92, stroke, fill_soft)
		"seq_upshift":
			_s_draw_gear_wheel(canvas, c + Vector2(-r * 0.35, r * 0.15), r * 0.52, stroke, 6)
			_s_draw_chevron_stack(canvas, c + Vector2(r * 0.38, -r * 0.08), r * 0.72, stroke, fill_soft, 2)
		"engine_brake":
			canvas.draw_arc(c, r * 0.86, 0.0, TAU, 28, stroke, 4.0, true)
			canvas.draw_arc(c, r * 0.42, 0.0, TAU, 20, stroke, 2.5, true)
			canvas.draw_arc(c, r * 1.02, -0.9, 0.9, 14, stroke, 7.0, true)
		"overtake_lance":
			_s_draw_lance_head(canvas, c, r * 1.05, stroke, fill_soft)
		"slipstream":
			for idx: int in range(-1, 2):
				var y_off: float = float(idx) * r * 0.46
				canvas.draw_line(Vector2(c.x - r * 1.05, c.y + y_off), Vector2(c.x + r * 0.85, c.y + y_off), stroke, 3.5)
				canvas.draw_line(Vector2(c.x + r * 0.55, c.y + y_off - 7.0), Vector2(c.x + r * 0.92, c.y + y_off), stroke, 3.5)
				canvas.draw_line(Vector2(c.x + r * 0.55, c.y + y_off + 7.0), Vector2(c.x + r * 0.92, c.y + y_off), stroke, 3.5)
		"triple_exhaust":
			for idx: int in range(-1, 2):
				_s_draw_flame_tongue(canvas, c + Vector2(float(idx) * r * 0.62, 0.0), r * 0.68, stroke, fill_soft)
		"nos_bottle":
			_s_draw_nos_cylinder(canvas, c, r * 0.92, stroke, fill_soft)
		"kinetic_meteor":
			_s_draw_lance_head(canvas, c + Vector2(r * 0.18, 0.0), r * 0.92, stroke, fill_soft)
			_s_draw_impact_burst(canvas, c - Vector2(r * 0.52, 0.0), r * 0.55, stroke)
		"redline_skull":
			canvas.draw_arc(c + Vector2(0.0, r * 0.25), r * 0.95, PI, TAU, 24, stroke, 4.0, true)
			canvas.draw_line(c + Vector2(0.0, r * 0.25), c + Vector2(r * 0.72, -r * 0.48), stroke, 4.5)
			canvas.draw_circle(c + Vector2(0.0, r * 0.25), 5.0, stroke)
		"handbrake_drift":
			canvas.draw_line(c + Vector2(-r * 0.70, r * 0.55), c + Vector2(r * 0.35, -r * 0.65), stroke, 6.0)
			canvas.draw_circle(c + Vector2(-r * 0.70, r * 0.55), 7.0, stroke)
			canvas.draw_arc(c + Vector2(r * 0.25, r * 0.25), r * 0.65, -0.5, 1.4, 16, stroke, 3.0, true)
		"turbo_snail":
			canvas.draw_arc(c, r * 0.80, 0.4, TAU, 28, stroke, 4.0, true)
			canvas.draw_arc(c, r * 0.38, 0.0, TAU, 20, stroke, 3.0, true)
			canvas.draw_line(c + Vector2(0.0, -r * 0.80), c + Vector2(r * 0.95, -r * 0.80), stroke, 4.5)
		"radiator_grid":
			var r_oct: PackedVector2Array = make_chamfer_poly(Rect2(c.x - r * 0.85, c.y - r * 0.68, r * 1.70, r * 1.36), 8.0, 8.0, 8.0, 8.0)
			canvas.draw_colored_polygon(r_oct, fill_soft)
			r_oct.append(r_oct[0])
			canvas.draw_polyline(r_oct, stroke, 3.2, true)
			for g: int in range(-2, 3):
				var gx: float = c.x + float(g) * r * 0.28
				canvas.draw_line(Vector2(gx, c.y - r * 0.54), Vector2(gx, c.y + r * 0.54), stroke, 2.2)
		"oil_slick":
			var pts: PackedVector2Array = PackedVector2Array([
				c + Vector2(-r * 0.95, r * 0.15),
				c + Vector2(-r * 0.45, -r * 0.55),
				c + Vector2(r * 0.35, -r * 0.42),
				c + Vector2(r * 0.95, r * 0.08),
				c + Vector2(r * 0.40, r * 0.62),
				c + Vector2(-r * 0.50, r * 0.55)
			])
			canvas.draw_colored_polygon(pts, fill_soft)
			pts.append(pts[0])
			canvas.draw_polyline(pts, stroke, 3.2, true)
		"backfire_blast":
			_s_draw_impact_burst(canvas, c, r * 0.98, stroke)
		"apex_slash":
			canvas.draw_arc(c + Vector2(r * 0.45, r * 0.55), r * 1.25, PI * 1.05, PI * 1.62, 20, stroke, 4.5, true)
			_s_draw_lance_head(canvas, c + Vector2(r * 0.25, -r * 0.20), r * 0.65, stroke, fill_soft)
		"twin_scroll":
			canvas.draw_arc(c + Vector2(-r * 0.36, 0.0), r * 0.54, 0.4, TAU, 20, stroke, 3.6, true)
			canvas.draw_arc(c + Vector2(r * 0.36, 0.0), r * 0.54, 0.4, TAU, 20, stroke, 3.6, true)
			canvas.draw_line(c + Vector2(-r * 0.36, -r * 0.54), c + Vector2(r * 0.36, -r * 0.54), stroke, 3.4)
		"blind_shift":
			_s_draw_shield_shape(canvas, c, r * 0.92, stroke, fill_soft)
			_s_draw_down_arrow(canvas, c + Vector2(-r * 0.22, 0.0), r * 0.42, stroke)
			_s_draw_down_arrow(canvas, c + Vector2(r * 0.22, 0.0), r * 0.42, stroke)
		"ceramic_launch":
			_s_draw_spiked_ram(canvas, c + Vector2(0.0, r * 0.16), r * 0.84, stroke, fill_soft)
			_s_draw_chevron_stack(canvas, c + Vector2(0.0, -r * 0.42), r * 0.46, stroke, fill_soft, 2)
		"cryo_fan":
			canvas.draw_arc(c, r * 0.84, 0.0, TAU, 24, stroke, 3.2, true)
			for f_i: int in range(6):
				var fa: float = (TAU * float(f_i)) / 6.0
				var fdir: Vector2 = Vector2(cos(fa), sin(fa))
				canvas.draw_line(c + fdir * (r * 0.18), c + fdir * (r * 0.74), stroke, 3.8)
			canvas.draw_circle(c, r * 0.22, fill_soft)
		"timing_chain":
			_s_draw_gear_wheel(canvas, c + Vector2(-r * 0.46, r * 0.12), r * 0.44, stroke, 7)
			_s_draw_gear_wheel(canvas, c + Vector2(r * 0.46, -r * 0.12), r * 0.44, stroke, 7)
			canvas.draw_line(c + Vector2(-r * 0.46, -r * 0.30), c + Vector2(r * 0.46, -r * 0.54), stroke, 3.2)
			canvas.draw_line(c + Vector2(-r * 0.46, r * 0.54), c + Vector2(r * 0.46, r * 0.30), stroke, 3.2)
		"supercharger_blower":
			var blower: PackedVector2Array = make_chamfer_poly(Rect2(c.x - r * 0.78, c.y - r * 0.52, r * 1.56, r * 1.04), 10.0, 10.0, 6.0, 6.0)
			canvas.draw_colored_polygon(blower, fill_soft)
			blower.append(blower[0])
			canvas.draw_polyline(blower, stroke, 3.4, true)
			_s_draw_flame_tongue(canvas, c + Vector2(-r * 0.32, -r * 0.15), r * 0.48, stroke, fill_soft)
			_s_draw_flame_tongue(canvas, c + Vector2(r * 0.32, -r * 0.15), r * 0.48, stroke, fill_soft)
		_:
			_s_draw_gear_wheel(canvas, c, r * 0.72, stroke, 8)

static func draw_relic_blueprint(canvas: CanvasItem, c: Vector2, r: float, relic_id: String, stroke: Color, fill_col: Color) -> void:
	canvas.draw_arc(c, r * 0.98, 0.0, TAU, 24, Color(stroke.r, stroke.g, stroke.b, 0.32), 1.6, true)
	match relic_id:
		"turbina_maggiorata":
			canvas.draw_arc(c, r * 0.76, 0.3, TAU, 24, stroke, 3.5, true)
			_s_draw_gear_wheel(canvas, c, r * 0.42, stroke, 6)
		"radiatore_rame":
			_s_draw_droplet(canvas, c, r * 0.78, stroke, fill_col)
		"frizione_rinforzata":
			_s_draw_shield_shape(canvas, c, r * 0.85, stroke, fill_col)
			_s_draw_gear_wheel(canvas, c, r * 0.38, stroke, 6)
		"volano_alleggerito":
			_s_draw_gear_wheel(canvas, c, r * 0.82, stroke, 10)
		"alternatore_corsa":
			_s_draw_chevron_stack(canvas, c, r * 0.82, stroke, fill_col, 2)
		"differenziale_autobloccante":
			_s_draw_shield_shape(canvas, c, r * 0.84, stroke, fill_col)
			canvas.draw_line(c + Vector2(-r * 0.56, 0.0), c + Vector2(r * 0.56, 0.0), stroke, 3.2)
			canvas.draw_circle(c, r * 0.24, stroke)
		"collettore_titanio":
			_s_draw_flame_tongue(canvas, c + Vector2(-r * 0.28, 0.0), r * 0.62, stroke, fill_col)
			_s_draw_flame_tongue(canvas, c + Vector2(r * 0.28, 0.0), r * 0.62, stroke, fill_col)
		"rigenerazione_frenata":
			canvas.draw_arc(c, r * 0.74, 0.0, TAU, 24, stroke, 3.2, true)
			_s_draw_down_arrow(canvas, c, r * 0.52, stroke)
		"recupero_rottami":
			_s_draw_spiked_ram(canvas, c, r * 0.78, stroke, fill_col)
		_:
			_s_draw_flame_tongue(canvas, c, r * 0.80, stroke, fill_col)

static func _s_draw_chevron_stack(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color, count: int) -> void:
	for i: int in range(count):
		var y_off: float = (float(i) - float(count - 1) * 0.5) * r * 0.62 + r * 0.12
		var pts: PackedVector2Array = PackedVector2Array([
			Vector2(c.x - r * 0.75, c.y + y_off + r * 0.26),
			Vector2(c.x, c.y + y_off - r * 0.34),
			Vector2(c.x + r * 0.75, c.y + y_off + r * 0.26),
			Vector2(c.x + r * 0.45, c.y + y_off + r * 0.26),
			Vector2(c.x, c.y + y_off - r * 0.08),
			Vector2(c.x - r * 0.45, c.y + y_off + r * 0.26)
		])
		canvas.draw_colored_polygon(pts, fill_col)
		pts.append(pts[0])
		canvas.draw_polyline(pts, stroke, 2.8, true)

static func _s_draw_shield_shape(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array([
		c + Vector2(-r * 0.78, -r * 0.72),
		c + Vector2(r * 0.78, -r * 0.72),
		c + Vector2(r * 0.72, r * 0.08),
		c + Vector2(0.0, r * 0.88),
		c + Vector2(-r * 0.72, r * 0.08)
	])
	canvas.draw_colored_polygon(pts, fill_col)
	pts.append(pts[0])
	canvas.draw_polyline(pts, stroke, 3.2, true)

static func _s_draw_gear_wheel(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, teeth: int) -> void:
	canvas.draw_arc(c, r * 0.72, 0.0, TAU, 24, stroke, 3.2, true)
	canvas.draw_arc(c, r * 0.32, 0.0, TAU, 16, stroke, 2.2, true)
	for i: int in range(teeth):
		var a: float = (TAU * float(i)) / float(teeth)
		var dir: Vector2 = Vector2(cos(a), sin(a))
		canvas.draw_line(c + dir * (r * 0.68), c + dir * r, stroke, 4.2)

static func _s_draw_spiked_ram(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var bar_pts: PackedVector2Array = make_chamfer_poly(Rect2(c.x - r * 0.95, c.y + r * 0.08, r * 1.90, r * 0.42), 6.0, 6.0, 6.0, 6.0)
	canvas.draw_colored_polygon(bar_pts, fill_col)
	bar_pts.append(bar_pts[0])
	canvas.draw_polyline(bar_pts, stroke, 2.8, true)
	for s: int in range(-1, 2):
		var sx: float = c.x + float(s) * r * 0.58
		var tri: PackedVector2Array = PackedVector2Array([
			Vector2(sx - r * 0.22, c.y + r * 0.08),
			Vector2(sx, c.y - r * 0.68),
			Vector2(sx + r * 0.22, c.y + r * 0.08)
		])
		canvas.draw_colored_polygon(tri, fill_col)
		tri.append(tri[0])
		canvas.draw_polyline(tri, stroke, 2.8, true)

static func _s_draw_impact_burst(canvas: CanvasItem, c: Vector2, r: float, stroke: Color) -> void:
	var rays: int = 8
	for i: int in range(rays):
		var a: float = (TAU * float(i)) / float(rays)
		var outer: float = r if (i % 2 == 0) else r * 0.62
		canvas.draw_line(c + Vector2(cos(a), sin(a)) * (r * 0.22), c + Vector2(cos(a), sin(a)) * outer, stroke, 3.0)

static func _s_draw_smoke_waves(canvas: CanvasItem, c: Vector2, r: float, stroke: Color) -> void:
	for i: int in range(-1, 2):
		canvas.draw_arc(c + Vector2(0.0, float(i) * r * 0.45), r * 0.36, -1.1, 1.1, 12, stroke, 2.8, true)

static func _s_draw_down_arrow(canvas: CanvasItem, c: Vector2, r: float, stroke: Color) -> void:
	canvas.draw_line(c + Vector2(0.0, -r * 0.75), c + Vector2(0.0, r * 0.65), stroke, 4.0)
	canvas.draw_line(c + Vector2(-r * 0.55, r * 0.12), c + Vector2(0.0, r * 0.72), stroke, 4.0)
	canvas.draw_line(c + Vector2(r * 0.55, r * 0.12), c + Vector2(0.0, r * 0.72), stroke, 4.0)

static func _s_draw_projectile(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array([
		c + Vector2(-r * 0.24, r * 0.72),
		c + Vector2(-r * 0.24, -r * 0.22),
		c + Vector2(0.0, -r * 0.78),
		c + Vector2(r * 0.24, -r * 0.22),
		c + Vector2(r * 0.24, r * 0.72)
	])
	canvas.draw_colored_polygon(pts, fill_col)
	pts.append(pts[0])
	canvas.draw_polyline(pts, stroke, 2.8, true)

static func _s_draw_droplet(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array([
		c + Vector2(0.0, -r * 0.88),
		c + Vector2(r * 0.64, r * 0.18),
		c + Vector2(r * 0.42, r * 0.72),
		c + Vector2(0.0, r * 0.86),
		c + Vector2(-r * 0.42, r * 0.72),
		c + Vector2(-r * 0.64, r * 0.18)
	])
	canvas.draw_colored_polygon(pts, fill_col)
	pts.append(pts[0])
	canvas.draw_polyline(pts, stroke, 3.2, true)

static func _s_draw_lance_head(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array([
		c + Vector2(-r * 0.85, -r * 0.48),
		c + Vector2(r * 0.90, 0.0),
		c + Vector2(-r * 0.85, r * 0.48),
		c + Vector2(-r * 0.42, 0.0)
	])
	canvas.draw_colored_polygon(pts, fill_col)
	pts.append(pts[0])
	canvas.draw_polyline(pts, stroke, 3.2, true)

static func _s_draw_flame_tongue(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array([
		c + Vector2(0.0, -r * 0.92),
		c + Vector2(r * 0.36, -r * 0.05),
		c + Vector2(r * 0.22, r * 0.78),
		c + Vector2(-r * 0.22, r * 0.78),
		c + Vector2(-r * 0.36, -r * 0.05)
	])
	canvas.draw_colored_polygon(pts, fill_col)
	pts.append(pts[0])
	canvas.draw_polyline(pts, stroke, 2.6, true)

static func _s_draw_nos_cylinder(canvas: CanvasItem, c: Vector2, r: float, stroke: Color, fill_col: Color) -> void:
	var body_pts: PackedVector2Array = make_chamfer_poly(Rect2(c.x - r * 0.42, c.y - r * 0.48, r * 0.84, r * 1.28), 8.0, 8.0, 6.0, 6.0)
	canvas.draw_colored_polygon(body_pts, fill_col)
	body_pts.append(body_pts[0])
	canvas.draw_polyline(body_pts, stroke, 3.0, true)
	canvas.draw_line(Vector2(c.x - r * 0.22, c.y - r * 0.72), Vector2(c.x + r * 0.22, c.y - r * 0.72), stroke, 4.0)
	canvas.draw_line(Vector2(c.x, c.y - r * 0.48), Vector2(c.x, c.y - r * 0.72), stroke, 4.0)
	canvas.draw_line(c + Vector2(r * 0.14, -r * 0.22), c + Vector2(-r * 0.14, r * 0.10), stroke, 3.0)
	canvas.draw_line(c + Vector2(-r * 0.14, r * 0.10), c + Vector2(r * 0.14, r * 0.10), stroke, 3.0)
	canvas.draw_line(c + Vector2(r * 0.14, r * 0.10), c + Vector2(-r * 0.14, r * 0.44), stroke, 3.0)

static func draw_category_icon(canvas: CanvasItem, c: Vector2, r: float, category: String, stroke: Color, fill_col: Color) -> void:
	match category:
		"Attack", "Attacco":
			_s_draw_impact_burst(canvas, c, r * 0.96, stroke)
			canvas.draw_circle(c, r * 0.28, fill_col)
		"Ram", "Speronamento":
			_s_draw_spiked_ram(canvas, c, r * 0.92, stroke, fill_col)
		"Defense", "Difesa":
			_s_draw_shield_shape(canvas, c, r * 0.92, stroke, fill_col)
		"Cooling", "Raffreddamento":
			_s_draw_droplet(canvas, c, r * 0.90, stroke, fill_col)
		"Power", "Potenza":
			_s_draw_flame_tongue(canvas, c, r * 0.95, stroke, fill_col)
		"Technique", "Tecnica":
			_s_draw_gear_wheel(canvas, c, r * 0.92, stroke, 6)
		_:
			_s_draw_chevron_stack(canvas, c, r * 0.88, stroke, fill_col, 2)
