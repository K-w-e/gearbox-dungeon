class_name OverheadPod3DController
extends Node3D

signal ticker_changed(text: String, mode: String)

const COLLISION_LAYER_COCKPIT: int = 2
const CONSUMABLE_KEYS: Array[String] = ["Z", "C", "V"]

var repo: GameRepository
var engine: CombatEngine

var screen_mesh: MeshInstance3D
var screen_area: Area3D
var vp_size: Vector2 = Vector2(1180.0, 142.0)
var world_size: Vector2 = Vector2(0.92, 0.106)

var visor_canvas: _OverheadVisorCanvas
var current_scanner_text: String = ""
var tutorial_objective_text: String = ""
var navigation_prompt_text: String = ""
var stall_warning_active: bool = false
var stall_warning_text: String = ""
var relic_flash_id: String = ""
var relic_flash_text: String = ""
var relic_flash_timer: float = 0.0

var item_hotspots: Array[Dictionary] = []
var hovered_hotspot_idx: int = -1

func initialize(repository: GameRepository, combat_engine: CombatEngine) -> void:
	repo = repository
	engine = combat_engine

	var pcfg: Dictionary = repo.cockpit.get("overhead_pod", {}) as Dictionary
	position = JsonConfigLoader.to_vec3(pcfg.get("pos", []), Vector3(0.0, 1.418, -0.52))
	rotation_degrees = JsonConfigLoader.to_vec3(pcfg.get("rot_deg", []), Vector3(19.0, 0.0, 0.0))

	var pod_scene: PackedScene = repo.load_model_scene("overhead_telemetry_pod")
	if pod_scene != null:
		var pod_inst: Node3D = pod_scene.instantiate() as Node3D
		pod_inst.scale = JsonConfigLoader.to_vec3(pcfg.get("pod_model_scale", []), Vector3(1.18, 1.04, 1.0))
		add_child(pod_inst)

	vp_size = JsonConfigLoader.to_vec2(pcfg.get("viewport_size", []), Vector2(1180.0, 142.0))
	world_size = JsonConfigLoader.to_vec2(pcfg.get("screen_size_m", []), Vector2(0.92, 0.106))
	var scr_off: Vector3 = JsonConfigLoader.to_vec3(pcfg.get("screen_offset", []), Vector3(0.0, 0.0, 0.022))

	var scr: Dictionary = DiegeticScreenFactory.create_screen(
		self,
		Vector2i(int(vp_size.x), int(vp_size.y)),
		world_size,
		scr_off,
		Vector3.ZERO,
		false,
		true
	)
	screen_mesh = scr.get("mesh") as MeshInstance3D
	current_scanner_text = ""
	visor_canvas = _OverheadVisorCanvas.new()
	visor_canvas.pod = self
	visor_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	(scr["root"] as Control).add_child(visor_canvas)

	screen_area = Area3D.new()
	screen_area.collision_layer = COLLISION_LAYER_COCKPIT
	screen_area.collision_mask = 0
	screen_area.position = scr_off + Vector3(0.0, 0.0, 0.008)
	screen_area.set_meta("interact_type", "overhead_pod_screen")
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(world_size.x * 1.04, world_size.y * 1.08, 0.026)
	cs.shape = box
	screen_area.add_child(cs)
	add_child(screen_area)

	engine.state_changed.connect(refresh_telemetry)
	engine.preview_gear_changed.connect(func(_g: int) -> void: refresh_telemetry())
	engine.relic_triggered.connect(_on_relic_triggered)
	refresh_telemetry()

func _on_relic_triggered(relic_id: String, relic_name: String, effect_text: String) -> void:
	relic_flash_id = relic_id
	relic_flash_text = "RELIC [%s]: %s" % [relic_name.to_upper(), effect_text.to_upper()]
	relic_flash_timer = 1.85
	refresh_telemetry()

