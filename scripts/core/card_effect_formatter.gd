class_name CardEffectFormatter
extends RefCounted

static func format_effects(repo: GameRepository, engine: CombatEngine, card: Dictionary, bonus_upgrade_level: int = 0) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if repo == null or engine == null or card.is_empty():
		return results

	var in_combat_ctx: bool = (engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ENEMY_TURN)
	var upg_lvl: int = 0
	if engine is CombatEngine and engine.has_method("card_upgrade_level"):
		upg_lvl = mini(engine.max_card_upgrade_level(), engine.card_upgrade_level(card) + maxi(0, bonus_upgrade_level))
	if upg_lvl > 0:
		_append_effect(
			repo, results, "card_upgrade", "LVL %d" % upg_lvl, bonus_upgrade_level > 0,
			"UPGRADED (LVL %d)" % upg_lvl,
			"Bunker Foundry bonus: permanent damage and Shield"
		)

	var eval_gear: int = engine.effective_gear() if engine.has_method("effective_gear") else engine.current_gear
	var allowed: Array = card.get("allowed_gears", []) as Array
	var gear_compatible: bool = in_combat_ctx and contains_gear(allowed, eval_gear)
	var preview: Dictionary = engine.calculate_card_preview(card, true, bonus_upgrade_level)
	var is_aoe: bool = str(card.get("target_type", "self")) == "all_enemies"
	var tgt_label: String = "all enemies" if is_aoe else "target enemy"

	if bool(card.get("requires_redline", false)):
		var red_u: int = int(repo.get_gear(eval_gear).get("redline_rpm_units", 8))
		var in_red: bool = in_combat_ctx and engine.transmission.is_redline(eval_gear, engine.rpm_units)
		_append_effect(
			repo, results, "req_redline", "%dK+" % red_u if in_combat_ctx else "RED", in_red,
			"REDLINE ONLY (%dK+)" % red_u if in_combat_ctx else "REDLINE ONLY",
			"Playable only in Redline zone"
		)

	if bool(card.get("consume_all_rpm", false)):
		var cur_u: int = engine.rpm_units if in_combat_ctx else 0
		var consume_txt: String = ("-%d,000" % cur_u) if cur_u > 0 else "100%"
		_append_effect(
			repo, results, "rpm_consume_all", consume_txt, false,
			"DUMP RPM (%s)" % consume_txt,
			"Dumps all current engine RPM"
		)
	else:
		var base_rpm: int = int(card.get("rpm_delta_units", 0))
		var eff_rpm: int = int(preview.get("rpm_delta_units", base_rpm)) if gear_compatible else base_rpm
		if base_rpm > 0 or eff_rpm > 0:
			_append_effect(
				repo, results, "rpm_gain", "+%d,000" % eff_rpm, eff_rpm > base_rpm,
				"RPM +%d,000" % eff_rpm,
				"Increases engine RPM"
			)
		elif base_rpm < 0 or eff_rpm < 0:
			var cost_txt: String = ("%d,000" % eff_rpm) if eff_rpm < 0 else "0"
			_append_effect(
				repo, results, "rpm_cost", cost_txt, eff_rpm > base_rpm,
				"RPM %s" % cost_txt,
				"Consumes engine RPM"
			)

	var has_attack: bool = card.has("damage") or bool(card.get("damage_from_block", false)) or bool(card.get("consume_all_rpm", false)) or bool(card.get("consume_all_heat", false))
	if has_attack:
		var raw_dmg: int = int(card.get("damage", 0))
		var shown_dmg: int = int(preview.get("damage", raw_dmg)) if gear_compatible else _fallback_uncompatible_damage(repo, engine, card, raw_dmg, upg_lvl, in_combat_ctx)
		var hits: int = maxi(1, int(card.get("hits", 1)))
		var dmg_val: String = ("%dx%d" % [shown_dmg, hits]) if hits > 1 else str(shown_dmg)
		var is_ram: bool = bool(card.get("is_ram", false))
		var atk_kw: String = "ram" if is_ram else ("damage_aoe" if is_aoe else "damage")
		var is_boosted: bool = (gear_compatible and not bool(card.get("damage_from_block", false)) and not bool(card.get("consume_all_rpm", false)) and not bool(card.get("consume_all_heat", false)) and shown_dmg > raw_dmg) or (not in_combat_ctx and upg_lvl > 0)

		var headline_dmg: String = "%s DAMAGE" % dmg_val
		if bool(card.get("damage_from_block", false)):
			var base_plus_upg: int = raw_dmg + int(repo.gameplay().get("card_upgrade_damage_bonus", 2)) * upg_lvl
			headline_dmg = ("RAM %d (%d+SHD)" % [shown_dmg, base_plus_upg]) if is_ram else ("DAMAGE = %d+SHIELD (%d)" % [base_plus_upg, shown_dmg])
		elif bool(card.get("consume_all_rpm", false)):
			var per_u: int = int(card.get("damage_per_rpm_unit", 5))
			headline_dmg = "%dxRPM (%d DAMAGE)" % [per_u, shown_dmg]
		elif bool(card.get("consume_all_heat", false)):
			var per_h: int = int(card.get("damage_per_heat", 9))
			headline_dmg = "%dxHEAT (%d AOE)" % [per_h, shown_dmg]
		elif is_ram:
			headline_dmg = "RAM %s" % dmg_val
		elif is_aoe:
			headline_dmg = "AOE DAMAGE %s" % dmg_val

		_append_effect(repo, results, atk_kw, dmg_val, is_boosted, headline_dmg, "Strikes %s" % tgt_label)

		var red_bonus: int = int(card.get("redline_bonus_damage", 0))
		if red_bonus > 0:
			var in_red_b: bool = gear_compatible and engine.transmission.is_redline(eval_gear, engine.rpm_units)
			_append_effect(
				repo, results, "bonus_redline", "+%d" % red_bonus, in_red_b,
				"REDLINE: +%d DAMAGE" % red_bonus,
				"Bonus in Redline Zone"
			)

		var heat_bonus: int = int(card.get("high_heat_bonus_damage", 0))
		if heat_bonus > 0:
			var h_thresh: int = int(card.get("high_heat_threshold", 3))
			var in_heat_b: bool = gear_compatible and engine.heat >= h_thresh
			_append_effect(
				repo, results, "bonus_heat", "+%d" % heat_bonus, in_heat_b,
				"HEAT >=%d: +%d DAMAGE" % [h_thresh, heat_bonus],
				"Bonus with hot engine"
			)

		var shift_scale_d: int = int(card.get("damage_per_shift_this_turn", 0))
		if shift_scale_d > 0:
			var s_cnt: int = engine.shifts_this_turn if (in_combat_ctx and "shifts_this_turn" in engine) else 0
			_append_effect(
				repo, results, "shift_scale", "+%dx%d" % [shift_scale_d, s_cnt], s_cnt > 0,
				"+%d DAMAGE/SHIFT (%d)" % [shift_scale_d, shift_scale_d * s_cnt],
				"Scales with shifts this turn"
			)

	var base_blk: int = int(card.get("block", 0))
	var clean_upg_blk: int = base_blk + (int(repo.gameplay().get("card_upgrade_block_bonus", 3)) * upg_lvl if base_blk > 0 else 0)
	var shown_blk: int = int(preview.get("block", clean_upg_blk)) if gear_compatible else clean_upg_blk
	if base_blk > 0 or (gear_compatible and shown_blk > 0):
		var blk_boosted: bool = shown_blk > base_blk
		_append_effect(
			repo, results, "shield", "+%d" % shown_blk, blk_boosted,
			"SHIELD +%d" % shown_blk,
			"Blocks incoming damage this turn"
		)

	if card.has("set_gear"):
		var target_g: String = engine.transmission.gear_short_name(int(card.get("set_gear", 0)))
		_append_effect(
			repo, results, "set_gear", target_g, false,
			"FIXED GEAR: %s" % target_g,
			"Immediately engages %s" % target_g
		)
	elif not (card.get("choose_shift_options", []) as Array).is_empty():
		_append_effect(
			repo, results, "shift_choice", "+/-1/+/-2", false,
			"SHIFT CHOICE +/-1/+/-2",
			"Choose gear shift range"
		)
	elif int(card.get("gear_shift_delta", 0)) != 0:
		var s_delta: int = int(card.get("gear_shift_delta", 0))
		_append_effect(
			repo, results, "shift", "%+d" % s_delta, false,
			"SHIFT GEAR %+d" % s_delta,
			"Free gear shift"
		)

	var heat_d: int = int(card.get("heat_delta", 0))
	if heat_d > 0:
		_append_effect(
			repo, results, "heat_up", "+%d" % heat_d, false,
			"HEAT +%d" % heat_d,
			"Heats up engine"
		)
	elif heat_d < 0:
		_append_effect(
			repo, results, "heat_down", str(heat_d), false,
			"HEAT %d" % heat_d,
			"Cools engine"
		)

	var draw_n: int = int(card.get("draw_cards", 0))
	if draw_n > 0:
		var c_word: String = "CARD" if draw_n == 1 else "CARDS"
		_append_effect(
			repo, results, "draw", "+%d" % draw_n, false,
			"DRAW %d %s" % [draw_n, c_word],
			"Draws from magazine"
		)

	var weak_n: int = int(card.get("apply_weakness", 0))
	if weak_n > 0:
		var w_kw: String = "weakness_aoe" if is_aoe else "weakness"
		_append_effect(
			repo, results, w_kw, "%dT" % weak_n, false,
			"%s %dT" % ["AOE WEAKNESS" if is_aoe else "WEAKNESS", weak_n],
			"-25% enemy damage"
		)

	var vuln_n: int = int(card.get("apply_vulnerable", 0))
	if vuln_n > 0:
		var v_kw: String = "vulnerable_aoe" if is_aoe else "vulnerable"
		_append_effect(
			repo, results, v_kw, "%dT" % vuln_n, false,
			"%s %dT" % ["AOE VULNERABLE" if is_aoe else "VULNERABLE", vuln_n],
			"+50% damage taken by enemy"
		)

	if bool(card.get("retain_half_block", false)):
		_append_effect(
			repo, results, "retain_block", "50%", false,
			"RETAIN 50% SHIELD",
			"Retains half Shield next turn"
		)

	if bool(card.get("consume_all_heat", false)):
		_append_effect(
			repo, results, "heat_vent", "-%d" % engine.heat, engine.heat > 0,
			"DUMP HEAT (-%d)" % engine.heat,
			"Vents all engine Heat"
		)

	if bool(card.get("restore_free_shift", false)):
		var rng_b: int = int(card.get("free_shift_range_bonus", 0))
		var rng_str: String = "+/-%d" % (1 + rng_b)
		_append_effect(
			repo, results, "sync_reset", rng_str, not engine.free_shift_available or rng_b > 0,
			"FREE SHIFT %s" % rng_str if rng_b > 0 else "RESTORE FREE SHIFT",
			"Unlocks free manual shift %s" % rng_str
		)

	if bool(card.get("discard_low_gear_cards", false)):
		_append_effect(
			repo, results, "discard_low", "1st-2nd", false,
			"DISCARD GEARS 1ST-2ND",
			"Discards low-gear cards"
		)

	if bool(card.get("exhaust", false)):
		_append_effect(
			repo, results, "exhaust", "1x", false,
			"EXHAUST (1 USE)",
			"Single use in combat"
		)

	if bool(card.get("end_turn", false)):
		_append_effect(
			repo, results, "end_turn", "STOP", false,
			"END TURN",
			"Instantly ends turn"
		)

	return results

