class_name CombatEngine
extends Node

signal state_changed
signal gear_shifted(old_gear: int, new_gear: int, was_grind: bool)
signal card_played_fx(card_data: Dictionary, target_index: int)
signal enemy_hit_fx(enemy_index: int, amount: int, blocked: bool)
signal player_hit_fx(amount: int, is_overheat: bool)
signal sfx_requested(sfx_id: String, intensity: float)
signal camera_trauma_requested(amount: float)
signal event_logged(message: String)
signal shift_choice_requested(card_hand_index: int, options: Array)
signal reward_cards_offered(choices: Array)
signal route_choices_offered(options: Array)
signal route_transition_started(option_index: int, chosen_option: Dictionary)
signal enemy_action_started(enemy_index: int, move_name: String)
signal floating_text_requested(target_enemy_index: int, text: String, color: Color)
signal preview_gear_changed(gear_idx: int)
signal relic_triggered(relic_id: String, relic_name: String, effect_text: String)
signal workshop_opened
signal encounter_site_opened(site_data: Dictionary)
signal card_burned(card_id: String)
signal consumable_used(consumable_id: String)
signal run_ended(victory: bool, summary: String)

const MODE_COMBAT: String = "combat"
const MODE_ENEMY_TURN: String = "enemy_turn"
const MODE_SHIFT_CHOICE: String = "shift_choice"
const MODE_REWARD: String = "reward"
const MODE_ROUTE_CHOICE: String = "route_choice"
const MODE_ROUTE_TRANSITION: String = "route_transition"
const MODE_WORKSHOP: String = "workshop"
const MODE_REST: String = "rest"
const MODE_UPGRADE: String = "upgrade"
const MODE_EVENT: String = "event"
const MODE_GAME_OVER: String = "game_over"
const MODE_VICTORY: String = "victory"
const MODE_TITLE: String = "title"
const ACTIVE_RUN_SAVE_PATH: String = "user://active_run.json"

var repo: GameRepository
var transmission: TransmissionSystem
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

var mode: String = MODE_TITLE
var stage_index: int = 0
var turn_number: int = 1
var selected_chassis_id: String = "interceptor"
var overdrive_level: int = 0

var hp: int = 0
var max_hp: int = 0
var block: int = 0
var rpm_units: int = 0
var heat: int = 0
var base_max_heat: int = 0
var current_gear: int = 1
var free_shift_available: bool = true
var scrap: int = 0
var shifts_this_turn: int = 0
var rev_match_used_this_turn: bool = false
var retain_half_block_next_turn: bool = false
var shift_surge_active: bool = false
var preview_gear_override: int = -99
var free_shift_bonus_range: int = 0
var turn_torque_bonus: int = 0
var turns_in_same_gear: int = 0

var puncture_turns: int = 0
var gear_lock_max: int = -99
var gear_lock_min: int = -99
var ranged_dodge_charges: int = 0
var pending_draw_penalty: int = 0

var enemy_turn_queue: Array[int] = []
var enemy_turn_timer: float = 0.0
var active_acting_enemy_index: int = -1
var route_options: Array[Dictionary] = []
var run_map_nodes: Array[Dictionary] = []
var current_map_node_id: String = ""
var visited_map_node_ids: Array[String] = []
var pending_route_node_id: String = ""
var pending_route_option: Dictionary = {}
var pending_route_option_index: int = -1
var active_site_data: Dictionary = {}
var site_selecting_deck_action: String = ""
var pending_site_choice: Dictionary = {}
var last_elite_relic_reward: String = ""
var pending_reward_consumable: String = ""
var reward_cards_pre_upgraded: bool = false

var tutorial_active: bool = false
var owned_relics: Array[String] = []
var owned_consumables: Array[String] = []
var upgrade_levels: Dictionary = {}
var resolved_encounter: Dictionary = {}
var master_deck: Array[String] = []
var draw_pile: Array[String] = []
var hand: Array[String] = []
var discard_pile: Array[String] = []
var exhaust_pile: Array[String] = []

var enemies: Array[Dictionary] = []
var reward_choices: Array[String] = []
var workshop_card_offer: String = ""
var workshop_relic_offer: String = ""
var workshop_card_offers: Array[Dictionary] = []
var workshop_relic_offers: Array[Dictionary] = []
var workshop_reroll_count: int = 0
var workshop_remove_count: int = 0
var pending_shift_card_hand_index: int = -1
var combat_log: Array[String] = []
var sim_paused: bool = false

func initialize(repository: GameRepository) -> void:
	repo = repository
	transmission = TransmissionSystem.new(repo)
	rng.randomize()
	enter_title_screen()

func enter_title_screen() -> void:
	mode = MODE_TITLE
	tutorial_active = false
	sim_paused = false
	combat_log.clear()
	_log_event(repo.get_ui_text("combat", "welcome_log"))
	state_changed.emit()

func start_tutorial_run() -> void:
	start_new_run(selected_chassis_id, overdrive_level)

func start_new_run(chassis_id: String = "", od_level: int = -1) -> void:
	if not chassis_id.is_empty():
		selected_chassis_id = chassis_id
	if od_level >= 0:
		overdrive_level = clampi(od_level, 0, 5)
	tutorial_active = false
	_reset_run_state()
	run_map_nodes = RunMapGenerator.generate_run_dag(repo, rng)
	if not run_map_nodes.is_empty():
		_enter_map_node(run_map_nodes[0])
		return
	_load_stage(stage_index)

func get_chassis_preset(chassis_id: String) -> Dictionary:
	var presets: Array = repo.gameplay().get("chassis_presets", []) as Array
	for entry: Variant in presets:
		if typeof(entry) == TYPE_DICTIONARY and str((entry as Dictionary).get("id", "")) == chassis_id:
			return entry as Dictionary
	return presets[0] as Dictionary if not presets.is_empty() else {}

func _reset_run_state() -> void:
	var gp: Dictionary = repo.gameplay()
	var preset: Dictionary = get_chassis_preset(selected_chassis_id) if not tutorial_active else {}
	max_hp = int(preset.get("max_hp", gp.get("max_hp", 70)))
	hp = max_hp
	base_max_heat = int(gp.get("max_heat", 5))
	scrap = int(preset.get("starting_scrap", gp.get("starting_scrap", 45)))
	owned_relics.clear()
	var start_rel: String = str(preset.get("starting_relic", ""))
	if not start_rel.is_empty() and not repo.get_relic(start_rel).is_empty():
		owned_relics.append(start_rel)
	owned_consumables.clear()
	var start_cons: String = str(preset.get("starting_consumable", "nitro_shot"))
	if not start_cons.is_empty() and not repo.get_consumable(start_cons).is_empty():
		owned_consumables.append(start_cons)
	upgrade_levels.clear()
	master_deck.clear()
	var starter_list: Array = preset.get("starter_deck", gp.get("starter_deck", [])) as Array
	for cid_val: Variant in starter_list:
		var cid: String = str(cid_val)
		if not repo.get_card(cid).is_empty():
			master_deck.append(cid)
	var bonus_cards: Array = preset.get("bonus_cards", []) as Array
	for bc_val: Variant in bonus_cards:
		var bc_id: String = str(bc_val)
		if not repo.get_card(bc_id).is_empty():
			master_deck.append(bc_id)
	combat_log.clear()
	stage_index = 0
	pending_draw_penalty = 0
	retain_half_block_next_turn = false
	shift_surge_active = false
	enemy_turn_queue.clear()
	active_acting_enemy_index = -1
	route_options.clear()
	run_map_nodes.clear()
	current_map_node_id = ""
	visited_map_node_ids.clear()
	pending_route_node_id = ""
	pending_route_option.clear()
	pending_route_option_index = -1
	active_site_data.clear()
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	last_elite_relic_reward = ""
	pending_reward_consumable = ""
	reward_cards_pre_upgraded = false

func max_heat() -> int:
	var bonus: int = 0
	for rid: String in owned_relics:
		var rdata: Dictionary = repo.get_relic(rid)
		bonus += int(rdata.get("max_heat_bonus", 0))
	var od_pen: int = 1 if (not tutorial_active and overdrive_level >= 3) else 0
	return maxi(3, base_max_heat + bonus - od_pen)

func has_grind_immunity() -> bool:
	for rid: String in owned_relics:
		if bool(repo.get_relic(rid).get("grind_hull_immune", false)):
			return true
	return false

func display_rpm() -> int:
	return rpm_units * int(repo.gameplay().get("rpm_display_multiplier", 1000))

func current_encounter() -> Dictionary:
	return resolved_encounter

func _resolve_encounter_variant(base_enc: Dictionary) -> Dictionary:
	var variants: Array = base_enc.get("variants", []) as Array
	if variants.is_empty():
		return base_enc
	var chosen: Variant = variants[rng.randi_range(0, variants.size() - 1)]
	if typeof(chosen) != TYPE_DICTIONARY:
		return base_enc
	var chosen_dict: Dictionary = chosen as Dictionary
	var merged: Dictionary = base_enc.duplicate()
	merged.erase("variants")
	merged["title"] = str(chosen_dict.get("title", base_enc.get("title", "Sector")))
	merged["enemies"] = chosen_dict.get("enemies", base_enc.get("enemies", []) as Array)
	return merged

func has_stall_risk() -> bool:
	return mode == MODE_COMBAT and transmission.is_stall_risk(current_gear, rpm_units)

func card_upgrade_level(card: Dictionary) -> int:
	if card.is_empty() or not card.has("id"):
		return 0
	return maxi(0, int(upgrade_levels.get(str(card.get("id", "")), 0)))

func max_card_upgrade_level() -> int:
	return int(repo.gameplay().get("card_upgrade_max_level", 2))

func upgradeable_card_ids() -> Array[String]:
	var result: Array[String] = []
	var max_lvl: int = max_card_upgrade_level()
	for cid: String in master_deck:
		if result.has(cid):
			continue
		if int(upgrade_levels.get(cid, 0)) < max_lvl:
			result.append(cid)
	return result

func upgrade_reward_card(card_id: String) -> bool:
	if mode != MODE_REWARD:
		return false
	if not master_deck.has(card_id):
		sfx_requested.emit("blocked", 0.5)
		return false
	if int(upgrade_levels.get(card_id, 0)) >= max_card_upgrade_level():
		sfx_requested.emit("blocked", 0.5)
		return false
	upgrade_levels[card_id] = int(upgrade_levels.get(card_id, 0)) + 1
	var lvl: int = int(upgrade_levels[card_id])
	var dmg_bonus: int = int(repo.gameplay().get("card_upgrade_damage_bonus", 2)) * lvl
	var blk_bonus: int = int(repo.gameplay().get("card_upgrade_block_bonus", 3)) * lvl
	_log_event("BUNKER FOUNDRY: %s upgraded to Power %d (+%d damage, +%d Shield)!" % [
		str(repo.get_card(card_id).get("name", card_id)), lvl, dmg_bonus, blk_bonus
	])
	reward_choices.clear()
	last_elite_relic_reward = ""
	reward_cards_pre_upgraded = false
	_advance_to_stage_or_route(stage_index + 1)
	return true

func active_fork_node_ids() -> Array[String]:
	var ids: Array[String] = []
	for opt: Dictionary in route_options:
		var nid: String = str(opt.get("map_node_id", ""))
		if not nid.is_empty():
			ids.append(nid)
	return ids

func is_site_mode() -> bool:
	return mode == MODE_REST or mode == MODE_UPGRADE or mode == MODE_EVENT

func _enter_map_node(node_dict: Dictionary) -> void:
	if node_dict.is_empty():
		_load_stage(stage_index)
		return
	var nid: String = str(node_dict.get("id", ""))
	if not nid.is_empty():
		current_map_node_id = nid
		if not visited_map_node_ids.has(nid):
			visited_map_node_ids.append(nid)
	stage_index = int(node_dict.get("stage_index", stage_index))
	resolved_encounter = (node_dict.get("encounter", {}) as Dictionary).duplicate(true)
	_dispatch_encounter(resolved_encounter, node_dict)
	save_active_run()

func _dispatch_encounter(enc: Dictionary, map_node: Dictionary = {}) -> void:
	resolved_encounter = enc.duplicate(true)
	active_site_data.clear()
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	var enc_type: String = str(enc.get("type", "combat"))
	if enc_type == "workshop":
		_log_event(">> %s <<" % str(enc.get("title", "")))
		_open_workshop()
		return
	if enc_type == "rest":
		var r_data: Dictionary = repo.rest_site().duplicate(true)
		resolved_encounter["title"] = str(r_data.get("title", enc.get("title", "")))
		_log_event(">> %s <<" % str(resolved_encounter.get("title", "")))
		_open_site(MODE_REST, r_data)
		return
	if enc_type == "upgrade":
		var u_data: Dictionary = repo.upgrade_site().duplicate(true)
		resolved_encounter["title"] = str(u_data.get("title", enc.get("title", "")))
		_log_event(">> %s <<" % str(resolved_encounter.get("title", "")))
		_open_site(MODE_UPGRADE, u_data)
		return
	if enc_type == "event":
		var ev_id: String = str(enc.get("event_id", map_node.get("event_id", "")))
		var ev_data: Dictionary = repo.get_random_event(ev_id).duplicate(true)
		var rev_title: String = str(ev_data.get("title", enc.get("revealed_title", enc.get("title", ""))))
		resolved_encounter["title"] = rev_title
		resolved_encounter["model_key"] = str(ev_data.get("model_key", enc.get("model_key", "")))
		if not map_node.is_empty():
			map_node["title"] = rev_title
		_log_event(">> %s <<" % rev_title)
		_open_site(MODE_EVENT, ev_data)
		return
	_log_event(">> %s <<" % str(enc.get("title", "")))
	_setup_combat_encounter(enc)