func _process(delta: float) -> void:
	if relic_flash_timer > 0.0:
		relic_flash_timer = maxf(0.0, relic_flash_timer - delta)
		if relic_flash_timer <= 0.0:
			relic_flash_id = ""
			relic_flash_text = ""
			refresh_telemetry()

func set_scanner_text(text: String) -> void:
	if repo == null:
		return
	var clean: String = text.strip_edges()
	if current_scanner_text == clean:
		return
	current_scanner_text = clean
	refresh_telemetry()

func set_tutorial_objective(text: String) -> void:
	var clean: String = text.strip_edges()
	if tutorial_objective_text == clean:
		return
	tutorial_objective_text = clean
	refresh_telemetry()

func set_navigation_prompt(text: String) -> void:
	var clean: String = text.strip_edges()
	if navigation_prompt_text == clean:
		return
	navigation_prompt_text = clean
	refresh_telemetry()

func set_stall_warning(active: bool, text: String = "") -> void:
	var clean: String = text.strip_edges() if active else ""
	if stall_warning_active == active and stall_warning_text == clean:
		return
	stall_warning_active = active
	stall_warning_text = clean
	refresh_telemetry()

func resolve_ticker_state() -> Dictionary:
	if repo == null or engine == null:
		return {"text": "", "mode": "idle"}
	if not current_scanner_text.is_empty():
		return {"text": current_scanner_text, "mode": "scanner"}
	if relic_flash_timer > 0.0 and not relic_flash_text.is_empty():
		return {"text": relic_flash_text, "mode": "tutorial"}
	if not tutorial_objective_text.is_empty():
		return {"text": tutorial_objective_text, "mode": "tutorial"}
	if stall_warning_active and not stall_warning_text.is_empty() and engine.mode == CombatEngine.MODE_COMBAT:
		return {"text": stall_warning_text, "mode": "stall"}
	if not navigation_prompt_text.is_empty():
		return {"text": navigation_prompt_text, "mode": "nav"}
	var g_short: String = engine.transmission.gear_short_name(engine.current_gear)
	var g_role: String = str(repo.get_gear(engine.current_gear).get("role", "")).to_upper()
	var sync_str: String = repo.get_ui_text("hud", "shift_ready_badge") if engine.free_shift_available else repo.get_ui_text("hud", "shift_grind_badge")
	var txt: String = repo.get_ui_text("hud", "overhead_telemetry_fmt") % [
		g_short,
		g_role,
		engine.display_rpm(),
		engine.heat,
		engine.max_heat(),
		sync_str
	]
	return {"text": txt, "mode": "telemetry"}

func refresh_telemetry() -> void:
	if visor_canvas != null:
		DiegeticScreenFactory.request_redraw(visor_canvas)
	var st: Dictionary = resolve_ticker_state()
	ticker_changed.emit(str(st.get("text", "")), str(st.get("mode", "idle")))

func clear_hover() -> void:
	if hovered_hotspot_idx != -1:
		hovered_hotspot_idx = -1
		refresh_telemetry()

func world_pos_to_viewport(world_hit: Vector3) -> Vector2:
	if screen_mesh == null:
		return Vector2(-1.0, -1.0)
	var local: Vector3 = screen_mesh.to_local(world_hit)
	var u: float = (local.x / maxf(0.01, world_size.x)) + 0.5
	var v: float = 0.5 - (local.y / maxf(0.01, world_size.y))
	return Vector2(u * vp_size.x, v * vp_size.y)

func update_hover_world_pos(world_hit: Vector3) -> Dictionary:
	if repo == null or engine == null:
		return {}
	var pt: Vector2 = world_pos_to_viewport(world_hit)
	var found: int = -1
	for i: int in range(item_hotspots.size()):
		var hs: Dictionary = item_hotspots[i]
		var center: Vector2 = hs.get("center", Vector2.ZERO) as Vector2
		var rad: float = float(hs.get("radius", 22.0))
		if center.distance_to(pt) <= rad:
			found = i
			break
	if found != hovered_hotspot_idx:
		hovered_hotspot_idx = found
		refresh_telemetry()
	if found >= 0 and found < item_hotspots.size():
		return item_hotspots[found]
	return {}