static func build_card_visual_model(repo: GameRepository, engine: CombatEngine, card: Dictionary, bonus_upgrade_level: int = 0) -> Dictionary:
	var model: Dictionary = {
		"upgrade_level": 0,
		"hero": {},
		"chips": [] as Array[Dictionary]
	}
	if repo == null or engine == null or card.is_empty():
		return model

	var in_combat_ctx: bool = (engine.mode == CombatEngine.MODE_COMBAT or engine.mode == CombatEngine.MODE_ENEMY_TURN)
	var upg_lvl: int = 0
	if engine is CombatEngine and engine.has_method("card_upgrade_level"):
		upg_lvl = mini(engine.max_card_upgrade_level(), engine.card_upgrade_level(card) + maxi(0, bonus_upgrade_level))
	model["upgrade_level"] = upg_lvl

	var eval_gear: int = engine.effective_gear() if engine.has_method("effective_gear") else engine.current_gear
	var allowed: Array = card.get("allowed_gears", []) as Array
	var gear_compatible: bool = in_combat_ctx and contains_gear(allowed, eval_gear)
	var preview: Dictionary = engine.calculate_card_preview(card, true, bonus_upgrade_level)
	var is_aoe: bool = str(card.get("target_type", "self")) == "all_enemies"
	var chips: Array[Dictionary] = []

	var has_attack: bool = card.has("damage") or bool(card.get("damage_from_block", false)) or bool(card.get("consume_all_rpm", false)) or bool(card.get("consume_all_heat", false))
	var base_blk: int = int(card.get("block", 0))
	var clean_upg_blk: int = base_blk + (int(repo.gameplay().get("card_upgrade_block_bonus", 3)) * upg_lvl if base_blk > 0 else 0)
	var shown_blk: int = int(preview.get("block", clean_upg_blk)) if gear_compatible else clean_upg_blk
	var has_shield: bool = base_blk > 0 or (gear_compatible and shown_blk > 0)
	var heat_d: int = int(card.get("heat_delta", 0))
	var base_rpm: int = int(card.get("rpm_delta_units", 0))
	var eff_rpm: int = int(preview.get("rpm_delta_units", base_rpm)) if gear_compatible else base_rpm
	var draw_n: int = int(card.get("draw_cards", 0))

	var hero: Dictionary = {}
	var used_primary: String = ""

	if has_attack:
		used_primary = "attack"
		var raw_dmg: int = int(card.get("damage", 0))
		var shown_dmg: int = int(preview.get("damage", raw_dmg)) if gear_compatible else _fallback_uncompatible_damage(repo, engine, card, raw_dmg, upg_lvl, in_combat_ctx)
		var hits: int = maxi(1, int(card.get("hits", 1)))
		var dmg_val: String = ("%dx%d" % [shown_dmg, hits]) if hits > 1 else str(shown_dmg)
		var is_ram: bool = bool(card.get("is_ram", false))
		var is_boosted: bool = (gear_compatible and not bool(card.get("damage_from_block", false)) and not bool(card.get("consume_all_rpm", false)) and not bool(card.get("consume_all_heat", false)) and shown_dmg > raw_dmg) or (not in_combat_ctx and upg_lvl > 0)
		var sub_lbl: String = "RAM" if is_ram else ("AOE DMG" if is_aoe else "DAMAGE")
		if bool(card.get("damage_from_block", false)):
			sub_lbl = "RAM +SHD" if is_ram else "DMG +SHD"
		elif bool(card.get("consume_all_rpm", false)):
			sub_lbl = "%dxRPM" % int(card.get("damage_per_rpm_unit", 5))
		elif bool(card.get("consume_all_heat", false)):
			sub_lbl = "%dxHEAT AOE" % int(card.get("damage_per_heat", 9))
		elif is_ram and is_aoe:
			sub_lbl = "AOE RAM"

		var bonus_txt: String = ""
		var bonus_act: bool = false
		var bonus_col: Color = repo.get_palette_color("selected_glow")
		var red_bonus: int = int(card.get("redline_bonus_damage", 0))
		var heat_bonus: int = int(card.get("high_heat_bonus_damage", 0))
		var shift_scale_d: int = int(card.get("damage_per_shift_this_turn", 0))
		if red_bonus > 0:
			bonus_txt = "REDLINE +%d" % red_bonus
			bonus_act = gear_compatible and engine.transmission.is_redline(eval_gear, engine.rpm_units)
			bonus_col = repo.get_palette_color("kw_redline")
		elif heat_bonus > 0:
			var h_thresh: int = int(card.get("high_heat_threshold", 3))
			bonus_txt = "TEMP >=%d: +%d" % [h_thresh, heat_bonus]
			bonus_act = gear_compatible and engine.heat >= h_thresh
			bonus_col = repo.get_palette_color("kw_heat_up")
		elif shift_scale_d > 0:
			var s_cnt: int = engine.shifts_this_turn if (in_combat_ctx and "shifts_this_turn" in engine) else 0
			bonus_txt = "+%d/SHIFT (%d)" % [shift_scale_d, shift_scale_d * s_cnt]
			bonus_act = s_cnt > 0
			bonus_col = repo.get_palette_color("kw_shift")

		hero = {
			"kind": "ram" if is_ram else ("damage_aoe" if is_aoe else "damage"),
			"value": dmg_val,
			"sublabel": sub_lbl,
			"color": repo.get_palette_color("kw_ram" if is_ram else "kw_damage"),
			"boosted": is_boosted,
			"bonus_text": bonus_txt,
			"bonus_active": bonus_act,
			"bonus_color": bonus_col
		}
	elif has_shield:
		used_primary = "shield"
		hero = {
			"kind": "shield",
			"value": "+%d" % shown_blk,
			"sublabel": "SHIELD",
			"color": repo.get_palette_color("kw_shield"),
			"boosted": shown_blk > base_blk,
			"bonus_text": "KEEP 50%" if bool(card.get("retain_half_block", false)) else "",
			"bonus_active": bool(card.get("retain_half_block", false)),
			"bonus_color": repo.get_palette_color("kw_shield")
		}
	elif heat_d < 0:
		used_primary = "heat_down"
		hero = {
			"kind": "heat_down",
			"value": str(heat_d),
			"sublabel": "COOLING",
			"color": repo.get_palette_color("kw_heat_down"),
			"boosted": false,
			"bonus_text": "",
			"bonus_active": false,
			"bonus_color": repo.get_palette_color("kw_heat_down")
		}
	elif eff_rpm > 0 and base_rpm >= 2:
		used_primary = "rpm_gain"
		hero = {
			"kind": "rpm_gain",
			"value": "+%dK" % eff_rpm,
			"sublabel": "RPM BOOST",
			"color": repo.get_palette_color("kw_rpm_up"),
			"boosted": eff_rpm > base_rpm,
			"bonus_text": "",
			"bonus_active": false,
			"bonus_color": repo.get_palette_color("kw_rpm_up")
		}
	elif draw_n > 0:
		used_primary = "draw"
		hero = {
			"kind": "draw",
			"value": "+%d" % draw_n,
			"sublabel": "CARD" if draw_n == 1 else "CARDS",
			"color": repo.get_palette_color("kw_draw"),
			"boosted": false,
			"bonus_text": "DROP 1-2" if bool(card.get("discard_low_gear_cards", false)) else "",
			"bonus_active": false,
			"bonus_color": repo.get_palette_color("kw_utility")
		}
	elif int(card.get("apply_weakness", 0)) > 0 or int(card.get("apply_vulnerable", 0)) > 0:
		used_primary = "debuff"
		var w_n: int = int(card.get("apply_weakness", 0))
		var v_n: int = int(card.get("apply_vulnerable", 0))
		hero = {
			"kind": "weakness" if w_n > 0 else "vulnerable",
			"value": "%dT" % (w_n if w_n > 0 else v_n),
			"sublabel": "WEAK" if w_n > 0 else "VULN",
			"color": repo.get_palette_color("kw_debuff"),
			"boosted": false,
			"bonus_text": ("VULN %dT" % v_n) if (w_n > 0 and v_n > 0) else "",
			"bonus_active": w_n > 0 and v_n > 0,
			"bonus_color": repo.get_palette_color("kw_debuff")
		}
	else:
		used_primary = "shift"
		hero = {
			"kind": "shift",
			"value": "SYNC",
			"sublabel": "SHIFT",
			"color": repo.get_palette_color("kw_shift"),
			"boosted": false,
			"bonus_text": "",
			"bonus_active": false,
			"bonus_color": repo.get_palette_color("kw_shift")
		}

	if bool(card.get("requires_redline", false)):
		var in_red_r: bool = in_combat_ctx and engine.transmission.is_redline(eval_gear, engine.rpm_units)
		_append_chip(repo, chips, "req_redline", "REDLINE!", in_red_r)

	if bool(card.get("consume_all_rpm", false)):
		_append_chip(repo, chips, "rpm_consume_all", "DUMP RPM", false)
	elif used_primary != "rpm_gain":
		if base_rpm > 0 or eff_rpm > 0:
			_append_chip(repo, chips, "rpm_gain", "+%dK RPM" % eff_rpm, eff_rpm > base_rpm)
		elif base_rpm < 0 or eff_rpm < 0:
			var r_txt: String = ("%dK RPM" % eff_rpm) if eff_rpm < 0 else "0 RPM"
			_append_chip(repo, chips, "rpm_cost", r_txt, eff_rpm > base_rpm)

	if used_primary != "shield" and has_shield:
		_append_chip(repo, chips, "shield", "+%d SHD" % shown_blk, shown_blk > base_blk)

	if card.has("set_gear"):
		var tg_s: String = engine.transmission.gear_short_name(int(card.get("set_gear", 0)))
		_append_chip(repo, chips, "set_gear", "GEAR %s" % tg_s, false)
	elif not (card.get("choose_shift_options", []) as Array).is_empty():
		_append_chip(repo, chips, "shift_choice", "SHIFT ±2", false)
	elif int(card.get("gear_shift_delta", 0)) != 0:
		_append_chip(repo, chips, "shift", "SHIFT %+d" % int(card.get("gear_shift_delta", 0)), false)

	if heat_d > 0:
		_append_chip(repo, chips, "heat_up", "+%d TEMP" % heat_d, false)
	elif heat_d < 0 and used_primary != "heat_down":
		_append_chip(repo, chips, "heat_down", "%d TEMP" % heat_d, false)

	if bool(card.get("consume_all_heat", false)):
		_append_chip(repo, chips, "heat_vent", "VENT %d" % engine.heat, engine.heat > 0)

	if draw_n > 0 and used_primary != "draw":
		_append_chip(repo, chips, "draw", "+%d CARD" % draw_n if draw_n == 1 else "+%d CARDS" % draw_n, false)

	if used_primary != "debuff":
		var w_c: int = int(card.get("apply_weakness", 0))
		if w_c > 0:
			_append_chip(repo, chips, "weakness_aoe" if is_aoe else "weakness", "WEAK %dT" % w_c, false)
		var v_c: int = int(card.get("apply_vulnerable", 0))
		if v_c > 0:
			_append_chip(repo, chips, "vulnerable_aoe" if is_aoe else "vulnerable", "VULN %dT" % v_c, false)

	if bool(card.get("restore_free_shift", false)):
		var rb: int = int(card.get("free_shift_range_bonus", 0))
		_append_chip(repo, chips, "sync_reset", "SYNC ±%d" % (1 + rb) if rb > 0 else "FREE SHIFT", not engine.free_shift_available or rb > 0)

	if bool(card.get("exhaust", false)):
		_append_chip(repo, chips, "exhaust", "1x USE", false)

	if bool(card.get("end_turn", false)):
		_append_chip(repo, chips, "end_turn", "END TURN", false)

	model["hero"] = hero
	model["chips"] = chips
	return model

