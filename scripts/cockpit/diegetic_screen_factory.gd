class_name DiegeticScreenFactory
extends RefCounted

static var _font_fit_cache: Dictionary = {}

static func create_screen(parent_node: Node3D, pixel_size_xy: Vector2i, world_size_xy: Vector2, local_pos: Vector3, local_rot_deg: Vector3 = Vector3.ZERO, billboard: bool = false, transparent_bg: bool = false) -> Dictionary:
	var safe_px: Vector2i = Vector2i(maxi(64, pixel_size_xy.x), maxi(32, pixel_size_xy.y))
	var safe_world: Vector2 = Vector2(maxf(0.02, world_size_xy.x), maxf(0.02, world_size_xy.y))

	var viewport: SubViewport = SubViewport.new()
	viewport.size = safe_px
	viewport.transparent_bg = transparent_bg
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
		viewport.msaa_2d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	parent_node.add_child(viewport)

	var root_control: Control = Control.new()
	root_control.position = Vector2.ZERO
	root_control.custom_minimum_size = Vector2(safe_px.x, safe_px.y)
	root_control.size = Vector2(safe_px.x, safe_px.y)
	viewport.add_child(root_control)

	var quad_instance: MeshInstance3D = MeshInstance3D.new()
	var quad_mesh: QuadMesh = QuadMesh.new()
	quad_mesh.size = safe_world
	quad_instance.mesh = quad_mesh
	quad_instance.position = local_pos
	quad_instance.rotation_degrees = local_rot_deg
	quad_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_fog = true
	mat.albedo_texture = viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if transparent_bg:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad_instance.material_override = mat
	parent_node.add_child(quad_instance)

	return {
		"viewport": viewport,
		"root": root_control,
		"mesh": quad_instance,
		"material": mat
	}

static func request_redraw(canvas: CanvasItem) -> void:
	if canvas == null or not is_instance_valid(canvas):
		return
	var vp: Viewport = canvas.get_viewport()
	if vp is SubViewport:
		var svp: SubViewport = vp as SubViewport
		if not bool(svp.get_meta("screen_disabled", false)):
			svp.render_target_update_mode = SubViewport.UPDATE_ONCE
	canvas.queue_redraw()

static func set_screen_enabled(canvas_or_vp: Node, enabled: bool) -> void:
	if canvas_or_vp == null or not is_instance_valid(canvas_or_vp):
		return
	var vp: Viewport = (canvas_or_vp as Viewport) if (canvas_or_vp is Viewport) else canvas_or_vp.get_viewport()
	if not (vp is SubViewport):
		return
	var svp: SubViewport = vp as SubViewport
	var was_disabled: bool = bool(svp.get_meta("screen_disabled", false))
	svp.set_meta("screen_disabled", not enabled)
	if not enabled:
		svp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif was_disabled:
		svp.render_target_update_mode = SubViewport.UPDATE_ONCE
		if canvas_or_vp is CanvasItem:
			(canvas_or_vp as CanvasItem).queue_redraw()

static func attach_full_panel(root_ctrl: Control, style: StyleBoxFlat) -> PanelContainer:
	var pnl: PanelContainer = PanelContainer.new()
	pnl.position = Vector2.ZERO
	pnl.custom_minimum_size = root_ctrl.size
	pnl.size = root_ctrl.size
	pnl.add_theme_stylebox_override("panel", style)
	root_ctrl.add_child(pnl)
	return pnl

static func make_panel_style(bg: Color, border: Color, border_w: int = 2, corner_r: int = 4, pad_x: float = 12.0, pad_y: float = 8.0) -> StyleBoxFlat:
	var st: StyleBoxFlat = StyleBoxFlat.new()
	st.bg_color = bg
	st.border_color = border
	st.border_width_left = border_w
	st.border_width_right = border_w
	st.border_width_top = border_w
	st.border_width_bottom = border_w
	st.corner_radius_top_left = corner_r
	st.corner_radius_top_right = corner_r
	st.corner_radius_bottom_left = corner_r
	st.corner_radius_bottom_right = corner_r
	st.content_margin_left = pad_x
	st.content_margin_right = pad_x
	st.content_margin_top = pad_y
	st.content_margin_bottom = pad_y
	return st

static func make_crisp_label(text: String, font_px: int, font_col: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, autowrap: bool = false, outline_px: int = 3, repo: GameRepository = null, font_role: String = "display") -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.horizontal_alignment = align
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if repo != null:
		lbl.add_theme_font_override("font", repo.get_font(font_role))
		lbl.add_theme_color_override("font_outline_color", repo.get_outline_color())
	else:
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_font_size_override("font_size", font_px)
	lbl.add_theme_color_override("font_color", font_col)
	lbl.add_theme_constant_override("outline_size", outline_px)
	if autowrap:
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl

static func style_label_3d(lbl: Label3D, repo: GameRepository, font_role: String, font_px: int, outline_px: int, pixel_size_m: float, col: Color) -> void:
	if lbl == null or repo == null:
		return
	lbl.font = repo.get_font(font_role)
	lbl.font_size = font_px
	lbl.outline_size = outline_px
	lbl.outline_modulate = repo.get_outline_color()
	lbl.pixel_size = pixel_size_m
	lbl.modulate = col
	lbl.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