func click_world_pos(world_hit: Vector3) -> bool:
	if repo == null or engine == null:
		return false
	var info: Dictionary = update_hover_world_pos(world_hit)
	if info.is_empty():
		return false
	if str(info.get("kind", "")) == "consumable":
		var s_idx: int = int(info.get("slot_index", -1))
		if s_idx >= 0 and s_idx < engine.owned_consumables.size():
			return engine.use_consumable(s_idx)
	return false


class _OverheadVisorCanvas extends Control:
	var pod: OverheadPod3DController

	func _draw() -> void:
		if pod == null or pod.repo == null or pod.engine == null:
			return
		var sz: Vector2 = size
		var rep: GameRepository = pod.repo
		var eng: CombatEngine = pod.engine
		var f_disp: Font = rep.get_font("display")
		var f_body: Font = rep.get_font("body_bold")
		var out_col: Color = rep.get_outline_color()

		var outer_r: Rect2 = Rect2(4.0, 3.0, sz.x - 8.0, sz.y - 6.0)
		var rim_col: Color = rep.get_palette_color("mfd_border")
		DiegeticScreenFactory.draw_industrial_plate(self, outer_r, rep, rim_col, 14.0, 2.4, true, 0.0, false)

		var pcfg: Dictionary = rep.cockpit.get("overhead_pod", {}) as Dictionary
		var enc: Dictionary = eng.current_encounter()
		var sec_title: String = str(enc.get("title", rep.get_ui_text("app_title", "app_title")))
		if eng.is_site_mode() and not eng.active_site_data.is_empty():
			sec_title = str(eng.active_site_data.get("title", sec_title))
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(28.0, 31.0),
			sec_title.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT,
			436.0,
			20,
			rep.get_palette_color("mfd_accent"),
			out_col,
			3,
			13
		)

		var tier_nodes: Array[Dictionary] = _collect_tier_nodes(rep, eng)
		var total_s: int = maxi(1, tier_nodes.size())
		var map_x0: float = float(pcfg.get("track_start_x", 34.0))
		var map_y: float = float(pcfg.get("track_y", 56.0))
		var max_w: float = maxf(80.0, float(pcfg.get("track_max_width", 412.0)))
		var step_m: float = minf(42.0, max_w / float(maxi(1, total_s - 1)))
		var track_col: Color = rep.get_palette_color("mfd_muted")
		var done_x: float = map_x0 + float(clampi(eng.stage_index, 0, total_s - 1)) * step_m
		draw_line(Vector2(map_x0, map_y), Vector2(map_x0 + float(total_s - 1) * step_m, map_y), Color(track_col.r, track_col.g, track_col.b, 0.35), 2.5)
		if eng.stage_index > 0:
			draw_line(Vector2(map_x0, map_y), Vector2(done_x, map_y), rep.get_palette_color("playable_glow") * 0.85, 3.5)

		var panel_bg: Color = rep.get_palette_color("mfd_panel_bg")
		var text_col: Color = rep.get_palette_color("mfd_text")
		for si: int in range(total_s):
			var s_dict: Dictionary = tier_nodes[si]
			var nc: Vector2 = Vector2(map_x0 + float(si) * step_m, map_y)
			var is_cur: bool = (si == eng.stage_index)
			var is_done: bool = (si < eng.stage_index)
			var nr: float = 13.5 if is_cur else 10.5
			var base_col: Color = rep.get_palette_color(RunMapGenerator.node_palette_key(s_dict))
			var ncol: Color = rep.get_palette_color("selected_glow") if is_cur else (rep.get_palette_color("playable_glow") if is_done else base_col * 0.88)

			if is_cur:
				draw_arc(nc, nr + 3.5, 0.0, TAU, 20, Color(ncol.r, ncol.g, ncol.b, 0.55), 2.0, true)
			draw_circle(nc, nr, panel_bg)
			draw_arc(nc, nr, 0.0, TAU, 20, ncol, 2.6 if is_cur else 1.8, true)
			Navigator3DController._NavigatorCanvas.draw_map_node_icon(self, nc, nr * 0.86, s_dict, text_col if is_cur else ncol.lightened(0.18), f_disp)

		var hx: float = 486.0
		var hy: float = 14.0
		var hp_ratio: float = clampf(float(eng.hp) / float(maxi(1, eng.max_hp)), 0.0, 1.0)
		var hp_col: Color = rep.get_palette_color("enemy_hp") if hp_ratio > 0.35 else rep.get_palette_color("redline_glow")
		var hull_lbl: String = rep.get_ui_text("hud", "overhead_hull_fmt") % [eng.hp, eng.max_hp]
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_disp,
			Vector2(hx, hy + 17.0),
			hull_lbl,
			HORIZONTAL_ALIGNMENT_LEFT,
			142.0,
			17,
			hp_col.lightened(0.24),
			out_col,
			3,
			12
		)

		var badge_txt: String = ""
		var badge_col: Color = rep.get_palette_color("playable_glow")
		if eng.shift_surge_active or eng.turn_torque_bonus > 0:
			var bonus: int = (int(rep.gameplay().get("manual_shift_damage_bonus", 3)) if eng.shift_surge_active else 0) + eng.turn_torque_bonus
			badge_txt = rep.get_ui_text("hud", "shift_surge_badge") % bonus
			badge_col = rep.get_palette_color("selected_glow")
		elif eng.free_shift_available:
			if eng.free_shift_bonus_range > 0:
				badge_txt = "SYNCHRO READY (+/-%d)" % (1 + eng.free_shift_bonus_range)
			else:
				badge_txt = rep.get_ui_text("hud", "shift_ready_badge")
			badge_col = rep.get_palette_color("playable_glow")
		else:
			badge_txt = rep.get_ui_text("hud", "shift_grind_badge")
			badge_col = rep.get_palette_color("slot_grind")
		var badge_r: Rect2 = Rect2(632.0, 11.0, 174.0, 24.0)
		DiegeticScreenFactory.draw_chamfer_rect(self, badge_r, 5.0, Color(badge_col.r * 0.2, badge_col.g * 0.18, badge_col.b * 0.12, 0.92), badge_col, 1.6)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body,
			Vector2(badge_r.position.x + 6.0, badge_r.position.y + 18.0),
			badge_txt,
			HORIZONTAL_ALIGNMENT_CENTER,
			badge_r.size.x - 12.0,
			15,
			badge_col.lightened(0.2),
			out_col,
			2,
			11
		)

		var segs: int = 12
		var seg_w: float = 22.5
		var seg_gap: float = 4.0
		for s: int in range(segs):
			var lit_s: bool = (float(s) / float(segs)) < hp_ratio and eng.hp > 0
			var sx_i: float = hx + float(s) * (seg_w + seg_gap)
			var sy_i: float = hy + 26.0
			var poly: PackedVector2Array = PackedVector2Array([
				Vector2(sx_i + 4.0, sy_i),
				Vector2(sx_i + seg_w, sy_i),
				Vector2(sx_i + seg_w - 4.0, sy_i + 22.0),
				Vector2(sx_i, sy_i + 22.0)
			])
			draw_colored_polygon(poly, hp_col * (0.94 if lit_s else 0.16))
			var closed_seg: PackedVector2Array = poly.duplicate()
			closed_seg.append(poly[0])
			draw_polyline(closed_seg, hp_col * 0.78, 1.3, true)

		var sh_c: Vector2 = Vector2(854.0, 44.0)
		var sh_col: Color = rep.get_palette_color("kw_shield")
		CardEmblemCanvas._s_draw_shield_shape(self, sh_c, 25.0, sh_col, Color(sh_col.r, sh_col.g, sh_col.b, 0.24))
		DiegeticScreenFactory.draw_fitted_text(self, f_body, sh_c + Vector2(30.0, -5.0), rep.get_ui_text("hud", "overhead_shield_lbl"), HORIZONTAL_ALIGNMENT_LEFT, 108.0, 14, sh_col, out_col, 2, 11)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, sh_c + Vector2(30.0, 20.0), "+%d" % eng.block, HORIZONTAL_ALIGNMENT_LEFT, 108.0, 25, text_col, out_col, 3, 14)

		var sc_c: Vector2 = Vector2(1022.0, 44.0)
		var sc_col: Color = rep.get_palette_color("selected_glow")
		CardEmblemCanvas._s_draw_gear_wheel(self, sc_c, 23.0, sc_col, 8)
		DiegeticScreenFactory.draw_fitted_text(self, f_body, sc_c + Vector2(30.0, -5.0), rep.get_ui_text("hud", "overhead_scrap_lbl"), HORIZONTAL_ALIGNMENT_LEFT, 108.0, 14, sc_col, out_col, 2, 11)
		DiegeticScreenFactory.draw_fitted_text(self, f_disp, sc_c + Vector2(30.0, 20.0), str(eng.scrap), HORIZONTAL_ALIGNMENT_LEFT, 108.0, 25, text_col, out_col, 3, 14)

		_draw_relics_and_consumables_row(sz, rep, eng, f_disp, f_body, out_col, panel_bg, text_col)

	func _draw_relics_and_consumables_row(
		sz: Vector2,
		rep: GameRepository,
		eng: CombatEngine,
		f_disp: Font,
		f_body: Font,
		out_col: Color,
		panel_bg: Color,
		text_col: Color
	) -> void:
		pod.item_hotspots.clear()
		var cy: float = 107.0
		var sock_r: float = 17.5
		var c_sel: Color = rep.get_palette_color("selected_glow")
		var c_play: Color = rep.get_palette_color("playable_glow")
		var c_muted: Color = rep.get_palette_color("mfd_muted")
		var c_red: Color = rep.get_palette_color("redline_glow")

		var max_relic_slots: int = maxi(4, eng.owned_relics.size())
		var rel_gap: float = minf(42.0, 184.0 / float(maxi(1, max_relic_slots - 1)))
		var rx0: float = 38.0
		for i: int in range(max_relic_slots):
			var rc: Vector2 = Vector2(rx0 + float(i) * rel_gap, cy)
			if i < eng.owned_relics.size():
				var rid: String = eng.owned_relics[i]
				var rdata: Dictionary = rep.get_relic(rid)
				var rname: String = str(rdata.get("name", rid))
				var rdesc: String = str(rdata.get("description", ""))
				var hs_idx: int = pod.item_hotspots.size()
				var is_hov: bool = (pod.hovered_hotspot_idx == hs_idx)
				var is_flashing: bool = (pod.relic_flash_timer > 0.0 and pod.relic_flash_id == rid)
				var r_col: Color = c_play if is_flashing else (text_col if is_hov else c_sel)
				var r_bg: Color = Color(r_col.r * 0.28, r_col.g * 0.22, r_col.b * 0.10, 0.95) if (is_flashing or is_hov) else panel_bg
				if is_flashing or is_hov:
					draw_arc(rc, sock_r + 3.5, 0.0, TAU, 20, Color(r_col.r, r_col.g, r_col.b, 0.75), 2.2, true)
				draw_circle(rc, sock_r, r_bg)
				draw_arc(rc, sock_r, 0.0, TAU, 20, r_col, 2.4 if (is_flashing or is_hov) else 1.8, true)
				_draw_relic_icon(rc, sock_r * 0.68, rid, r_col.lightened(0.22))
				pod.item_hotspots.append({
					"kind": "relic",
					"center": rc,
					"radius": sock_r + 4.0,
					"title": rname.to_upper(),
					"desc": rdesc,
					"color": c_sel
				})
			else:
				draw_circle(rc, sock_r * 0.82, Color(0.03, 0.035, 0.045, 0.55))
				draw_arc(rc, sock_r * 0.82, 0.0, TAU, 16, c_muted * 0.28, 1.2, true)

		var ticker: Dictionary = pod.resolve_ticker_state()
		var t_mode: String = str(ticker.get("mode", "telemetry"))
		var t_txt: String = str(ticker.get("text", ""))
		var tick_r: Rect2 = Rect2(248.0, 84.0, 762.0, 46.0)
		var t_brd: Color = rep.get_palette_color("mfd_border") * 0.75
		var t_fg: Color = c_muted.lightened(0.24)
		var t_bg: Color = panel_bg
		if t_mode == "stall":
			t_brd = c_red
			t_fg = c_red.lightened(0.28)
			t_bg = Color(c_red.r * 0.22, c_red.g * 0.06, c_red.b * 0.05, 0.96)
		elif t_mode == "tutorial":
			t_brd = c_play
			t_fg = c_sel.lightened(0.22)
			t_bg = Color(c_play.r * 0.16, c_play.g * 0.22, c_play.b * 0.10, 0.96)
		elif t_mode == "scanner":
			t_brd = c_sel
			t_fg = text_col
		elif t_mode == "nav":
			t_brd = rep.get_palette_color("mfd_accent")
			t_fg = t_brd.lightened(0.22)
		DiegeticScreenFactory.draw_chamfer_rect(self, tick_r, 6.0, t_bg, t_brd, 2.0 if t_mode != "telemetry" else 1.4)
		DiegeticScreenFactory.draw_fitted_text(
			self,
			f_body if t_mode == "telemetry" else f_disp,
			Vector2(tick_r.position.x + 12.0, tick_r.position.y + 30.0),
			t_txt,
			HORIZONTAL_ALIGNMENT_CENTER,
			tick_r.size.x - 24.0,
			17,
			t_fg,
			out_col,
			2,
			11
		)

		var max_slots: int = eng.max_consumable_slots()
		var cx_end: float = sz.x - 38.0
		var cx0: float = cx_end - float(max_slots - 1) * 50.0
		for s_idx: int in range(max_slots):
			var sc: Vector2 = Vector2(cx0 + float(s_idx) * 50.0, cy)
			var hs_idx: int = pod.item_hotspots.size()
			var is_hov: bool = (pod.hovered_hotspot_idx == hs_idx)
			var key_lbl: String = OverheadPod3DController.CONSUMABLE_KEYS[s_idx] if s_idx < OverheadPod3DController.CONSUMABLE_KEYS.size() else ""
			if s_idx < eng.owned_consumables.size():
				var cid: String = eng.owned_consumables[s_idx]
				var cdata: Dictionary = rep.get_consumable(cid)
				var cname: String = str(cdata.get("name", cid))
				var cdesc: String = str(cdata.get("description", ""))
				var c_col: Color = rep.get_palette_color(str(cdata.get("color_key", "playable_glow")))
				var rim: Color = text_col if is_hov else c_col
				var bg: Color = Color(c_col.r * 0.26, c_col.g * 0.22, c_col.b * 0.14, 0.96) if is_hov else panel_bg
				if is_hov:
					draw_arc(sc, sock_r + 4.0, 0.0, TAU, 20, Color(c_col.r, c_col.g, c_col.b, 0.85), 2.4, true)
				_draw_hex_socket(sc, sock_r, bg, rim, 2.5 if is_hov else 1.9)
				_draw_consumable_icon(sc, sock_r * 0.70, cid, c_col.lightened(0.24))
				if not key_lbl.is_empty():
					DiegeticScreenFactory.draw_fitted_text(self, f_disp, Vector2(sc.x - 14.0, sc.y + sock_r + 11.0), "[%s]" % key_lbl, HORIZONTAL_ALIGNMENT_CENTER, 28.0, 11, text_col, out_col, 2, 9)
				var title_with_key: String = ("%s [%s]" % [cname.to_upper(), key_lbl]) if not key_lbl.is_empty() else cname.to_upper()
				pod.item_hotspots.append({
					"kind": "consumable",
					"slot_index": s_idx,
					"center": sc,
					"radius": sock_r + 5.0,
					"title": title_with_key,
					"desc": cdesc,
					"color": c_col
				})
			else:
				_draw_hex_socket(sc, sock_r * 0.88, Color(0.03, 0.035, 0.045, 0.65), c_muted * 0.35, 1.3)
				pod.item_hotspots.append({
					"kind": "empty_consumable",
					"slot_index": s_idx,
					"center": sc,
					"radius": sock_r + 4.0,
					"title": "EMPTY CANISTER SLOT",
					"desc": "Salvage chemical canisters from post-combat rewards.",
					"color": c_muted
				})

	func _draw_hex_socket(c: Vector2, r: float, fill: Color, brd: Color, w: float) -> void:
		var pts: PackedVector2Array = PackedVector2Array()
		for k: int in range(6):
			var a: float = deg_to_rad(60.0 * float(k) - 30.0)
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(pts, fill)
		pts.append(pts[0])
		draw_polyline(pts, brd, w, true)

	func _draw_relic_icon(c: Vector2, r: float, relic_id: String, col: Color) -> void:
		match relic_id:
			"turbina_maggiorata":
				CardEmblemCanvas._s_draw_gear_wheel(self, c, r * 0.95, col, 8)
				draw_circle(c, r * 0.32, col.lightened(0.3))
			"radiatore_rame":
				for i: int in range(-2, 3):
					var x: float = c.x + float(i) * (r * 0.36)
					draw_line(Vector2(x, c.y - r * 0.72), Vector2(x, c.y + r * 0.72), col, 2.2)
				draw_rect(Rect2(c - Vector2(r * 0.8, r * 0.75), Vector2(r * 1.6, r * 1.5)), col, false, 2.0)
			"frizione_rinforzata":
				draw_arc(c, r * 0.85, 0.0, TAU, 18, col, 2.6, true)
				draw_arc(c, r * 0.42, 0.0, TAU, 14, col, 2.0, true)
			"volano_alleggerito":
				CardEmblemCanvas._s_draw_gear_wheel(self, c, r * 0.90, col, 6)
			"alternatore_corsa":
				var bolt: PackedVector2Array = PackedVector2Array([
					c + Vector2(r * 0.15, -r * 0.90),
					c + Vector2(-r * 0.55, r * 0.05),
					c + Vector2(r * 0.05, r * 0.05),
					c + Vector2(-r * 0.20, r * 0.90),
					c + Vector2(r * 0.55, -r * 0.08),
					c + Vector2(-r * 0.05, -r * 0.08)
				])
				draw_colored_polygon(bolt, col)
			"scambiatore_calore":
				CardEmblemCanvas._s_draw_shield_shape(self, c, r * 0.92, col, Color(col.r, col.g, col.b, 0.25))
			"paraurti_titanio":
				CardEmblemCanvas._s_draw_shield_shape(self, c, r * 0.95, col, Color(col.r, col.g, col.b, 0.35))
			"iniettore_pirotecnico":
				CardEmblemCanvas._s_draw_impact_burst(self, c, r * 0.95, col)
			_:
				CardEmblemCanvas._s_draw_gear_wheel(self, c + Vector2(-r * 0.28, -r * 0.22), r * 0.58, col, 6)
				CardEmblemCanvas._s_draw_gear_wheel(self, c + Vector2(r * 0.30, r * 0.24), r * 0.52, col.lightened(0.2), 6)

	func _draw_consumable_icon(c: Vector2, r: float, cons_id: String, col: Color) -> void:
		var body_r: Rect2 = Rect2(c.x - r * 0.52, c.y - r * 0.42, r * 1.04, r * 1.18)
		var cap_r: Rect2 = Rect2(c.x - r * 0.28, c.y - r * 0.76, r * 0.56, r * 0.32)
		draw_rect(cap_r, col.lightened(0.25), true)
		draw_rect(body_r, Color(col.r, col.g, col.b, 0.32), true)
		draw_rect(body_r, col, false, 2.2)
		var ic: Vector2 = c + Vector2(0.0, r * 0.16)
		match cons_id:
			"nitro_shot":
				var bolt: PackedVector2Array = PackedVector2Array([
					ic + Vector2(r * 0.10, -r * 0.42),
					ic + Vector2(-r * 0.28, r * 0.04),
					ic + Vector2(r * 0.04, r * 0.04),
					ic + Vector2(-r * 0.12, r * 0.42),
					ic + Vector2(r * 0.28, -r * 0.04),
					ic + Vector2(-r * 0.04, -r * 0.04)
				])
				draw_colored_polygon(bolt, col.lightened(0.35))
			"cryo_flush":
				draw_line(ic + Vector2(-r * 0.32, 0.0), ic + Vector2(r * 0.32, 0.0), col.lightened(0.35), 2.0)
				draw_line(ic + Vector2(0.0, -r * 0.32), ic + Vector2(0.0, r * 0.32), col.lightened(0.35), 2.0)
			"nanite_foam":
				draw_line(ic + Vector2(-r * 0.30, 0.0), ic + Vector2(r * 0.30, 0.0), col.lightened(0.38), 3.2)
				draw_line(ic + Vector2(0.0, -r * 0.30), ic + Vector2(0.0, r * 0.30), col.lightened(0.38), 3.2)
			"thermite_charge":
				CardEmblemCanvas._s_draw_impact_burst(self, ic, r * 0.42, col.lightened(0.35))
			"emp_flare":
				draw_arc(ic, r * 0.28, 0.0, TAU, 12, col.lightened(0.35), 2.0, true)
			_:
				draw_circle(ic, r * 0.24, col.lightened(0.35))

	func _collect_tier_nodes(rep: GameRepository, eng: CombatEngine) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		if eng.run_map_nodes.is_empty():
			for enc_d: Dictionary in rep.encounters:
				result.append(enc_d)
			return result

		var reachable: Array[String] = RunMapGenerator.compute_reachable_ids(eng.run_map_nodes, eng.current_map_node_id)
		var by_tier: Dictionary = {}
		var max_tier: int = 0
		var current_next: Array = []
		for nd: Dictionary in eng.run_map_nodes:
			var stg: int = int(nd.get("stage_index", 0))
			max_tier = maxi(max_tier, stg)
			if not by_tier.has(stg):
				by_tier[stg] = []
			(by_tier[stg] as Array).append(nd)
			if str(nd.get("id", "")) == eng.current_map_node_id:
				current_next = nd.get("next_ids", []) as Array

		for ti: int in range(max_tier + 1):
			var bucket: Array = by_tier.get(ti, []) as Array
			if bucket.is_empty():
				result.append({"type": "combat"})
				continue
			var chosen: Dictionary = bucket[0] as Dictionary
			for cand_v: Variant in bucket:
				var cand: Dictionary = cand_v as Dictionary
				var cid: String = str(cand.get("id", ""))
				if reachable.has(cid):
					chosen = cand
					break
			for cand_v: Variant in bucket:
				var cand: Dictionary = cand_v as Dictionary
				var cid: String = str(cand.get("id", ""))
				if cid == eng.current_map_node_id or eng.visited_map_node_ids.has(cid):
					chosen = cand
					break
				if current_next.has(cid):
					chosen = cand
			result.append(chosen)
		return result