static func _append_chip(repo: GameRepository, list: Array[Dictionary], kw_id: String, val_text: String, boosted: bool) -> void:
	var meta: Dictionary = repo.get_keyword_meta(kw_id)
	var c_key: String = str(meta.get("color_key", "kw_utility"))
	list.append({
		"keyword_id": kw_id,
		"value": val_text,
		"color": repo.get_palette_color(c_key, Color.WHITE),
		"boosted": boosted
	})

static func contains_gear(allowed: Array, gear_index: int) -> bool:
	for g_val: Variant in allowed:
		if int(g_val) == gear_index:
			return true
	return false

static func format_inline_summary(repo: GameRepository, engine: CombatEngine, card: Dictionary, bonus_upgrade_level: int = 0) -> String:
	var effects: Array[Dictionary] = format_effects(repo, engine, card, bonus_upgrade_level)
	var parts: PackedStringArray = PackedStringArray()
	for eff: Dictionary in effects:
		parts.append(str(eff.get("headline", "%s %s" % [str(eff.get("label", "")), str(eff.get("value", ""))])))
	return " • ".join(parts)

static func _fallback_uncompatible_damage(repo: GameRepository, engine: CombatEngine, card: Dictionary, raw_dmg: int, upg_lvl: int = 0, in_combat_ctx: bool = true) -> int:
	var upg_dmg: int = int(repo.gameplay().get("card_upgrade_damage_bonus", 2)) * upg_lvl
	if bool(card.get("damage_from_block", false)):
		return raw_dmg + upg_dmg + (engine.block if in_combat_ctx else 0)
	if bool(card.get("consume_all_rpm", false)):
		return (engine.rpm_units * int(card.get("damage_per_rpm_unit", 5)) if in_combat_ctx else 0) + upg_dmg
	if bool(card.get("consume_all_heat", false)):
		return (engine.heat * int(card.get("damage_per_heat", 9)) if in_combat_ctx else 0) + upg_dmg
	return raw_dmg + upg_dmg

static func _append_effect(
	repo: GameRepository,
	list: Array[Dictionary],
	kw_id: String,
	val_text: String,
	boosted: bool,
	headline_text: String = "",
	sub_text: String = ""
) -> void:
	var meta: Dictionary = repo.get_keyword_meta(kw_id)
	var c_key: String = str(meta.get("color_key", "kw_utility"))
	var lbl: String = str(meta.get("label", kw_id.to_upper()))
	var gls: String = str(meta.get("glossary", ""))
	list.append({
		"keyword_id": kw_id,
		"label": lbl,
		"value": val_text,
		"headline": headline_text if not headline_text.is_empty() else ("%s %s" % [lbl, val_text]),
		"subtext": sub_text if not sub_text.is_empty() else gls,
		"color": repo.get_palette_color(c_key, Color.WHITE),
		"boosted": boosted,
		"glossary": gls
	})