static func create_metal_bezel(parent_node: Node3D, screen_size: Vector2, pad: float, depth: float, local_pos: Vector3, local_rot_deg: Vector3, metal_col: Color) -> MeshInstance3D:
	var inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(screen_size.x + pad * 2.0, screen_size.y + pad * 2.0, depth)
	inst.mesh = box
	inst.position = local_pos
	inst.rotation_degrees = local_rot_deg
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = metal_col
	mat.metallic = 0.62
	mat.roughness = 0.44
	inst.material_override = mat
	parent_node.add_child(inst)
	return inst

static func create_metal_strut(parent_node: Node3D, size_xyz: Vector3, local_pos: Vector3, local_rot_deg: Vector3, metal_col: Color) -> MeshInstance3D:
	var inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size_xyz
	inst.mesh = box
	inst.position = local_pos
	inst.rotation_degrees = local_rot_deg
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = metal_col
	mat.metallic = 0.58
	mat.roughness = 0.48
	inst.material_override = mat
	parent_node.add_child(inst)
	return inst

static func draw_chamfer_rect(canvas: CanvasItem, r: Rect2, cut: float, fill: Color, border: Color, bw: float = 2.0) -> void:
	var c: float = minf(cut, minf(r.size.x, r.size.y) * 0.35)
	var pts: PackedVector2Array = PackedVector2Array([
		Vector2(r.position.x + c, r.position.y),
		Vector2(r.end.x - c, r.position.y),
		Vector2(r.end.x, r.position.y + c),
		Vector2(r.end.x, r.end.y - c),
		Vector2(r.end.x - c, r.end.y),
		Vector2(r.position.x + c, r.end.y),
		Vector2(r.position.x, r.end.y - c),
		Vector2(r.position.x, r.position.y + c)
	])
	canvas.draw_colored_polygon(pts, fill)
	if bw > 0.0 and border.a > 0.01:
		var closed: PackedVector2Array = pts.duplicate()
		closed.append(pts[0])
		canvas.draw_polyline(closed, border, bw, true)

static func draw_hazard_band(canvas: CanvasItem, rect: Rect2, stripe_col: Color, stripe_w: float = 14.0, gap_w: float = 10.0) -> void:
	if rect.size.x <= 2.0 or rect.size.y <= 2.0:
		return
	var step: float = maxf(6.0, stripe_w + gap_w)
	var skew: float = rect.size.y * 0.72
	var x: float = rect.position.x - skew
	while x < rect.end.x + skew:
		var x0: float = clampf(x, rect.position.x, rect.end.x)
		var x1: float = clampf(x + stripe_w, rect.position.x, rect.end.x)
		var bx0: float = clampf(x + skew, rect.position.x, rect.end.x)
		var bx1: float = clampf(x + stripe_w + skew, rect.position.x, rect.end.x)
		if x1 > x0 + 0.5 or bx1 > bx0 + 0.5:
			canvas.draw_colored_polygon(PackedVector2Array([
				Vector2(x0, rect.position.y),
				Vector2(x1, rect.position.y),
				Vector2(bx1, rect.end.y),
				Vector2(bx0, rect.end.y)
			]), stripe_col)
		x += step