func _open_site(target_mode: String, site_dict: Dictionary) -> void:
	mode = target_mode
	enemies.clear()
	hand.clear()
	active_site_data = site_dict
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	var idle_rpm: int = clampi(maxi(rpm_units, 2), transmission.min_rpm_units(), transmission.max_rpm_units())
	rpm_units = idle_rpm
	sfx_requested.emit("air_brake", 0.72)
	encounter_site_opened.emit(active_site_data)
	state_changed.emit()

func evaluate_site_choice(choice_index: int) -> Dictionary:
	var res: Dictionary = {"allowed": false, "reason": ""}
	if not is_site_mode():
		return res
	var choices: Array = active_site_data.get("choices", []) as Array
	if choice_index < 0 or choice_index >= choices.size() or typeof(choices[choice_index]) != TYPE_DICTIONARY:
		return res
	var ch: Dictionary = choices[choice_index] as Dictionary
	var req_sc: int = int(ch.get("req_scrap", 0))
	if req_sc > 0 and scrap < req_sc:
		res["reason"] = repo.get_ui_text("sites", "choice_locked_scrap") % req_sc
		return res
	var min_hp_req: int = int(ch.get("min_hp_required", 0))
	if min_hp_req > 0 and hp < min_hp_req:
		res["reason"] = repo.get_ui_text("sites", "choice_locked_hp") % (min_hp_req - 1)
		return res
	if bool(ch.get("require_missing_hp", false)) and hp >= max_hp:
		res["reason"] = repo.get_ui_text("sites", "choice_locked_full_hp")
		return res
	if bool(ch.get("open_card_upgrade", false)) and upgradeable_card_ids().is_empty():
		res["reason"] = repo.get_ui_text("sites", "choice_locked_deck")
		return res
	if int(ch.get("upgrade_random_cards", 0)) > 0 and upgradeable_card_ids().is_empty() and mode == MODE_UPGRADE:
		res["reason"] = repo.get_ui_text("sites", "choice_locked_deck")
		return res
	var min_deck: int = int((repo.gameplay().get("run_map", {}) as Dictionary).get("min_deck_size_for_remove", 4))
	if bool(ch.get("open_card_remove", false)) and master_deck.size() <= min_deck:
		res["reason"] = repo.get_ui_text("sites", "choice_locked_deck")
		return res
	res["allowed"] = true
	return res

func execute_site_choice(choice_index: int) -> bool:
	var eval: Dictionary = evaluate_site_choice(choice_index)
	if not bool(eval.get("allowed", false)):
		var r_txt: String = str(eval.get("reason", ""))
		if not r_txt.is_empty():
			_log_event(r_txt)
		sfx_requested.emit("blocked", 0.55)
		state_changed.emit()
		return false

	var choices: Array = active_site_data.get("choices", []) as Array
	var ch: Dictionary = (choices[choice_index] as Dictionary).duplicate(true)
	if bool(ch.get("open_card_upgrade", false)):
		pending_site_choice = ch
		site_selecting_deck_action = "upgrade"
		sfx_requested.emit("switch_click", 0.85)
		state_changed.emit()
		return true
	if bool(ch.get("open_card_remove", false)):
		pending_site_choice = ch
		site_selecting_deck_action = "remove"
		sfx_requested.emit("switch_click", 0.85)
		state_changed.emit()
		return true

	_apply_site_choice_effects(ch)
	_finish_site_and_advance()
	return true

func cancel_site_deck_selection() -> void:
	if not is_site_mode() or site_selecting_deck_action.is_empty():
		return
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	sfx_requested.emit("switch_click", 0.65)
	state_changed.emit()

func resolve_site_deck_upgrade(card_id: String) -> bool:
	if not is_site_mode() or site_selecting_deck_action != "upgrade":
		return false
	if not master_deck.has(card_id) or int(upgrade_levels.get(card_id, 0)) >= max_card_upgrade_level():
		sfx_requested.emit("blocked", 0.5)
		return false
	var ch: Dictionary = pending_site_choice.duplicate(true)
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	_apply_site_choice_effects(ch)
	upgrade_levels[card_id] = int(upgrade_levels.get(card_id, 0)) + 1
	var lvl: int = int(upgrade_levels[card_id])
	_log_event("FORGE CALIBRATION: %s upgraded to Power %d!" % [str(repo.get_card(card_id).get("name", card_id)), lvl])
	sfx_requested.emit("shift_clack", 0.95)
	_finish_site_and_advance()
	return true

func resolve_site_deck_remove(deck_index: int) -> bool:
	if not is_site_mode() or site_selecting_deck_action != "remove":
		return false
	var min_deck: int = int((repo.gameplay().get("run_map", {}) as Dictionary).get("min_deck_size_for_remove", 4))
	if master_deck.size() <= min_deck or deck_index < 0 or deck_index >= master_deck.size():
		sfx_requested.emit("blocked", 0.5)
		return false
	var ch: Dictionary = pending_site_choice.duplicate(true)
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	_apply_site_choice_effects(ch)
	var removed_id: String = master_deck[deck_index]
	master_deck.remove_at(deck_index)
	_log_event("FIELD-STRIP: Removed %s from deck!" % str(repo.get_card(removed_id).get("name", removed_id)))
	sfx_requested.emit("grind", 0.75)
	_finish_site_and_advance()
	return true

func _apply_site_choice_effects(ch: Dictionary) -> void:
	var max_hp_d: int = int(ch.get("max_hp_delta", 0))
	if max_hp_d != 0:
		max_hp = maxi(10, max_hp + max_hp_d)
		if max_hp_d > 0:
			_log_event("Chassis reinforced: +%d Max Hull HP!" % max_hp_d)

	var heal_pct: float = float(ch.get("heal_pct", 0.0))
	if heal_pct > 0.0:
		var pct_amt: int = maxi(1, roundi(float(max_hp) * heal_pct))
		hp = mini(max_hp, hp + pct_amt)
		_log_event("Emergency welding: +%d Hull HP restored!" % pct_amt)
		sfx_requested.emit("shield", 0.85)

	var hp_d: int = int(ch.get("hp_delta", 0))
	if hp_d > 0:
		hp = mini(max_hp, hp + hp_d)
		_log_event("Hull patched: +%d HP!" % hp_d)
		sfx_requested.emit("shield", 0.8)
	elif hp_d < 0:
		hp = maxi(1, hp + hp_d)
		_log_event("Hazard impact: %d Hull HP!" % hp_d)
		sfx_requested.emit("player_hit", 0.8)
		camera_trauma_requested.emit(0.32)

	var sc_d: int = int(ch.get("scrap_delta", 0))
	if sc_d != 0:
		scrap = maxi(0, scrap + sc_d)
		if sc_d > 0:
			_log_event("Salvaged +%d Scrap!" % sc_d)

	if bool(ch.get("grant_random_card", false)):
		var c_pool: Array[String] = _non_starter_card_pool()
		if not c_pool.is_empty():
			var new_cid: String = c_pool[0]
			master_deck.append(new_cid)
			_log_event("Recovered module: %s added to deck!" % str(repo.get_card(new_cid).get("name", new_cid)))
			sfx_requested.emit("card_play", 0.85)

	if bool(ch.get("grant_random_relic", false)):
		var granted_rel: String = _grant_random_unowned_relic()
		if not granted_rel.is_empty():
			_log_event("Relic Vault breached: %s installed!" % str(repo.get_relic(granted_rel).get("name", granted_rel)))
			sfx_requested.emit("victory_chime", 0.85)

	var rand_upg_cnt: int = int(ch.get("upgrade_random_cards", 0))
	if rand_upg_cnt > 0:
		for _u: int in range(rand_upg_cnt):
			var upg_pool: Array[String] = upgradeable_card_ids()
			if upg_pool.is_empty():
				break
			_shuffle_strings(upg_pool)
			var u_cid: String = upg_pool[0]
			upgrade_levels[u_cid] = int(upgrade_levels.get(u_cid, 0)) + 1
			_log_event("Overbored %s -> Power %d!" % [str(repo.get_card(u_cid).get("name", u_cid)), int(upgrade_levels[u_cid])])
		sfx_requested.emit("shift_clack", 0.9)

func _finish_site_and_advance() -> void:
	active_site_data.clear()
	site_selecting_deck_action = ""
	pending_site_choice.clear()
	_advance_to_stage_or_route(stage_index + 1)

func _grant_random_unowned_relic() -> String:
	var r_pool: Array[String] = []
	for rdict: Dictionary in repo.all_relics:
		var rid: String = str(rdict.get("id", ""))
		if not rid.is_empty() and not owned_relics.has(rid):
			r_pool.append(rid)
	if r_pool.is_empty():
		var fb_scrap: int = int((repo.gameplay().get("run_map", {}) as Dictionary).get("fallback_relic_scrap_bonus", 35))
		scrap += fb_scrap
		_log_event("All relics owned: salvaged +%d bonus Scrap instead!" % fb_scrap)
		return ""
	_shuffle_strings(r_pool)
	var chosen_rid: String = r_pool[0]
	owned_relics.append(chosen_rid)
	return chosen_rid

func _non_starter_card_pool() -> Array[String]:
	var early_pool: Array[String] = []
	var advanced_pool: Array[String] = []
	for card_dict: Dictionary in repo.all_cards:
		if bool(card_dict.get("starter", false)) or str(card_dict.get("category", "")) == "Starter":
			continue
		var cid: String = str(card_dict.get("id", ""))
		var gears: Array = card_dict.get("allowed_gears", []) as Array
		var is_high_payoff: bool = bool(card_dict.get("exhaust", false)) or bool(card_dict.get("consume_all_rpm", false)) or bool(card_dict.get("consume_all_heat", false)) or bool(card_dict.get("requires_redline", false)) or int(card_dict.get("damage_per_shift_this_turn", 0)) > 0 or ( not gears.has(1) and not gears.has(2) )
		if is_high_payoff:
			advanced_pool.append(cid)
		else:
			early_pool.append(cid)
	_shuffle_strings(early_pool)
	_shuffle_strings(advanced_pool)
	var is_late_or_elite: bool = (stage_index >= 3) or bool(current_encounter().get("is_elite", false))
	var combined: Array[String] = []
	if is_late_or_elite:
		for i: int in range(maxi(advanced_pool.size(), early_pool.size())):
			if i < advanced_pool.size():
				combined.append(advanced_pool[i])
			if i < early_pool.size():
				combined.append(early_pool[i])
	else:
		combined.append_array(early_pool)
		combined.append_array(advanced_pool)
	return combined

func effective_gear() -> int:
	if mode == MODE_COMBAT and preview_gear_override >= -1 and preview_gear_override <= 6:
		return preview_gear_override
	return current_gear

func set_preview_gear(gear_idx: int) -> void:
	var clean: int = gear_idx if (gear_idx >= -1 and gear_idx <= 6) else -99
	if preview_gear_override == clean:
		return
	preview_gear_override = clean
	preview_gear_changed.emit(effective_gear())

func _notify_relic_triggered(relic_id: String, effect_text: String) -> void:
	var rdata: Dictionary = repo.get_relic(relic_id)
	var rname: String = str(rdata.get("name", relic_id))
	relic_triggered.emit(relic_id, rname, effect_text)

func max_consumable_slots() -> int:
	return maxi(1, int(repo.gameplay().get("max_consumables", 3)))

func add_consumable(cons_id: String) -> bool:
	if cons_id.is_empty() or repo.get_consumable(cons_id).is_empty():
		return false
	if owned_consumables.size() >= max_consumable_slots():
		return false
	owned_consumables.append(cons_id)
	return true

func _grant_random_consumable() -> String:
	if owned_consumables.size() >= max_consumable_slots() or repo.all_consumables.is_empty():
		return ""
	var c_pool: Array[String] = []
	for cdict: Dictionary in repo.all_consumables:
		var cid: String = str(cdict.get("id", ""))
		if not cid.is_empty():
			c_pool.append(cid)
	if c_pool.is_empty():
		return ""
	_shuffle_strings(c_pool)
	var chosen_cid: String = c_pool[0]
	owned_consumables.append(chosen_cid)
	return chosen_cid