static func draw_industrial_plate(canvas: CanvasItem, rect: Rect2, repo: GameRepository, accent: Color, cut: float = 10.0, border_w: float = 2.4, with_scanlines: bool = true, hazard_band_h: float = 0.0, use_panel_bg: bool = false) -> void:
	if canvas == null or repo == null:
		return
	var style: Dictionary = repo.screen_style()
	var bg_col: Color = repo.get_palette_color("mfd_panel_bg" if use_panel_bg else "mfd_bg")
	draw_chamfer_rect(canvas, rect, cut, bg_col, Color.TRANSPARENT, 0.0)

	var vig_band: float = float(style.get("vignette_band_px", 14.0))
	var vig_alpha: float = float(style.get("vignette_alpha", 0.3))
	if vig_band > 1.0 and rect.size.y > vig_band * 2.5:
		canvas.draw_rect(Rect2(rect.position.x + cut * 0.5, rect.position.y + 1.0, rect.size.x - cut, vig_band), Color(0.0, 0.0, 0.0, vig_alpha))
		canvas.draw_rect(Rect2(rect.position.x + cut * 0.5, rect.end.y - vig_band - 1.0, rect.size.x - cut, vig_band), Color(0.0, 0.0, 0.0, vig_alpha))

	if hazard_band_h > 2.0:
		var hb_rect: Rect2 = Rect2(rect.position.x + 3.0, rect.position.y + 3.0, rect.size.x - 6.0, minf(hazard_band_h, rect.size.y - 6.0))
		canvas.draw_rect(hb_rect, Color(accent.r * 0.2, accent.g * 0.18, accent.b * 0.14, 0.92))
		var h_alpha: float = float(style.get("hazard_stripe_alpha", 0.22))
		var h_w: float = float(style.get("hazard_stripe_width_px", 14.0))
		var h_g: float = float(style.get("hazard_stripe_gap_px", 10.0))
		draw_hazard_band(canvas, hb_rect, Color(accent.r, accent.g, accent.b, h_alpha), h_w, h_g)
		canvas.draw_line(Vector2(hb_rect.position.x, hb_rect.end.y), Vector2(hb_rect.end.x, hb_rect.end.y), Color(accent.r, accent.g, accent.b, 0.65), 1.6)

	if with_scanlines:
		var spacing: float = maxf(3.0, float(style.get("scanline_spacing_px", 4.0)))
		var s_alpha: float = float(style.get("scanline_alpha", 0.14))
		var sy: float = rect.position.y + spacing
		while sy < rect.end.y - 2.0:
			canvas.draw_line(Vector2(rect.position.x + 3.0, sy), Vector2(rect.end.x - 3.0, sy), Color(0.0, 0.0, 0.0, s_alpha), 1.0)
			sy += spacing

	draw_chamfer_rect(canvas, rect, cut, Color.TRANSPARENT, accent, border_w)

	var brk_len: float = minf(float(style.get("bracket_len_px", 18.0)), minf(rect.size.x, rect.size.y) * 0.22)
	var brk_w: float = float(style.get("bracket_width_px", 2.6))
	var trim_col: Color = repo.get_palette_color("bezel_trim").lerp(accent, 0.45)
	var rivet_r: float = float(style.get("rivet_radius_px", 3.6))
	if rect.size.x >= 96.0 and rect.size.y >= 54.0:
		var inset: float = maxf(4.0, cut * 0.55)
		var tl: Vector2 = rect.position + Vector2(inset, inset)
		var tr: Vector2 = Vector2(rect.end.x - inset, rect.position.y + inset)
		var bl: Vector2 = Vector2(rect.position.x + inset, rect.end.y - inset)
		var br: Vector2 = rect.end - Vector2(inset, inset)
		canvas.draw_line(tl, tl + Vector2(brk_len, 0.0), trim_col, brk_w)
		canvas.draw_line(tl, tl + Vector2(0.0, brk_len), trim_col, brk_w)
		canvas.draw_line(tr, tr + Vector2(-brk_len, 0.0), trim_col, brk_w)
		canvas.draw_line(tr, tr + Vector2(0.0, brk_len), trim_col, brk_w)
		canvas.draw_line(bl, bl + Vector2(brk_len, 0.0), trim_col, brk_w)
		canvas.draw_line(bl, bl + Vector2(0.0, -brk_len), trim_col, brk_w)
		canvas.draw_line(br, br + Vector2(-brk_len, 0.0), trim_col, brk_w)
		canvas.draw_line(br, br + Vector2(0.0, -brk_len), trim_col, brk_w)
		if rivet_r > 1.0 and rect.size.y >= 84.0:
			var r_off: float = inset + 6.0
			for rpt: Vector2 in [
				rect.position + Vector2(r_off, r_off),
				Vector2(rect.end.x - r_off, rect.position.y + r_off),
				Vector2(rect.position.x + r_off, rect.end.y - r_off),
				rect.end - Vector2(r_off, r_off)
			]:
				canvas.draw_circle(rpt, rivet_r, Color(0.08, 0.07, 0.06, 0.92))
				canvas.draw_arc(rpt, rivet_r, 0.0, TAU, 12, Color(trim_col.r, trim_col.g, trim_col.b, 0.72), 1.2)

static func fit_font_size(font: Font, text: String, max_w: float, max_px: int, min_px: int = 11) -> int:
	if font == null or text.is_empty() or max_w <= 0.0:
		return max_px
	var lo: int = mini(min_px, max_px)
	if lo >= max_px:
		return max_px
	var w_bucket: int = int(max_w)
	var cache_key: String = "%d|%d|%d|%d|%s" % [font.get_rid().get_id(), w_bucket, max_px, lo, text]
	if _font_fit_cache.has(cache_key):
		return int(_font_fit_cache[cache_key])
	var chosen: int = lo
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, max_px).x <= max_w:
		chosen = max_px
	else:
		var low: int = lo
		var high: int = max_px - 1
		while low <= high:
			var mid: int = (low + high) >> 1
			if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, mid).x <= max_w:
				chosen = mid
				low = mid + 1
			else:
				high = mid - 1
	if _font_fit_cache.size() >= 1024:
		_font_fit_cache.clear()
	_font_fit_cache[cache_key] = chosen
	return chosen

static func draw_fitted_text(canvas: CanvasItem, font: Font, pos: Vector2, text: String, align: HorizontalAlignment, max_w: float, max_px: int, col: Color, outline_col: Color, outline_px: int = 3, min_px: int = 11) -> int:
	if canvas == null or font == null or text.is_empty():
		return max_px
	var sz: int = fit_font_size(font, text, max_w, max_px, min_px)
	var width_arg: float = max_w if max_w > 0.0 else -1.0
	if outline_px > 0:
		canvas.draw_string_outline(font, pos, text, align, width_arg, sz, outline_px, outline_col)
	canvas.draw_string(font, pos, text, align, width_arg, sz, col)
	return sz