func use_consumable(slot_index: int) -> bool:
	if mode != MODE_COMBAT or slot_index < 0 or slot_index >= owned_consumables.size():
		sfx_requested.emit("blocked", 0.5)
		return false
	var cid: String = owned_consumables[slot_index]
	var cdata: Dictionary = repo.get_consumable(cid)
	if cdata.is_empty():
		return false
	owned_consumables.remove_at(slot_index)
	var cname: String = str(cdata.get("name", cid))

	var rpm_d: int = int(cdata.get("rpm_delta_units", 0))
	if rpm_d != 0:
		rpm_units = clampi(rpm_units + rpm_d, transmission.min_rpm_units(), transmission.max_rpm_units())

	var heat_d: int = int(cdata.get("heat_delta", 0))
	if heat_d < 0:
		heat = maxi(0, heat + heat_d)
	elif heat_d > 0:
		_add_heat(heat_d)

	var blk_d: int = int(cdata.get("block", 0))
	if blk_d > 0:
		block += blk_d

	var heal_d: int = int(cdata.get("heal", 0))
	if heal_d > 0 and hp < max_hp:
		hp = mini(max_hp, hp + heal_d)

	if bool(cdata.get("restore_free_shift", false)):
		free_shift_available = true
		var rng_b: int = int(cdata.get("free_shift_range_bonus", 0))
		if rng_b > 0:
			free_shift_bonus_range = maxi(free_shift_bonus_range, rng_b)

	var aoe_dmg: int = int(cdata.get("aoe_damage", 0))
	var vuln_d: int = int(cdata.get("apply_vulnerable", 0))
	var weak_d: int = int(cdata.get("apply_weakness", 0))
	if aoe_dmg > 0 or vuln_d > 0 or weak_d > 0:
		for e_idx: int in range(enemies.size()):
			if not bool(enemies[e_idx].get("alive", false)):
				continue
			if weak_d > 0:
				enemies[e_idx]["weakness"] = int(enemies[e_idx].get("weakness", 0)) + weak_d
			if vuln_d > 0:
				enemies[e_idx]["vulnerable"] = int(enemies[e_idx].get("vulnerable", 0)) + vuln_d
			if aoe_dmg > 0:
				_deal_damage_to_enemy(e_idx, aoe_dmg)
				if mode == MODE_GAME_OVER:
					return true

	var draw_d: int = int(cdata.get("draw_cards", 0))
	if draw_d > 0:
		draw_cards(draw_d)

	_log_event("CANISTER DEPLOYED: %s (%s)!" % [cname, str(cdata.get("short", ""))])
	var cons_sfx: String = "turbo_blowoff" if rpm_d > 0 else ("coolant_vent" if heat_d < 0 else ("gun_burst" if aoe_dmg > 0 else "shield"))
	sfx_requested.emit(cons_sfx, 1.0)
	camera_trauma_requested.emit(0.24)
	floating_text_requested.emit(-1, str(cdata.get("short", cname.to_upper())), repo.get_palette_color(str(cdata.get("color_key", "selected_glow"))))
	relic_triggered.emit(cid, cname, str(cdata.get("short", "USED")))
	consumable_used.emit(cid)

	if _check_combat_victory():
		return true
	state_changed.emit()
	return true

func _advance_to_stage_or_route(next_index: int) -> void:
	if not tutorial_active and not run_map_nodes.is_empty() and not current_map_node_id.is_empty():
		var cur_node: Dictionary = RunMapGenerator.find_node(run_map_nodes, current_map_node_id)
		var outgoing: Array = cur_node.get("next_ids", []) as Array
		if outgoing.is_empty():
			_load_stage(repo.encounters.size())
			return
		if outgoing.size() == 1:
			var single_node: Dictionary = RunMapGenerator.find_node(run_map_nodes, str(outgoing[0]))
			_enter_map_node(single_node)
			return
		stage_index = next_index
		mode = MODE_ROUTE_CHOICE
		route_options.clear()
		var max_opts: int = mini(2, outgoing.size())
		for k: int in range(max_opts):
			var opt_node: Dictionary = RunMapGenerator.find_node(run_map_nodes, str(outgoing[k]))
			if opt_node.is_empty():
				continue
			var opt_enc: Dictionary = (opt_node.get("encounter", {}) as Dictionary).duplicate(true)
			opt_enc["map_node_id"] = str(opt_node.get("id", ""))
			route_options.append(opt_enc)
		route_choices_offered.emit(route_options)
		state_changed.emit()
		save_active_run()
		return

	if next_index < 0 or next_index >= repo.encounters.size():
		_load_stage(next_index)
		return
	var base_enc: Dictionary = repo.encounters[next_index]
	var variants: Array = base_enc.get("variants", []) as Array
	if variants.size() >= 2 and not tutorial_active:
		stage_index = next_index
		_offer_route_choices(base_enc, variants)
		return
	_load_stage(next_index)

func _offer_route_choices(base_enc: Dictionary, variants: Array) -> void:
	mode = MODE_ROUTE_CHOICE
	route_options.clear()
	var map_cfg: Dictionary = repo.gameplay().get("run_map", {}) as Dictionary
	var def_scrap: int = int(map_cfg.get("default_left_bonus_scrap", 0))
	var def_heal: int = int(map_cfg.get("default_right_bonus_heal", 0))
	var indices: Array[int] = []
	for i: int in range(variants.size()):
		indices.append(i)
	for i: int in range(indices.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: int = indices[i]
		indices[i] = indices[j]
		indices[j] = tmp
	var pick_count: int = mini(2, indices.size())
	for k: int in range(pick_count):
		var v_dict: Dictionary = (variants[indices[k]] as Dictionary).duplicate()
		var merged: Dictionary = base_enc.duplicate()
		merged.erase("variants")
		merged["title"] = str(v_dict.get("title", base_enc.get("title", "Sector")))
		merged["enemies"] = v_dict.get("enemies", base_enc.get("enemies", []) as Array)
		var b_scrap: int = int(v_dict.get("bonus_scrap", def_scrap if k == 0 else 0))
		var b_heal: int = int(v_dict.get("bonus_heal", def_heal if (k == 1 and b_scrap == 0) else 0))
		merged["bonus_scrap"] = b_scrap
		merged["bonus_heal"] = b_heal
		route_options.append(merged)
	route_choices_offered.emit(route_options)
	state_changed.emit()

func begin_route_transition(option_index: int) -> bool:
	if mode != MODE_ROUTE_CHOICE or option_index < 0 or option_index >= route_options.size():
		return false
	pending_route_option_index = option_index
	pending_route_option = route_options[option_index].duplicate(true)
	pending_route_node_id = str(pending_route_option.get("map_node_id", ""))
	mode = MODE_ROUTE_TRANSITION
	rpm_units = clampi(maxi(rpm_units, 3), transmission.min_rpm_units(), transmission.max_rpm_units())
	sfx_requested.emit("tire_screech", 0.78)
	route_transition_started.emit(option_index, pending_route_option)
	state_changed.emit()
	return true

func complete_route_transition() -> bool:
	if mode != MODE_ROUTE_TRANSITION or pending_route_option.is_empty():
		return false
	var chosen: Dictionary = pending_route_option.duplicate(true)
	pending_route_option.clear()
	pending_route_node_id = ""
	pending_route_option_index = -1
	route_options.clear()
	_apply_chosen_route(chosen)
	return true

func select_route_option(option_index: int) -> bool:
	if mode != MODE_ROUTE_CHOICE or option_index < 0 or option_index >= route_options.size():
		return false
	var chosen: Dictionary = route_options[option_index].duplicate(true)
	route_options.clear()
	pending_route_option.clear()
	pending_route_node_id = ""
	pending_route_option_index = -1
	_apply_chosen_route(chosen)
	return true

func _apply_chosen_route(chosen: Dictionary) -> void:
	var chosen_nid: String = str(chosen.get("map_node_id", ""))
	var map_node: Dictionary = {}
	if not chosen_nid.is_empty():
		current_map_node_id = chosen_nid
		if not visited_map_node_ids.has(chosen_nid):
			visited_map_node_ids.append(chosen_nid)
		map_node = RunMapGenerator.find_node(run_map_nodes, chosen_nid)
		if not map_node.is_empty():
			stage_index = int(map_node.get("stage_index", stage_index))
	var b_scrap: int = int(chosen.get("bonus_scrap", 0))
	var b_heal: int = int(chosen.get("bonus_heal", 0))
	if b_scrap > 0:
		scrap += b_scrap
		_log_event("Lane Split: +%d Scrap salvaged along the track!" % b_scrap)
	if b_heal > 0 and hp < max_hp:
		hp = mini(max_hp, hp + b_heal)
		_log_event("Lane Split: Service station (+%d Hull HP)!" % b_heal)
	resolved_encounter = chosen
	_dispatch_encounter(chosen, map_node)

func _load_stage(index: int) -> void:
	if index < 0 or index >= repo.encounters.size():
		mode = MODE_VICTORY
		clear_saved_run()
		_log_event("All sectors cleared!")
		run_ended.emit(true, "You conquered the Mechanical Megadungeon!")
		state_changed.emit()
		return

	if mode == MODE_REWARD:
		mode = MODE_COMBAT
	stage_index = index
	resolved_encounter = _resolve_encounter_variant(repo.encounters[stage_index])
	var enc: Dictionary = resolved_encounter
	var enc_type: String = str(enc.get("type", "combat"))
	_log_event(">> %s <<" % str(enc.get("title", "Sector")))

	if enc_type == "workshop":
		_open_workshop()
		return

	_setup_combat_encounter(enc)

func _setup_combat_encounter(enc: Dictionary) -> void:
	mode = MODE_COMBAT
	turn_number = 0
	block = 0
	var preset: Dictionary = get_chassis_preset(selected_chassis_id) if not tutorial_active else {}
	heat = int(repo.gameplay().get("starting_heat", 0))
	current_gear = int(preset.get("starting_gear", repo.gameplay().get("starting_gear", 1)))
	puncture_turns = 0
	gear_lock_max = -99
	gear_lock_min = -99
	ranged_dodge_charges = 0
	pending_draw_penalty = 0
	pending_shift_card_hand_index = -1
	shifts_this_turn = 0
	rev_match_used_this_turn = false
	retain_half_block_next_turn = false
	shift_surge_active = false
	preview_gear_override = -99
	free_shift_bonus_range = 0
	turn_torque_bonus = 0
	turns_in_same_gear = 0
	enemy_turn_queue.clear()
	active_acting_enemy_index = -1

	var start_rpm: int = int(preset.get("starting_rpm_units", repo.gameplay().get("starting_rpm_units", 2)))
	for rid: String in owned_relics:
		var rpm_b: int = int(repo.get_relic(rid).get("starting_rpm_bonus_units", 0))
		if rpm_b > 0:
			start_rpm += rpm_b
			_notify_relic_triggered(rid, "+%d,000 RPM" % rpm_b)
	rpm_units = clampi(start_rpm, transmission.min_rpm_units(), transmission.max_rpm_units())

	draw_pile = master_deck.duplicate()
	_shuffle_strings(draw_pile)
	hand.clear()
	discard_pile.clear()
	exhaust_pile.clear()

	enemies.clear()
	var raw_spawns: Array = enc.get("enemies", []) as Array
	var lane_jitter: float = float(repo.gameplay().get("spawn_lane_jitter", 0.0))
	var hp_var_pct: float = float(repo.gameplay().get("enemy_hp_variance_pct", 0.0))
	for spawn_val: Variant in raw_spawns:
		if typeof(spawn_val) != TYPE_DICTIONARY:
			continue
		var spawn_cfg: Dictionary = spawn_val as Dictionary
		var eid: String = str(spawn_cfg.get("enemy_id", ""))
		var tmpl: Dictionary = repo.get_enemy(eid)
		if tmpl.is_empty():
			continue
		var e_hp: int = int(spawn_cfg.get("hp_override", tmpl.get("hp", 30)))
		if not spawn_cfg.has("hp_override") and hp_var_pct > 0.0:
			var scale: float = 1.0 + rng.randf_range(-hp_var_pct, hp_var_pct) / 100.0
			e_hp = maxi(8, roundi(float(e_hp) * scale))
		if not tutorial_active and overdrive_level > 0:
			e_hp = maxi(8, roundi(float(e_hp) * (1.0 + 0.08 * float(overdrive_level))))
		var od_str: int = (2 if overdrive_level >= 5 else (1 if overdrive_level >= 2 else 0)) if not tutorial_active else 0
		var jitter: float = rng.randf_range(-lane_jitter, lane_jitter) if lane_jitter > 0.0 else 0.0
		enemies.append({
			"id": eid,
			"name": str(tmpl.get("name", eid)),
			"hp": e_hp,
			"max_hp": e_hp,
			"block": 0,
			"strength": od_str,
			"weakness": 0,
			"vulnerable": 0,
			"reflect_high_gear": false,
			"max_safe_gear": 6,
			"intent_index": 0,
			"lane_x": float(spawn_cfg.get("lane_x", 0.0)) + jitter,
			"distance_z": float(spawn_cfg.get("distance_z", -5.8)),
			"alive": true
		})

	_start_player_turn()

func _start_player_turn() -> void:
	if mode != MODE_COMBAT and mode != MODE_ENEMY_TURN:
		return
	mode = MODE_COMBAT
	active_acting_enemy_index = -1
	turn_number += 1
	if retain_half_block_next_turn and block > 0:
		block = block / 2
		_log_event("Mobile Bunker: retained %d Shield!" % block)
	else:
		block = 0
	retain_half_block_next_turn = false
	free_shift_available = true
	free_shift_bonus_range = 0
	shifts_this_turn = 0
	rev_match_used_this_turn = false
	shift_surge_active = false
	turn_torque_bonus = 0
	preview_gear_override = -99

	var prevent_decay: bool = false
	var relic_heat_cool: int = 0
	var low_gear_blk: int = 0
	for rid: String in owned_relics:
		var rdata: Dictionary = repo.get_relic(rid)
		if bool(rdata.get("prevent_natural_decay", false)):
			prevent_decay = true
			if turn_number > 1:
				_notify_relic_triggered(rid, "RPM HOLD")
		var h_red: int = int(rdata.get("turn_start_heat_reduction", 0))
		if h_red > 0:
			relic_heat_cool += h_red
			if heat > 0:
				_notify_relic_triggered(rid, "-%d HEAT" % h_red)
		if current_gear <= 2 and current_gear != 0:
			var lg_b: int = int(rdata.get("low_gear_turn_block", 0))
			if lg_b > 0:
				low_gear_blk += lg_b
				_notify_relic_triggered(rid, "+%d SHIELD" % lg_b)

	if low_gear_blk > 0:
		block += low_gear_blk
		_log_event("Titanium Bumper: +%d Shield in low gear!" % low_gear_blk)

	if turn_number > 1 and not prevent_decay:
		var decay: int = int(repo.gameplay().get("natural_rpm_decay_units", 1))
		rpm_units = maxi(transmission.min_rpm_units(), rpm_units - decay)

	if relic_heat_cool > 0 and heat > 0:
		heat = maxi(0, heat - relic_heat_cool)

	var gear_data: Dictionary = repo.get_gear(current_gear)
	ranged_dodge_charges = int(gear_data.get("ranged_dodge_charges", 0))

	var draw_count: int = int(repo.gameplay().get("base_hand_size", 5))
	draw_count += int(gear_data.get("start_turn_draw_bonus", 0))
	if pending_draw_penalty > 0:
		draw_count = maxi(1, draw_count - pending_draw_penalty)
		_log_event("Post-Stall: draw %d fewer cards!" % pending_draw_penalty)
		pending_draw_penalty = 0

	draw_cards(draw_count)
	_refresh_boss_passive_states()

	if transmission.is_stall_risk(current_gear, rpm_units):
		_log_event("IMMINENT STALL: %s at %d,000 RPM. Ending turn now will clear Shield and force Neutral!" % [
			transmission.gear_short_name(current_gear), rpm_units
		])
		sfx_requested.emit("alarm", 0.6)

	state_changed.emit()

func _refresh_boss_passive_states() -> void:
	for enemy: Dictionary in enemies:
		if not bool(enemy.get("alive", false)):
			continue
		var intent: Dictionary = get_enemy_intent(enemy)
		enemy["reflect_high_gear"] = bool(intent.get("reflect_high_gear", false))
		enemy["max_safe_gear"] = int(intent.get("max_safe_gear", 6))

func get_enemy_intent(enemy: Dictionary) -> Dictionary:
	var tmpl: Dictionary = repo.get_enemy(str(enemy.get("id", "")))
	var pattern: Array = tmpl.get("pattern", []) as Array
	if pattern.is_empty():
		return {}
	var idx: int = posmod(int(enemy.get("intent_index", 0)), pattern.size())
	return pattern[idx] as Dictionary

func intent_range(intent: Dictionary, key: String, fallback_key: String = "") -> Vector2i:
	var raw: Variant = intent.get(key, null)
	if raw == null and not fallback_key.is_empty():
		raw = intent.get(fallback_key, null)
	if raw == null:
		return Vector2i.ZERO
	if typeof(raw) == TYPE_ARRAY:
		var arr: Array = raw as Array
		if arr.is_empty():
			return Vector2i.ZERO
		if arr.size() == 1:
			var v1: int = int(arr[0])
			return Vector2i(v1, v1)
		var a: int = int(arr[0])
		var b: int = int(arr[1])
		return Vector2i(mini(a, b), maxi(a, b))
	var single: int = int(raw)
	return Vector2i(single, single)

func roll_intent_value(intent: Dictionary, key: String, fallback_key: String = "") -> int:
	var r: Vector2i = intent_range(intent, key, fallback_key)
	if r.x >= r.y:
		return r.x
	return rng.randi_range(r.x, r.y)

func format_range_value(r: Vector2i) -> String:
	return str(r.x) if r.x == r.y else ("%d-%d" % [r.x, r.y])

func effective_enemy_damage_range(enemy: Dictionary, intent: Dictionary) -> Vector2i:
	var dr: Vector2i = intent_range(intent, "damage", "base_damage")
	if dr.y <= 0:
		return Vector2i.ZERO
	var str_b: int = int(enemy.get("strength", 0))
	var min_d: int = maxi(0, dr.x + str_b)
	var max_d: int = maxi(0, dr.y + str_b)
	if str(intent.get("type", "")) == "boss_crush":
		var per_gear: int = int(intent.get("gear_damage_reduction_per_level", 5))
		var eff_gear: int = maxi(0, current_gear)
		min_d = maxi(0, min_d - eff_gear * per_gear)
		max_d = maxi(0, max_d - eff_gear * per_gear)
	if int(enemy.get("weakness", 0)) > 0:
		var w_mult: float = float(repo.gameplay().get("weakness_damage_multiplier", 0.75))
		min_d = int(round(float(min_d) * w_mult))
		max_d = int(round(float(max_d) * w_mult))
	return Vector2i(min_d, maxi(min_d, max_d))

func format_enemy_intent_action_label(intent: Dictionary) -> String:
	var itype: String = str(intent.get("type", "attack"))
	match itype:
		"boss_crush":
			return repo.get_ui_text("combat", "intent_act_crush")
		"defend", "defend_all", "boss_wall":
			return repo.get_ui_text("combat", "intent_act_defend")
		"heal", "heal_all":
			return repo.get_ui_text("combat", "intent_act_heal")
		"buff":
			return repo.get_ui_text("combat", "intent_act_buff")
		_:
			if bool(intent.get("is_melee", false)):
				return repo.get_ui_text("combat", "intent_act_melee")
			if bool(intent.get("is_ranged", false)):
				return repo.get_ui_text("combat", "intent_act_ranged")
			return repo.get_ui_text("combat", "intent_act_attack")

func format_enemy_intent_summary(enemy: Dictionary) -> String:
	var intent: Dictionary = get_enemy_intent(enemy)
	if intent.is_empty():
		return ""
	var itype: String = str(intent.get("type", "attack"))
	var parts: PackedStringArray = PackedStringArray()

	var dr: Vector2i = effective_enemy_damage_range(enemy, intent)
	var raw_dr: Vector2i = intent_range(intent, "damage", "base_damage")
	if raw_dr.y > 0:
		var hits: int = maxi(1, int(intent.get("hits", 1)))
		var dmg_str: String = ("%sx%d" % [format_range_value(dr), hits]) if hits > 1 else format_range_value(dr)
		if itype == "boss_crush":
			var per_g: int = int(intent.get("gear_damage_reduction_per_level", 5))
			parts.append(repo.get_ui_text("combat", "intent_dmg_crush_fmt") % [dmg_str, per_g])
		elif bool(intent.get("is_melee", false)):
			parts.append(repo.get_ui_text("combat", "intent_dmg_melee_fmt") % dmg_str)
		elif bool(intent.get("is_ranged", false)):
			parts.append(repo.get_ui_text("combat", "intent_dmg_ranged_fmt") % dmg_str)
		else:
			parts.append(repo.get_ui_text("combat", "intent_dmg_generic_fmt") % dmg_str)
		if bool(intent.get("has_corto_raggio", false)):
			var safe_gears: Array = intent.get("safe_gears", [-1, 5, 6]) as Array
			parts.append(repo.get_ui_text("combat", "intent_miss_gears_fmt") % transmission.format_allowed_gears(safe_gears))

	var br: Vector2i = intent_range(intent, "block")
	if br.y > 0:
		var b_fmt: String = "intent_shield_all_fmt" if (itype == "defend_all" or itype == "heal_all") else "intent_shield_self_fmt"
		parts.append(repo.get_ui_text("combat", b_fmt) % format_range_value(br))

	var hr: Vector2i = intent_range(intent, "heal")
	if hr.y > 0:
		var h_fmt: String = "intent_heal_all_fmt" if (itype == "heal_all" or bool(intent.get("heal_all", false))) else "intent_heal_self_fmt"
		parts.append(repo.get_ui_text("combat", h_fmt) % format_range_value(hr))

	var sr: Vector2i = intent_range(intent, "strength")
	if sr.y > 0:
		parts.append(repo.get_ui_text("combat", "intent_str_fmt") % format_range_value(sr))

	var pr: Vector2i = intent_range(intent, "puncture")
	if pr.y > 0:
		parts.append(repo.get_ui_text("combat", "intent_puncture_fmt") % format_range_value(pr))

	var rr: Vector2i = intent_range(intent, "rpm_drain_units")
	if rr.y > 0:
		parts.append(repo.get_ui_text("combat", "intent_rpm_drain_fmt") % format_range_value(rr))

	var htr: Vector2i = intent_range(intent, "heat_add")
	if htr.y > 0:
		parts.append(repo.get_ui_text("combat", "intent_heat_fmt") % format_range_value(htr))

	if intent.has("gear_lock_max"):
		parts.append(repo.get_ui_text("combat", "intent_gear_max_fmt") % transmission.gear_short_name(int(intent.get("gear_lock_max", 3))))
	if intent.has("gear_lock_min"):
		parts.append(repo.get_ui_text("combat", "intent_gear_min_fmt") % transmission.gear_short_name(int(intent.get("gear_lock_min", 3))))
	if bool(intent.get("reflect_high_gear", false)):
		parts.append(repo.get_ui_text("combat", "intent_reflect_fmt") % transmission.gear_short_name(int(intent.get("max_safe_gear", 2))))

	return "  •  ".join(parts)

func preview_manual_shift(target_gear: int) -> Dictionary:
	return transmission.evaluate_manual_shift(current_gear, target_gear, free_shift_available, gear_lock_max, has_grind_immunity(), gear_lock_min, free_shift_bonus_range)

func request_manual_shift(target_gear: int) -> bool:
	if mode != MODE_COMBAT:
		return false
	var eval: Dictionary = preview_manual_shift(target_gear)
	if not bool(eval.get("allowed", false)):
		var reason: String = str(eval.get("reason", "Gearbox locked"))
		if not reason.is_empty():
			_log_event(reason)
		sfx_requested.emit("blocked", 0.5)
		state_changed.emit()
		return false

	var old_gear: int = current_gear
	var was_grind: bool = int(eval.get("extra_grind_steps", 0)) > 0
	if bool(eval.get("uses_free_shift", false)):
		free_shift_available = false
		free_shift_bonus_range = 0

	preview_gear_override = -99
	current_gear = target_gear
	shift_surge_active = true
	_on_gear_changed_side_effects(old_gear, current_gear)

	if was_grind:
		var hp_cost: int = int(eval.get("hp_cost", 0))
		var heat_cost: int = int(eval.get("heat_cost", 0))
		if hp_cost == 0 and has_grind_immunity():
			for rid: String in owned_relics:
				if bool(repo.get_relic(rid).get("grind_hull_immune", false)):
					_notify_relic_triggered(rid, "0 HULL DMG")
		_log_event("GEAR GRIND! %s -> %s (-%d HP, +%d Heat)" % [transmission.gear_short_name(old_gear), transmission.gear_short_name(current_gear), hp_cost, heat_cost])
		sfx_requested.emit("grind", 1.0)
		camera_trauma_requested.emit(0.45)
		if hp_cost > 0:
			_apply_direct_hull_damage(hp_cost, false)
			if mode == MODE_GAME_OVER:
				return true
		if heat_cost > 0:
			_add_heat(heat_cost)
	else:
		_log_event("Shift gear: %s -> %s" % [transmission.gear_short_name(old_gear), transmission.gear_short_name(current_gear)])
		sfx_requested.emit("shift_clack", 0.85)
		camera_trauma_requested.emit(0.16)

	gear_shifted.emit(old_gear, current_gear, was_grind)
	state_changed.emit()
	return true

func step_manual_shift(delta_step: int) -> bool:
	var sanitized_step: int = clampi(delta_step, -1, 1)
	if sanitized_step == 0:
		return false
	return request_manual_shift(current_gear + sanitized_step)

func _force_card_shift(target_gear: int) -> void:
	var clamped: int = transmission.clamp_gear(target_gear, gear_lock_max, gear_lock_min)
	if clamped == current_gear:
		return
	var old_gear: int = current_gear
	current_gear = clamped
	_on_gear_changed_side_effects(old_gear, current_gear)
	sfx_requested.emit("shift_clack", 0.75)
	gear_shifted.emit(old_gear, current_gear, false)

func _on_gear_changed_side_effects(old_gear: int, new_gear: int) -> void:
	if old_gear != new_gear:
		shifts_this_turn += 1
		turns_in_same_gear = 0
		var shift_blk_total: int = 0
		var downshift_rpm_total: int = 0
		for rid: String in owned_relics:
			var rdata: Dictionary = repo.get_relic(rid)
			var sb: int = int(rdata.get("shift_bonus_block", 0))
			if sb > 0:
				shift_blk_total += sb
				_notify_relic_triggered(rid, "+%d SHIELD" % sb)
			if new_gear < old_gear:
				var dr: int = int(rdata.get("downshift_rpm_bonus", 0))
				if dr > 0:
					downshift_rpm_total += dr
					_notify_relic_triggered(rid, "+%dK RPM" % dr)
		if shift_blk_total > 0:
			block += shift_blk_total
		if downshift_rpm_total > 0:
			rpm_units = clampi(rpm_units + downshift_rpm_total, transmission.min_rpm_units(), transmission.max_rpm_units())
	if puncture_turns > 0:
		var loss: int = int(repo.gameplay().get("puncture_rpm_loss_units", 1))
		rpm_units = maxi(transmission.min_rpm_units(), rpm_units - loss)
		_log_event("Puncture active: lose -%d,000 RPM shifting gears!" % loss)
	var gdata: Dictionary = repo.get_gear(new_gear)
	if int(gdata.get("ranged_dodge_charges", 0)) > 0:
		ranged_dodge_charges = maxi(ranged_dodge_charges, int(gdata.get("ranged_dodge_charges", 0)))
	var is_optimal_target: bool = transmission.is_optimal(new_gear, rpm_units)
	if old_gear != new_gear and new_gear < old_gear and new_gear >= 1:
		sfx_requested.emit("throttle_blip", 1.25 if is_optimal_target else 0.85)
	elif old_gear != new_gear and not rev_match_used_this_turn and is_optimal_target and new_gear >= 1:
		sfx_requested.emit("throttle_blip", 1.0)
	if old_gear != new_gear and new_gear >= 1 and not rev_match_used_this_turn and is_optimal_target:
		rev_match_used_this_turn = true
		var rev_blk: int = int(repo.gameplay().get("rev_match_block_bonus", 3))
		var rev_trq: int = int(repo.gameplay().get("rev_match_torque_bonus", 2))
		var rev_rpm: int = 0
		for rid: String in owned_relics:
			var rdata: Dictionary = repo.get_relic(rid)
			var ex_b: int = int(rdata.get("rev_match_extra_block", 0))
			var ex_r: int = int(rdata.get("rev_match_rpm_bonus", 0))
			if ex_b > 0 or ex_r > 0:
				rev_blk += ex_b
				rev_rpm += ex_r
				_notify_relic_triggered(rid, "+%d SHIELD +%dK RPM" % [ex_b, ex_r])
		block += rev_blk
		turn_torque_bonus += rev_trq
		if rev_rpm > 0:
			rpm_units = clampi(rpm_units + rev_rpm, transmission.min_rpm_units(), transmission.max_rpm_units())
		_log_event("PERFECT SHIFT (Rev-Match in %s)! +%d Shield, +%d Torque DMG!" % [transmission.gear_short_name(new_gear), rev_blk, rev_trq])
		sfx_requested.emit("rev_match", 0.88)
		floating_text_requested.emit(-1, repo.get_ui_text("combat", "float_perfect_shift_fmt") % rev_blk, repo.get_palette_color("kw_shield"))

func burn_card_for_rpm(hand_index: int) -> bool:
	if mode != MODE_COMBAT or hand_index < 0 or hand_index >= hand.size():
		sfx_requested.emit("blocked", 0.5)
		return false
	var cid: String = hand[hand_index]
	var cdata: Dictionary = repo.get_card(cid)
	hand.remove_at(hand_index)
	discard_pile.append(cid)
	var gain: int = maxi(1, int(repo.gameplay().get("burn_card_rpm_gain_units", 1)))
	rpm_units = clampi(rpm_units + gain, transmission.min_rpm_units(), transmission.max_rpm_units())
	_log_event("CLUTCH KICK: %s burned for +%d,000 RPM!" % [str(cdata.get("name", cid)), gain])
	sfx_requested.emit("clutch_kick", 0.95)
	camera_trauma_requested.emit(0.16)
	floating_text_requested.emit(-1, repo.get_ui_text("combat", "float_burn_rpm_fmt") % gain, repo.get_palette_color("playable_glow"))
	card_burned.emit(cid)
	state_changed.emit()
	return true

func can_play_card(hand_index: int, use_preview_gear: bool = true, explicit_gear: int = -99) -> Dictionary:
	var check: Dictionary = {"playable": false, "reason": ""}
	if mode != MODE_COMBAT:
		check["reason"] = repo.get_ui_text("combat", "err_not_in_combat")
		return check
	if hand_index < 0 or hand_index >= hand.size():
		check["reason"] = repo.get_ui_text("combat", "err_invalid_card")
		return check
	var card: Dictionary = repo.get_card(hand[hand_index])
	if card.is_empty():
		check["reason"] = repo.get_ui_text("combat", "err_missing_card")
		return check
	var eval_gear: int = explicit_gear if (explicit_gear >= -1 and explicit_gear <= 6) else (effective_gear() if use_preview_gear else current_gear)
	var allowed: Array = card.get("allowed_gears", []) as Array
	var gear_ok: bool = false
	for g_val: Variant in allowed:
		if int(g_val) == eval_gear:
			gear_ok = true
			break
	if not gear_ok:
		check["reason"] = repo.get_ui_text("combat", "err_wrong_gear_fmt") % transmission.format_allowed_gears(allowed)
		return check
	if bool(card.get("requires_redline", false)) and not transmission.is_redline(eval_gear, rpm_units):
		check["reason"] = repo.get_ui_text("combat", "err_redline_only")
		return check
	if bool(card.get("consume_all_rpm", false)) and rpm_units <= 0:
		check["reason"] = repo.get_ui_text("combat", "err_min_rpm")
		return check
	if bool(card.get("consume_all_heat", false)) and heat <= 0:
		check["reason"] = repo.get_ui_text("combat", "err_min_heat")
		return check
	var eff_rpm_delta: int = transmission.effective_card_rpm_delta(card, eval_gear)
	if eff_rpm_delta < 0 and (rpm_units + eff_rpm_delta) < transmission.min_rpm_units():
		check["reason"] = repo.get_ui_text("combat", "err_low_rpm_fmt") % absi(eff_rpm_delta)
		return check
	check["playable"] = true
	return check

func calculate_card_preview(card: Dictionary, use_preview_gear: bool = true, bonus_upgrade_level: int = 0) -> Dictionary:
	var eval_gear: int = effective_gear() if use_preview_gear else current_gear
	var is_previewing_shift: bool = use_preview_gear and (eval_gear != current_gear)
	var upg_lvl: int = mini(max_card_upgrade_level(), card_upgrade_level(card) + maxi(0, bonus_upgrade_level))
	var base_dmg: int = int(card.get("damage", 0))
	if bool(card.get("damage_from_block", false)):
		var bonus_first: int = int(repo.get_gear(eval_gear).get("bonus_block_per_card", 0))
		base_dmg += block + bonus_first
	elif bool(card.get("consume_all_rpm", false)):
		base_dmg = rpm_units * int(card.get("damage_per_rpm_unit", 5))
	elif bool(card.get("consume_all_heat", false)):
		base_dmg = heat * int(card.get("damage_per_heat", 9))

	var is_attack: bool = base_dmg > 0 or card.has("damage") or bool(card.get("damage_from_block", false)) or bool(card.get("consume_all_rpm", false)) or bool(card.get("consume_all_heat", false))
	var final_dmg: int = 0
	if is_attack:
		var surge_active_now: bool = shift_surge_active or is_previewing_shift
		var surge_bonus: int = int(repo.gameplay().get("manual_shift_damage_bonus", 3)) if surge_active_now else 0
		var preview_trq: int = turn_torque_bonus
		if is_previewing_shift and eval_gear >= 1 and not rev_match_used_this_turn and transmission.is_optimal(eval_gear, rpm_units):
			preview_trq += int(repo.gameplay().get("rev_match_torque_bonus", 2))
		var dmg_float: float = float(base_dmg) + float(int(repo.gameplay().get("card_upgrade_damage_bonus", 2)) * upg_lvl)
		var is_red_eval: bool = transmission.is_redline(eval_gear, rpm_units)
		if is_red_eval:
			dmg_float += float(int(repo.gameplay().get("redline_universal_damage_bonus", 4)))
			dmg_float += float(card.get("redline_bonus_damage", 0))
		var hot_min: int = int(repo.gameplay().get("hot_engine_min_heat", 2))
		if heat >= hot_min:
			dmg_float += float(int(repo.gameplay().get("hot_engine_damage_bonus", 2)))
		var h_thresh: int = int(card.get("high_heat_threshold", 99))
		if heat >= h_thresh:
			dmg_float += float(card.get("high_heat_bonus_damage", 0))
		var shift_scale: int = int(card.get("damage_per_shift_this_turn", 0))
		if shift_scale > 0:
			var eff_shifts: int = shifts_this_turn + (1 if is_previewing_shift else 0)
			dmg_float += float(shift_scale * eff_shifts)
		if bool(card.get("is_ram", false)):
			dmg_float += float(repo.get_gear(eval_gear).get("ram_damage_bonus", 0))
		dmg_float += float(surge_bonus + preview_trq)
		for rid: String in owned_relics:
			var rdata: Dictionary = repo.get_relic(rid)
			var thresh: int = int(rdata.get("min_rpm_units_threshold", 99))
			if rpm_units >= thresh:
				dmg_float += float(rdata.get("bonus_damage_high_rpm", 0))
			if is_red_eval:
				dmg_float += float(rdata.get("redline_damage_bonus", 0))
		var gear_mult: float = 1.0 + float(repo.get_gear(eval_gear).get("damage_bonus_pct", 0.0))
		final_dmg = maxi(0, int(round(dmg_float * gear_mult)))

	var base_blk: int = int(card.get("block", 0))
	if base_blk > 0:
		base_blk += int(repo.gameplay().get("card_upgrade_block_bonus", 3)) * upg_lvl
	var gear_blk_bonus: int = int(repo.get_gear(eval_gear).get("bonus_block_per_card", 0))
	var total_blk: int = base_blk + gear_blk_bonus
	var eff_rpm: int = transmission.effective_card_rpm_delta(card, eval_gear)
	return {
		"damage": final_dmg,
		"hits": maxi(1, int(card.get("hits", 1))),
		"block": total_blk,
		"rpm_delta_units": eff_rpm,
		"upgrade_level": upg_lvl
	}

func first_alive_enemy_index() -> int:
	for i: int in range(enemies.size()):
		if bool(enemies[i].get("alive", false)):
			return i
	return -1

func alive_enemy_count() -> int:
	var count: int = 0
	for enemy: Dictionary in enemies:
		if bool(enemy.get("alive", false)):
			count += 1
	return count

func play_card(hand_index: int, target_enemy_index: int = -1) -> bool:
	preview_gear_override = -99
	var check: Dictionary = can_play_card(hand_index, false)
	if not bool(check.get("playable", false)):
		_log_event(str(check.get("reason", repo.get_ui_text("combat", "err_invalid_card"))))
		sfx_requested.emit("blocked", 0.5)
		state_changed.emit()
		return false

	var card_id: String = hand[hand_index]
	var card: Dictionary = repo.get_card(card_id)
	var target_type: String = str(card.get("target_type", "self"))

	var resolved_target: int = target_enemy_index
	if target_type == "single_enemy":
		if resolved_target < 0 or resolved_target >= enemies.size() or not bool(enemies[resolved_target].get("alive", false)):
			if alive_enemy_count() == 1:
				resolved_target = first_alive_enemy_index()
			else:
				return false

	var shift_opts: Array = card.get("choose_shift_options", []) as Array
	if not shift_opts.is_empty():
		pending_shift_card_hand_index = hand_index
		mode = MODE_SHIFT_CHOICE
		shift_choice_requested.emit(hand_index, shift_opts)
		state_changed.emit()
		return true

	return _execute_card_resolution(hand_index, resolved_target, 0, false)

func resolve_pending_shift_choice(chosen_delta: int) -> bool:
	if mode != MODE_SHIFT_CHOICE or pending_shift_card_hand_index < 0 or pending_shift_card_hand_index >= hand.size():
		mode = MODE_COMBAT
		pending_shift_card_hand_index = -1
		state_changed.emit()
		return false
	var idx: int = pending_shift_card_hand_index
	pending_shift_card_hand_index = -1
	mode = MODE_COMBAT
	var clean_delta: int = clampi(chosen_delta, -2, 2)
	return _execute_card_resolution(idx, -1, clean_delta, true)

func _execute_card_resolution(hand_index: int, resolved_target: int, chosen_shift_delta: int, has_chosen_shift: bool) -> bool:
	var card_id: String = hand[hand_index]
	var card: Dictionary = repo.get_card(card_id)
	hand.remove_at(hand_index)

	var started_in_redline: bool = transmission.is_redline(current_gear, rpm_units)
	var preview: Dictionary = calculate_card_preview(card, false)
	var consumed_units: int = rpm_units

	if bool(card.get("consume_all_rpm", false)):
		rpm_units = 0
	else:
		var delta_rpm: int = int(preview.get("rpm_delta_units", 0))
		rpm_units = clampi(rpm_units + delta_rpm, transmission.min_rpm_units(), transmission.max_rpm_units())

	var gained_block: int = int(preview.get("block", 0))
	if gained_block > 0:
		block += gained_block
		sfx_requested.emit("shield", 0.65)

	var card_heat: int = int(card.get("heat_delta", 0))
	if started_in_redline:
		card_heat += int(repo.gameplay().get("redline_heat_per_card", 1))
		_log_event("REDLINE! Playing in Redline generates +1 Heat!")

	var single_hit_dmg: int = int(preview.get("damage", 0))
	var hit_count: int = int(preview.get("hits", 1))
	var target_type: String = str(card.get("target_type", "self"))

	if single_hit_dmg > 0:
		for rid: String in owned_relics:
			var rdata: Dictionary = repo.get_relic(rid)
			var thresh: int = int(rdata.get("min_rpm_units_threshold", 99))
			var b_high: int = int(rdata.get("bonus_damage_high_rpm", 0))
			if b_high > 0 and consumed_units >= thresh:
				_notify_relic_triggered(rid, "+%d DMG" % b_high)
			var b_red: int = int(rdata.get("redline_damage_bonus", 0))
			if b_red > 0 and started_in_redline:
				_notify_relic_triggered(rid, "+%d RED DMG" % b_red)
		if shift_surge_active:
			var surge_amt: int = int(repo.gameplay().get("manual_shift_damage_bonus", 3))
			shift_surge_active = false
			_log_event(repo.get_ui_text("hud", "shift_surge_log") % surge_amt)
			if resolved_target >= 0:
				floating_text_requested.emit(resolved_target, repo.get_ui_text("hud", "shift_surge_float") % surge_amt, Color(1.0, 0.88, 0.25))
		if target_type == "single_enemy" and resolved_target >= 0:
			for _h: int in range(hit_count):
				_deal_damage_to_enemy(resolved_target, single_hit_dmg)
				if mode == MODE_GAME_OVER:
					return true
		elif target_type == "all_enemies":
			for _h: int in range(hit_count):
				for e_idx: int in range(enemies.size()):
					if bool(enemies[e_idx].get("alive", false)):
						_deal_damage_to_enemy(e_idx, single_hit_dmg)
						if mode == MODE_GAME_OVER:
							return true
		var hit_sfx: String = "ram_hit" if bool(card.get("is_ram", false)) else ("gun_burst" if (bool(card.get("is_ranged", false)) or hit_count > 1) else "attack_hit")
		sfx_requested.emit(hit_sfx, 0.92)
		camera_trauma_requested.emit(0.38 if bool(card.get("is_ram", false)) else 0.22)
	else:
		if int(card.get("rpm_delta_units", 0)) >= 2:
			sfx_requested.emit("turbo_blowoff", 0.82)
		elif int(card.get("heat_delta", 0)) < 0:
			sfx_requested.emit("coolant_vent", 0.80)
		else:
			sfx_requested.emit("card_play", 0.7)

	var weak_amt: int = int(card.get("apply_weakness", 0))
	var vuln_amt: int = int(card.get("apply_vulnerable", 0))
	if weak_amt > 0 or vuln_amt > 0:
		if target_type == "single_enemy" and resolved_target >= 0 and bool(enemies[resolved_target].get("alive", false)):
			enemies[resolved_target]["weakness"] = int(enemies[resolved_target].get("weakness", 0)) + weak_amt
			enemies[resolved_target]["vulnerable"] = int(enemies[resolved_target].get("vulnerable", 0)) + vuln_amt
		elif target_type == "all_enemies":
			for e_idx: int in range(enemies.size()):
				if bool(enemies[e_idx].get("alive", false)):
					enemies[e_idx]["weakness"] = int(enemies[e_idx].get("weakness", 0)) + weak_amt
					enemies[e_idx]["vulnerable"] = int(enemies[e_idx].get("vulnerable", 0)) + vuln_amt

	if card.has("set_gear"):
		_force_card_shift(int(card.get("set_gear", 0)))
	elif has_chosen_shift and chosen_shift_delta != 0:
		_force_card_shift(current_gear + chosen_shift_delta)
	elif int(card.get("gear_shift_delta", 0)) != 0:
		_force_card_shift(current_gear + int(card.get("gear_shift_delta", 0)))

	if bool(card.get("retain_half_block", false)):
		retain_half_block_next_turn = true

	if bool(card.get("restore_free_shift", false)):
		free_shift_available = true
		var bonus_rng: int = int(card.get("free_shift_range_bonus", 0))
		if bonus_rng > 0:
			free_shift_bonus_range = maxi(free_shift_bonus_range, bonus_rng)
		_log_event(repo.get_ui_text("combat", "quick_shifter_log"))

	if bool(card.get("consume_all_heat", false)) and heat > 0:
		heat = 0
		sfx_requested.emit("coolant_vent", 0.88)
		_trigger_pyro_relic_aoe()

	var to_draw: int = int(card.get("draw_cards", 0))
	if to_draw > 0:
		draw_cards(to_draw)

	if bool(card.get("discard_low_gear_cards", false)):
		_discard_low_gear_cards_from_hand()

	if card_heat != 0:
		if card_heat > 0:
			_add_heat(card_heat)
		else:
			heat = maxi(0, heat + card_heat)

	if bool(card.get("exhaust", false)):
		exhaust_pile.append(card_id)
	else:
		discard_pile.append(card_id)

	card_played_fx.emit(card, resolved_target)
	_log_event(repo.get_ui_text("combat", "card_played_log_fmt") % str(card.get("name", card_id)))

	if _check_combat_victory():
		return true

	if mode == MODE_COMBAT and bool(card.get("end_turn", false)):
		end_player_turn()
		return true

	state_changed.emit()
	return true

func _discard_low_gear_cards_from_hand() -> void:
	var kept: Array[String] = []
	var discarded_count: int = 0
	for cid: String in hand:
		var cdata: Dictionary = repo.get_card(cid)
		var gears: Array = cdata.get("allowed_gears", []) as Array
		var requires_low: bool = gears.size() < repo.ordered_gears.size() and (gears.has(1) or gears.has(2)) and not gears.has(4) and not gears.has(5) and not gears.has(6)
		if requires_low:
			discard_pile.append(cid)
			discarded_count += 1
		else:
			kept.append(cid)
	hand = kept
	if discarded_count > 0:
		_log_event("Drafting Slipstream: discarded %d low-gear cards" % discarded_count)

func _deal_damage_to_enemy(enemy_index: int, raw_damage: int) -> void:
	if enemy_index < 0 or enemy_index >= enemies.size():
		return
	var enemy: Dictionary = enemies[enemy_index]
	if not bool(enemy.get("alive", false)):
		return

	var dmg: int = raw_damage
	if int(enemy.get("vulnerable", 0)) > 0:
		var v_mult: float = float(repo.gameplay().get("vulnerable_damage_multiplier", 1.5))
		dmg = int(round(float(dmg) * v_mult))

	if bool(enemy.get("reflect_high_gear", false)) and current_gear > int(enemy.get("max_safe_gear", 2)):
		_log_event("STEEL WALL! Reflected %d damage because you are above 2nd gear!" % dmg)
		_apply_enemy_damage_to_player(dmg, false, false)
		return

	var e_block: int = int(enemy.get("block", 0))
	var absorbed: int = mini(e_block, dmg)
	e_block -= absorbed
	var remaining: int = dmg - absorbed
	enemy["block"] = e_block
	enemy["hp"] = maxi(0, int(enemy.get("hp", 0)) - remaining)
	enemy_hit_fx.emit(enemy_index, dmg, remaining == 0)

	if int(enemy.get("hp", 0)) <= 0:
		enemy["alive"] = false
		_log_event("%s destroyed!" % str(enemy.get("name", "Enemy")))
		sfx_requested.emit("explosion", 1.0)
		camera_trauma_requested.emit(0.5)

func _trigger_pyro_relic_aoe() -> void:
	for rid: String in owned_relics:
		var aoe_dmg: int = int(repo.get_relic(rid).get("overheat_aoe_damage", 0))
		if aoe_dmg > 0:
			_notify_relic_triggered(rid, "%d AOE DMG" % aoe_dmg)
			_log_event("Pyrotechnic Injector: %d explosive damage to all enemies!" % aoe_dmg)
			for e_idx: int in range(enemies.size()):
				if bool(enemies[e_idx].get("alive", false)):
					_deal_damage_to_enemy(e_idx, aoe_dmg)

func _add_heat(amount: int) -> void:
	heat += amount
	var cap: int = max_heat()
	if heat >= cap:
		heat = 0
		var hull_dmg: int = int(repo.gameplay().get("overheat_hull_damage", 15))
		if not tutorial_active and overdrive_level >= 3:
			hull_dmg += 3
		var reset_g: int = int(repo.gameplay().get("overheat_reset_gear", 0))
		var old_g: int = current_gear
		current_gear = reset_g
		_log_event("ENGINE OVERHEAT! -%d piercing HP and shifted to Neutral (N)!" % hull_dmg)
		sfx_requested.emit("overheat", 1.0)
		camera_trauma_requested.emit(0.75)
		gear_shifted.emit(old_g, current_gear, true)
		_trigger_pyro_relic_aoe()
		_apply_direct_hull_damage(hull_dmg, true)

func _apply_direct_hull_damage(amount: int, is_overheat: bool) -> void:
	if amount <= 0:
		return
	hp = maxi(0, hp - amount)
	player_hit_fx.emit(amount, is_overheat)
	if hp <= 0:
		mode = MODE_GAME_OVER
		clear_saved_run()
		_log_event(repo.get_ui_text("combat", "hull_destroyed_log"))
		run_ended.emit(false, repo.get_ui_text("combat", "defeat_summary_fmt") % (stage_index + 1))
		state_changed.emit()

func _apply_enemy_damage_to_player(raw_amount: int, is_melee: bool, is_ranged: bool) -> void:
	if raw_amount <= 0 or mode == MODE_GAME_OVER:
		return
	if is_ranged and ranged_dodge_charges > 0:
		ranged_dodge_charges -= 1
		_log_event("OVERDRIVE DODGE (6th)! Ranged attack evaded!")
		sfx_requested.emit("shift_clack", 0.6)
		return

	var adjusted: float = float(raw_amount)
	if is_melee:
		var melee_red: float = float(repo.get_gear(current_gear).get("melee_damage_reduction", 0.0))
		if melee_red > 0.0:
			adjusted *= (1.0 - melee_red)
			_log_event("Reverse (R): Melee damage halved!")

	var final_dmg: int = maxi(0, int(round(adjusted)))
	var absorbed: int = mini(block, final_dmg)
	block -= absorbed
	var hull_dmg: int = final_dmg - absorbed
	if hull_dmg > 0:
		sfx_requested.emit("player_hit", 0.95)
		camera_trauma_requested.emit(0.55)
		_apply_direct_hull_damage(hull_dmg, false)
	else:
		sfx_requested.emit("shield", 0.8)

func end_player_turn() -> void:
	if mode != MODE_COMBAT:
		return

	var gear_data: Dictionary = repo.get_gear(current_gear)
	if transmission.is_stall_risk(current_gear, rpm_units):
		var old_g: int = current_gear
		var stall_pen: int = int(repo.gameplay().get("stall_draw_penalty", 1))
		if not tutorial_active and overdrive_level >= 4:
			stall_pen += 1
		block = 0
		current_gear = 0
		rpm_units = 0
		pending_draw_penalty = stall_pen
		if stall_pen > 0:
			_log_event("ENGINE STALL! Shield wiped, shifted to Neutral, 0 RPM, draw %d fewer card!" % stall_pen)
		else:
			_log_event("ENGINE STALL! Shield wiped, shifted to Neutral at 0 RPM!")
		sfx_requested.emit("stall", 1.0)
		camera_trauma_requested.emit(0.65)
		gear_shifted.emit(old_g, current_gear, true)
		if not tutorial_active and overdrive_level >= 4:
			_apply_direct_hull_damage(4, false)
			if mode == MODE_GAME_OVER:
				return
	else:
		if gear_data.has("end_turn_rpm_cap_units"):
			var cap_u: int = int(gear_data.get("end_turn_rpm_cap_units", 1))
			rpm_units = mini(rpm_units, cap_u)
		var cool: int = int(gear_data.get("end_turn_heat_reduction", 0))
		if cool > 0 and heat > 0:
			heat = maxi(0, heat - cool)
			sfx_requested.emit("coolant_vent", 0.65)
			_log_event("Neutral Cooling: -%d Heat" % cool)
		if shifts_this_turn == 0 and current_gear != 0:
			turns_in_same_gear += 1
			var lug_thresh: int = int(repo.gameplay().get("same_gear_lugging_turns", 2))
			var lug_heat: int = int(repo.gameplay().get("same_gear_lugging_heat", 1))
			if turns_in_same_gear >= lug_thresh and lug_heat > 0:
				_log_event("GEAR LUGGING (%s): +%d Heat — Shift gears to keep drivetrain fresh!" % [transmission.gear_short_name(current_gear), lug_heat])
				floating_text_requested.emit(-1, "LUGGING +%d HEAT!" % lug_heat, repo.get_palette_color("kw_heat_up"))
				_add_heat(lug_heat)
				if mode == MODE_GAME_OVER:
					return
		else:
			turns_in_same_gear = 0

	for cid: String in hand:
		discard_pile.append(cid)
	hand.clear()

	if puncture_turns > 0:
		puncture_turns -= 1
	gear_lock_max = -99
	gear_lock_min = -99

	_begin_enemies_turn_sequence()

func _begin_enemies_turn_sequence() -> void:
	enemy_turn_queue.clear()
	for e_idx: int in range(enemies.size()):
		if bool(enemies[e_idx].get("alive", false)):
			enemies[e_idx]["block"] = 0
			enemy_turn_queue.append(e_idx)
	if enemy_turn_queue.is_empty():
		_start_player_turn()
		return
	mode = MODE_ENEMY_TURN
	active_acting_enemy_index = -1
	enemy_turn_timer = 0.14
	state_changed.emit()

func _process(delta: float) -> void:
	if sim_paused or mode != MODE_ENEMY_TURN:
		return
	enemy_turn_timer -= delta
	if enemy_turn_timer > 0.0:
		return
	if enemy_turn_queue.is_empty():
		active_acting_enemy_index = -1
		if mode == MODE_ENEMY_TURN:
			_start_player_turn()
		return
	var e_idx: int = enemy_turn_queue.pop_front()
	if e_idx < 0 or e_idx >= enemies.size() or not bool(enemies[e_idx].get("alive", false)):
		enemy_turn_timer = 0.05
		return
	active_acting_enemy_index = e_idx
	var enemy: Dictionary = enemies[e_idx]
	var intent: Dictionary = get_enemy_intent(enemy)
	enemy_action_started.emit(e_idx, format_enemy_intent_action_label(intent))
	_resolve_single_enemy_intent(enemy, intent, e_idx)
	if mode != MODE_ENEMY_TURN:
		active_acting_enemy_index = -1
		return
	enemy["intent_index"] = int(enemy.get("intent_index", 0)) + 1
	if int(enemy.get("weakness", 0)) > 0:
		enemy["weakness"] = int(enemy.get("weakness", 0)) - 1
	if int(enemy.get("vulnerable", 0)) > 0:
		enemy["vulnerable"] = int(enemy.get("vulnerable", 0)) - 1
	enemy_turn_timer = float(repo.gameplay().get("enemy_turn_step_delay_s", 0.48))
	state_changed.emit()

func _resolve_single_enemy_intent(enemy: Dictionary, intent: Dictionary, enemy_index: int = -1) -> void:
	var itype: String = str(intent.get("type", "attack"))
	var ename: String = str(enemy.get("name", "Enemy"))
	var is_melee: bool = bool(intent.get("is_melee", false)) or itype == "boss_crush"
	var is_ranged: bool = bool(intent.get("is_ranged", false))

	if bool(intent.get("has_corto_raggio", false)):
		var safe_list: Array = intent.get("safe_gears", [-1, 5, 6]) as Array
		for sg: Variant in safe_list:
			if int(sg) == current_gear:
				_log_event("%s attack MISSES (you are in %s)!" % [ename, transmission.gear_short_name(current_gear)])
				sfx_requested.emit("shift_clack", 0.5)
				return

	var dmg_range: Vector2i = intent_range(intent, "damage", "base_damage")
	if dmg_range.y > 0:
		var rolled_dmg: int = roll_intent_value(intent, "damage", "base_damage") + int(enemy.get("strength", 0))
		if itype == "boss_crush":
			var per_gear: int = int(intent.get("gear_damage_reduction_per_level", 5))
			rolled_dmg = maxi(0, rolled_dmg - maxi(0, current_gear) * per_gear)
		if int(enemy.get("weakness", 0)) > 0:
			rolled_dmg = int(round(float(rolled_dmg) * float(repo.gameplay().get("weakness_damage_multiplier", 0.75))))
		var hits: int = maxi(1, int(intent.get("hits", 1)))
		for _i: int in range(hits):
			_apply_enemy_damage_to_player(rolled_dmg, is_melee, is_ranged)
			if mode == MODE_GAME_OVER:
				return

	var blk_range: Vector2i = intent_range(intent, "block")
	if blk_range.y > 0:
		var blk_val: int = roll_intent_value(intent, "block")
		if itype == "defend_all" or itype == "heal_all":
			for ally: Dictionary in enemies:
				if bool(ally.get("alive", false)):
					ally["block"] = int(ally.get("block", 0)) + blk_val
			_log_event("%s shields all enemies (+%d Shield)" % [ename, blk_val])
		else:
			enemy["block"] = int(enemy.get("block", 0)) + blk_val
			_log_event("%s gains +%d Shield" % [ename, blk_val])
		sfx_requested.emit("shield", 0.8)

	var heal_range: Vector2i = intent_range(intent, "heal")
	if heal_range.y > 0:
		var heal_val: int = roll_intent_value(intent, "heal")
		if itype == "heal_all" or bool(intent.get("heal_all", false)):
			for a_idx: int in range(enemies.size()):
				var ally_e: Dictionary = enemies[a_idx]
				if bool(ally_e.get("alive", false)):
					var cur_h: int = int(ally_e.get("hp", 0))
					var max_h: int = int(ally_e.get("max_hp", cur_h))
					ally_e["hp"] = mini(max_h, cur_h + heal_val)
					floating_text_requested.emit(a_idx, repo.get_ui_text("combat", "float_heal_fmt") % heal_val, repo.get_palette_color("playable_glow"))
			_log_event("%s repairs all enemies (+%d HP)" % [ename, heal_val])
		else:
			var cur_hp: int = int(enemy.get("hp", 0))
			var max_hp_e: int = int(enemy.get("max_hp", cur_hp))
			enemy["hp"] = mini(max_hp_e, cur_hp + heal_val)
			if enemy_index >= 0:
				floating_text_requested.emit(enemy_index, repo.get_ui_text("combat", "float_heal_fmt") % heal_val, repo.get_palette_color("playable_glow"))
			_log_event("%s repairs +%d HP" % [ename, heal_val])
		sfx_requested.emit("shield", 0.75)

	var str_range: Vector2i = intent_range(intent, "strength")
	if str_range.y > 0:
		var str_val: int = roll_intent_value(intent, "strength")
		enemy["strength"] = int(enemy.get("strength", 0)) + str_val
		_log_event("%s gains +%d Strength" % [ename, str_val])

	var punc_range: Vector2i = intent_range(intent, "puncture")
	if punc_range.y > 0:
		var punc_val: int = roll_intent_value(intent, "puncture")
		puncture_turns += punc_val
		_log_event("%s inflicts PUNCTURE (%d turns)!" % [ename, punc_val])

	if intent.has("gear_lock_max"):
		gear_lock_max = int(intent.get("gear_lock_max", 3))
		if current_gear > gear_lock_max:
			var prev_g: int = current_gear
			current_gear = gear_lock_max
			gear_shifted.emit(prev_g, current_gear, true)
		_log_event("%s activates GEAR LOCK (max %s)!" % [ename, transmission.gear_short_name(gear_lock_max)])

	if intent.has("gear_lock_min"):
		gear_lock_min = int(intent.get("gear_lock_min", 3))
		if current_gear < gear_lock_min:
			var prev_g_min: int = current_gear
			current_gear = gear_lock_min
			gear_shifted.emit(prev_g_min, current_gear, true)
		_log_event("%s activates GEAR LOCK (min %s)!" % [ename, transmission.gear_short_name(gear_lock_min)])

	var drain_range: Vector2i = intent_range(intent, "rpm_drain_units")
	if drain_range.y > 0:
		var drained: int = roll_intent_value(intent, "rpm_drain_units")
		rpm_units = maxi(transmission.min_rpm_units(), rpm_units - drained)
		_log_event("%s drains -%d,000 RPM!" % [ename, drained])

	var heat_range: Vector2i = intent_range(intent, "heat_add")
	if heat_range.y > 0:
		var heat_val: int = roll_intent_value(intent, "heat_add")
		_add_heat(heat_val)
		if mode == MODE_GAME_OVER or _check_combat_victory():
			return

func _check_combat_victory() -> bool:
	if alive_enemy_count() > 0:
		return false

	if tutorial_active:
		mode = MODE_VICTORY
		tutorial_active = false
		_log_event(repo.get_ui_text("combat", "tutorial_victory_summary"))
		sfx_requested.emit("victory_chime", 1.0)
		run_ended.emit(true, repo.get_ui_text("combat", "tutorial_victory_summary"))
		state_changed.emit()
		return true

	var enc: Dictionary = current_encounter()
	last_elite_relic_reward = ""
	reward_cards_pre_upgraded = false
	var map_cfg: Dictionary = repo.gameplay().get("run_map", {}) as Dictionary
	var reward_scrap: int = int(enc.get("reward_scrap", 25))
	if bool(enc.get("is_elite", false)):
		reward_scrap += int(map_cfg.get("elite_bonus_scrap", 0))
	for rid: String in owned_relics:
		var rdata: Dictionary = repo.get_relic(rid)
		var pc_heal: int = int(rdata.get("post_combat_heal", 0))
		var pc_scrap: int = int(rdata.get("post_combat_scrap_bonus", 0))
		if pc_heal > 0:
			hp = mini(max_hp, hp + pc_heal)
		if pc_scrap > 0:
			reward_scrap += pc_scrap
		if pc_heal > 0 or pc_scrap > 0:
			_notify_relic_triggered(rid, "+%d HP +%d SCRAP" % [pc_heal, pc_scrap])
	scrap += reward_scrap
	_log_event("Sector cleared! +%d Scrap collected." % reward_scrap)
	sfx_requested.emit("victory_chime", 0.9)

	var is_final_victory: bool = bool(enc.get("is_boss", false))
	if not is_final_victory and run_map_nodes.is_empty():
		is_final_victory = (stage_index + 1 >= repo.encounters.size())

	if is_final_victory:
		mode = MODE_VICTORY
		clear_saved_run()
		run_ended.emit(true, repo.get_ui_text("combat", "victory_summary_fmt") % [hp, max_hp])
		state_changed.emit()
		return true

	if bool(enc.get("is_elite", false)):
		if bool(map_cfg.get("elite_grants_relic", true)):
			last_elite_relic_reward = _grant_random_unowned_relic()
			if not last_elite_relic_reward.is_empty():
				var rname: String = str(repo.get_relic(last_elite_relic_reward).get("name", last_elite_relic_reward))
				_log_event("ELITE TROPHY: %s recovered and installed!" % rname)
		reward_cards_pre_upgraded = bool(map_cfg.get("elite_upgraded_card_rewards", true))

	pending_reward_consumable = ""
	var drop_chance: float = clampf(float(repo.gameplay().get("consumable_drop_chance", 0.65)), 0.0, 1.0)
	if owned_consumables.size() < max_consumable_slots() and not repo.all_consumables.is_empty() and rng.randf() <= drop_chance:
		var c_pool: Array[String] = []
		for cdict: Dictionary in repo.all_consumables:
			var cid: String = str(cdict.get("id", ""))
			if not cid.is_empty():
				c_pool.append(cid)
		if not c_pool.is_empty():
			_shuffle_strings(c_pool)
			pending_reward_consumable = c_pool[0]

	_offer_card_rewards()
	return true

func _offer_card_rewards() -> void:
	mode = MODE_REWARD
	reward_choices.clear()
	var pool: Array[String] = _non_starter_card_pool()
	var count: int = mini(int(repo.gameplay().get("reward_card_choices", 3)), pool.size())
	for i: int in range(count):
		reward_choices.append(pool[i])
	reward_cards_offered.emit(reward_choices)
	state_changed.emit()
	save_active_run()

func claim_reward_consumable() -> bool:
	if mode != MODE_REWARD or pending_reward_consumable.is_empty():
		sfx_requested.emit("blocked", 0.5)
		return false
	if not add_consumable(pending_reward_consumable):
		sfx_requested.emit("blocked", 0.5)
		return false
	var cname: String = str(repo.get_consumable(pending_reward_consumable).get("name", pending_reward_consumable))
	pending_reward_consumable = ""
	_log_event("Canister salvaged: %s loaded into rack!" % cname)
	sfx_requested.emit("shift_clack", 0.85)
	state_changed.emit()
	save_active_run()
	return true

func select_reward_card(card_id: String) -> void:
	if mode != MODE_REWARD:
		return
	if card_id == "__consumable__":
		claim_reward_consumable()
		return
	if card_id == "__repair__":
		var heal_amt: int = 12
		hp = mini(max_hp, hp + heal_amt)
		_log_event("Field repair: +%d Hull HP." % heal_amt)
		sfx_requested.emit("shield", 0.85)
	elif not card_id.is_empty() and not repo.get_card(card_id).is_empty():
		master_deck.append(card_id)
		if reward_cards_pre_upgraded and int(upgrade_levels.get(card_id, 0)) < max_card_upgrade_level():
			upgrade_levels[card_id] = int(upgrade_levels.get(card_id, 0)) + 1
			_log_event("Installed Elite-tuned module: %s (Power %d)!" % [
				str(repo.get_card(card_id).get("name", card_id)),
				int(upgrade_levels[card_id])
			])
		else:
			_log_event(repo.get_ui_text("combat", "card_added_log_fmt") % str(repo.get_card(card_id).get("name", card_id)))
		sfx_requested.emit("card_play", 0.8)
	else:
		scrap += 18
		_log_event("Module recycled: +18 extra Scrap.")
		sfx_requested.emit("shift_clack", 0.75)
	reward_choices.clear()
	last_elite_relic_reward = ""
	pending_reward_consumable = ""
	reward_cards_pre_upgraded = false
	_advance_to_stage_or_route(stage_index + 1)

func _open_workshop() -> void:
	mode = MODE_WORKSHOP
	workshop_reroll_count = 0
	workshop_remove_count = 0
	_generate_workshop_inventory()
	workshop_opened.emit()
	state_changed.emit()
	save_active_run()

func _generate_workshop_inventory() -> void:
	var wcfg: Dictionary = repo.workshop()
	var base_c_cost: int = int(wcfg.get("card_buy_cost", 34))
	var sale_c_cost: int = int(wcfg.get("card_sale_cost", 18))

	var card_pool: Array[String] = []
	for cdict: Dictionary in repo.all_cards:
		if not bool(cdict.get("starter", false)) and str(cdict.get("category", "")) != "Starter":
			card_pool.append(str(cdict.get("id", "")))
	_shuffle_strings(card_pool)

	workshop_card_offers.clear()
	for i: int in range(mini(3, card_pool.size())):
		var is_sale: bool = (i == 2)
		workshop_card_offers.append({
			"card_id": card_pool[i],
			"cost": sale_c_cost if is_sale else base_c_cost,
			"on_sale": is_sale,
			"sold": false
		})

	var relic_pool: Array[String] = []
	for rdict: Dictionary in repo.all_relics:
		var rid: String = str(rdict.get("id", ""))
		if not owned_relics.has(rid):
			relic_pool.append(rid)
	_shuffle_strings(relic_pool)

	workshop_relic_offers.clear()
	for i: int in range(mini(2, relic_pool.size())):
		var rdata: Dictionary = repo.get_relic(relic_pool[i])
		workshop_relic_offers.append({
			"relic_id": relic_pool[i],
			"cost": int(rdata.get("cost", 42)),
			"sold": false
		})
	_sync_legacy_workshop_fields()

func _sync_legacy_workshop_fields() -> void:
	workshop_card_offer = ""
	for co: Dictionary in workshop_card_offers:
		if not bool(co.get("sold", false)):
			workshop_card_offer = str(co.get("card_id", ""))
			break
	workshop_relic_offer = ""
	for ro: Dictionary in workshop_relic_offers:
		if not bool(ro.get("sold", false)):
			workshop_relic_offer = str(ro.get("relic_id", ""))
			break

func workshop_current_reroll_cost() -> int:
	var wcfg: Dictionary = repo.workshop()
	return int(wcfg.get("reroll_cost", 10)) + workshop_reroll_count * int(wcfg.get("reroll_cost_step", 8))

func workshop_current_remove_cost() -> int:
	var wcfg: Dictionary = repo.workshop()
	return int(wcfg.get("card_remove_cost", 22)) + workshop_remove_count * 10

func workshop_repair_hull() -> bool:
	if mode != MODE_WORKSHOP:
		return false
	var cost: int = int(repo.workshop().get("repair_cost", 20))
	var heal: int = int(repo.workshop().get("repair_amount", 25))
	if scrap < cost or hp >= max_hp:
		sfx_requested.emit("blocked", 0.5)
		return false
	scrap -= cost
	hp = mini(max_hp, hp + heal)
	_log_event("Workshop: Hull repaired (+%d HP)" % heal)
	sfx_requested.emit("shield", 0.85)
	state_changed.emit()
	save_active_run()
	return true

func workshop_reinforce_chassis() -> bool:
	if mode != MODE_WORKSHOP:
		return false
	var cost: int = int(repo.workshop().get("tune_cost", 30))
	var bonus_hp: int = int(repo.workshop().get("tune_max_hp_bonus", 12))
	if scrap < cost:
		sfx_requested.emit("blocked", 0.5)
		return false
	scrap -= cost
	max_hp += bonus_hp
	hp += bonus_hp
	_log_event("Workshop: Chassis reinforced (+%d Max HP)" % bonus_hp)
	sfx_requested.emit("shift_clack", 0.9)
	state_changed.emit()
	save_active_run()
	return true

func workshop_buy_card() -> bool:
	for i: int in range(workshop_card_offers.size()):
		if not bool(workshop_card_offers[i].get("sold", false)):
			return workshop_buy_card_at(i)
	return false

func workshop_buy_card_at(offer_index: int) -> bool:
	if mode != MODE_WORKSHOP or offer_index < 0 or offer_index >= workshop_card_offers.size():
		return false
	var entry: Dictionary = workshop_card_offers[offer_index]
	if bool(entry.get("sold", false)):
		return false
	var cid: String = str(entry.get("card_id", ""))
	var cost: int = int(entry.get("cost", 34))
	if cid.is_empty() or scrap < cost:
		sfx_requested.emit("blocked", 0.5)
		return false
	scrap -= cost
	master_deck.append(cid)
	entry["sold"] = true
	_sync_legacy_workshop_fields()
	_log_event("Workshop: Purchased %s" % str(repo.get_card(cid).get("name", "")))
	sfx_requested.emit("card_play", 0.85)
	state_changed.emit()
	save_active_run()
	return true

func workshop_buy_relic() -> bool:
	for i: int in range(workshop_relic_offers.size()):
		if not bool(workshop_relic_offers[i].get("sold", false)):
			return workshop_buy_relic_at(i)
	return false

func workshop_buy_relic_at(offer_index: int) -> bool:
	if mode != MODE_WORKSHOP or offer_index < 0 or offer_index >= workshop_relic_offers.size():
		return false
	var entry: Dictionary = workshop_relic_offers[offer_index]
	if bool(entry.get("sold", false)):
		return false
	var rid: String = str(entry.get("relic_id", ""))
	var rdata: Dictionary = repo.get_relic(rid)
	var cost: int = int(entry.get("cost", 42))
	if rid.is_empty() or scrap < cost:
		sfx_requested.emit("blocked", 0.5)
		return false
	scrap -= cost
	owned_relics.append(rid)
	entry["sold"] = true
	_sync_legacy_workshop_fields()
	_log_event("Workshop: Installed %s!" % str(rdata.get("name", "")))
	sfx_requested.emit("shift_clack", 1.0)
	state_changed.emit()
	save_active_run()
	return true

func workshop_remove_deck_card(deck_index: int) -> bool:
	if mode != MODE_WORKSHOP or master_deck.size() <= 4 or deck_index < 0 or deck_index >= master_deck.size():
		sfx_requested.emit("blocked", 0.5)
		return false
	var cost: int = workshop_current_remove_cost()
	if scrap < cost:
		sfx_requested.emit("blocked", 0.5)
		return false
	var removed_id: String = master_deck[deck_index]
	master_deck.remove_at(deck_index)
	scrap -= cost
	workshop_remove_count += 1
	_log_event("Workshop: Dismantled %s from deck!" % str(repo.get_card(removed_id).get("name", removed_id)))
	sfx_requested.emit("grind", 0.7)
	state_changed.emit()
	save_active_run()
	return true

func workshop_reroll_offers() -> bool:
	if mode != MODE_WORKSHOP:
		return false
	var cost: int = workshop_current_reroll_cost()
	if scrap < cost:
		sfx_requested.emit("blocked", 0.5)
		return false
	scrap -= cost
	workshop_reroll_count += 1
	_generate_workshop_inventory()
	_log_event("Workshop: Parts catalog restocked!")
	sfx_requested.emit("shift_clack", 0.85)
	state_changed.emit()
	save_active_run()
	return true

func leave_workshop() -> void:
	if mode != MODE_WORKSHOP:
		return
	_advance_to_stage_or_route(stage_index + 1)

func draw_cards(amount: int) -> void:
	var max_hand: int = int(repo.gameplay().get("max_hand_size", 10))
	for _i: int in range(amount):
		if hand.size() >= max_hand:
			break
		if draw_pile.is_empty():
			if discard_pile.is_empty():
				break
			draw_pile = discard_pile.duplicate()
			discard_pile.clear()
			_shuffle_strings(draw_pile)
		var next_card: String = draw_pile.pop_back()
		hand.append(next_card)

func _shuffle_strings(list: Array[String]) -> void:
	for i: int in range(list.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: String = list[i]
		list[i] = list[j]
		list[j] = tmp

func _log_event(msg: String) -> void:
	combat_log.append(msg)
	if combat_log.size() > 24:
		combat_log.pop_front()
	event_logged.emit(msg)

func has_saved_run() -> bool:
	return FileAccess.file_exists(ACTIVE_RUN_SAVE_PATH)

func clear_saved_run() -> void:
	if FileAccess.file_exists(ACTIVE_RUN_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ACTIVE_RUN_SAVE_PATH))

func peek_saved_run_info() -> Dictionary:
	if not has_saved_run():
		return {}
	var raw: String = FileAccess.get_file_as_string(ACTIVE_RUN_SAVE_PATH)
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed as Dictionary
	if int(d.get("hp", 0)) <= 0:
		return {}
	return d

func to_save_dict() -> Dictionary:
	var save_mode: String = mode
	if save_mode == MODE_ENEMY_TURN or save_mode == MODE_SHIFT_CHOICE:
		save_mode = MODE_COMBAT
	elif save_mode == MODE_ROUTE_TRANSITION:
		save_mode = MODE_ROUTE_CHOICE
	return {
		"version": 1,
		"mode": save_mode,
		"stage_index": stage_index,
		"selected_chassis_id": selected_chassis_id,
		"overdrive_level": overdrive_level,
		"hp": hp,
		"max_hp": max_hp,
		"scrap": scrap,
		"owned_relics": owned_relics.duplicate(),
		"owned_consumables": owned_consumables.duplicate(),
		"upgrade_levels": upgrade_levels.duplicate(true),
		"master_deck": master_deck.duplicate(),
		"run_map_nodes": run_map_nodes.duplicate(true),
		"current_map_node_id": current_map_node_id,
		"visited_map_node_ids": visited_map_node_ids.duplicate(),
		"resolved_encounter": resolved_encounter.duplicate(true),
		"route_options": route_options.duplicate(true),
		"active_site_data": active_site_data.duplicate(true),
		"reward_choices": reward_choices.duplicate(),
		"pending_reward_consumable": pending_reward_consumable,
		"reward_cards_pre_upgraded": reward_cards_pre_upgraded,
		"last_elite_relic_reward": last_elite_relic_reward,
		"workshop_card_offers": workshop_card_offers.duplicate(true),
		"workshop_relic_offers": workshop_relic_offers.duplicate(true),
		"workshop_reroll_count": workshop_reroll_count,
		"workshop_remove_count": workshop_remove_count
	}

func save_active_run() -> void:
	if tutorial_active or hp <= 0 or mode == MODE_TITLE or mode == MODE_GAME_OVER or mode == MODE_VICTORY:
		return
	var f: FileAccess = FileAccess.open(ACTIVE_RUN_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(to_save_dict()))
	f.close()

func load_saved_run() -> bool:
	if not has_saved_run():
		return false
	var raw: String = FileAccess.get_file_as_string(ACTIVE_RUN_SAVE_PATH)
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		clear_saved_run()
		return false
	return load_from_save_dict(parsed as Dictionary)

func load_from_save_dict(raw_data: Dictionary) -> bool:
	if repo == null or raw_data.is_empty():
		return false
	var data: Dictionary = _normalize_json_numbers(raw_data) as Dictionary
	var saved_hp: int = int(data.get("hp", 0))
	var raw_nodes: Array = data.get("run_map_nodes", []) as Array
	if saved_hp <= 0 or raw_nodes.is_empty():
		return false

	tutorial_active = false
	sim_paused = false
	selected_chassis_id = str(data.get("selected_chassis_id", "interceptor"))
	if get_chassis_preset(selected_chassis_id).is_empty():
		selected_chassis_id = "interceptor"
	overdrive_level = clampi(int(data.get("overdrive_level", 0)), 0, 5)
	_reset_run_state()

	max_hp = maxi(10, int(data.get("max_hp", max_hp)))
	hp = clampi(saved_hp, 1, max_hp)
	scrap = maxi(0, int(data.get("scrap", scrap)))
	stage_index = maxi(0, int(data.get("stage_index", 0)))
	current_map_node_id = str(data.get("current_map_node_id", ""))

	owned_relics = _to_string_array(data.get("owned_relics", []))
	owned_consumables = _to_string_array(data.get("owned_consumables", []))
	var saved_deck: Array[String] = _to_string_array(data.get("master_deck", []))
	if not saved_deck.is_empty():
		master_deck = saved_deck

	upgrade_levels.clear()
	var upg_raw: Variant = data.get("upgrade_levels", {})
	if typeof(upg_raw) == TYPE_DICTIONARY:
		for k: Variant in (upg_raw as Dictionary).keys():
			upgrade_levels[str(k)] = clampi(int((upg_raw as Dictionary)[k]), 0, max_card_upgrade_level())

	run_map_nodes = _to_dict_array(raw_nodes)
	for nd: Dictionary in run_map_nodes:
		nd["next_ids"] = _to_string_array(nd.get("next_ids", []))
	visited_map_node_ids = _to_string_array(data.get("visited_map_node_ids", []))
	resolved_encounter = (data.get("resolved_encounter", {}) as Dictionary).duplicate(true)

	var saved_mode: String = str(data.get("mode", MODE_COMBAT))
	match saved_mode:
		MODE_REWARD:
			mode = MODE_REWARD
			reward_choices = _to_string_array(data.get("reward_choices", []))
			pending_reward_consumable = str(data.get("pending_reward_consumable", ""))
			reward_cards_pre_upgraded = bool(data.get("reward_cards_pre_upgraded", false))
			last_elite_relic_reward = str(data.get("last_elite_relic_reward", ""))
			reward_cards_offered.emit(reward_choices)
			state_changed.emit()
		MODE_WORKSHOP:
			mode = MODE_WORKSHOP
			workshop_card_offers = _to_dict_array(data.get("workshop_card_offers", []))
			workshop_relic_offers = _to_dict_array(data.get("workshop_relic_offers", []))
			workshop_reroll_count = maxi(0, int(data.get("workshop_reroll_count", 0)))
			workshop_remove_count = maxi(0, int(data.get("workshop_remove_count", 0)))
			if workshop_card_offers.is_empty():
				_generate_workshop_inventory()
			else:
				_sync_legacy_workshop_fields()
			workshop_opened.emit()
			state_changed.emit()
		MODE_ROUTE_CHOICE:
			mode = MODE_ROUTE_CHOICE
			route_options = _to_dict_array(data.get("route_options", []))
			if route_options.is_empty():
				_advance_to_stage_or_route(stage_index)
			else:
				route_choices_offered.emit(route_options)
				state_changed.emit()
		MODE_REST, MODE_UPGRADE, MODE_EVENT:
			var sdata: Dictionary = (data.get("active_site_data", {}) as Dictionary).duplicate(true)
			if sdata.is_empty():
				var cur_nd: Dictionary = RunMapGenerator.find_node(run_map_nodes, current_map_node_id)
				_enter_map_node(cur_nd)
			else:
				_open_site(saved_mode, sdata)
		_:
			if resolved_encounter.is_empty():
				var cur_n: Dictionary = RunMapGenerator.find_node(run_map_nodes, current_map_node_id)
				_enter_map_node(cur_n)
			else:
				_setup_combat_encounter(resolved_encounter)
	return true

static func _to_string_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(raw) == TYPE_ARRAY:
		for item: Variant in (raw as Array):
			out.append(str(item))
	return out

static func _to_dict_array(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) == TYPE_ARRAY:
		for item: Variant in (raw as Array):
			if typeof(item) == TYPE_DICTIONARY:
				out.append((item as Dictionary).duplicate(true))
	return out

static func _normalize_json_numbers(val: Variant) -> Variant:
	match typeof(val):
		TYPE_FLOAT:
			var f: float = val as float
			if not is_nan(f) and not is_inf(f) and absf(f - roundf(f)) < 0.00001:
				return int(roundf(f))
			return f
		TYPE_ARRAY:
			var arr: Array = []
			for item: Variant in (val as Array):
				arr.append(_normalize_json_numbers(item))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k: Variant in (val as Dictionary).keys():
				d[str(k)] = _normalize_json_numbers((val as Dictionary)[k])
			return d
		_:
			return val
