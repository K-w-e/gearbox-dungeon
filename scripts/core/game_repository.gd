class_name GameRepository
extends RefCounted

const DATA_ROOT: String = "res://data/"

var config: Dictionary = {}
var cockpit: Dictionary = {}
var title_menu: Dictionary = {}
var ui_strings: Dictionary = {}
var gears_by_index: Dictionary = {}
var ordered_gears: Array[Dictionary] = []
var cards_by_id: Dictionary = {}
var all_cards: Array[Dictionary] = []
var enemies_by_id: Dictionary = {}
var encounters: Array[Dictionary] = []
var relics_by_id: Dictionary = {}
var all_relics: Array[Dictionary] = []
var consumables_by_id: Dictionary = {}
var all_consumables: Array[Dictionary] = []
var events_config: Dictionary = {}
var random_events_by_id: Dictionary = {}
var all_random_events: Array[Dictionary] = []
var fonts: Dictionary = {}
var model_cache: Dictionary = {}
var is_valid: bool = false

func load_all() -> bool:
	config = JsonConfigLoader.load_dictionary(DATA_ROOT + "config.json")
	cockpit = JsonConfigLoader.load_dictionary(DATA_ROOT + "cockpit_3d.json")
	title_menu = JsonConfigLoader.load_dictionary(DATA_ROOT + "title_menu.json")
	ui_strings = JsonConfigLoader.load_dictionary(DATA_ROOT + "ui_strings.json")
	var raw_gears: Array = JsonConfigLoader.load_array(DATA_ROOT + "gears.json")
	var raw_cards: Array = JsonConfigLoader.load_array(DATA_ROOT + "cards.json")
	var raw_enemies: Array = JsonConfigLoader.load_array(DATA_ROOT + "enemies.json")
	var raw_encounters: Array = JsonConfigLoader.load_array(DATA_ROOT + "encounters.json")
	var raw_relics: Array = JsonConfigLoader.load_array(DATA_ROOT + "relics.json")
	events_config = JsonConfigLoader.load_dictionary(DATA_ROOT + "events.json")

	if config.is_empty() or cockpit.is_empty() or title_menu.is_empty() or events_config.is_empty() or raw_gears.is_empty() or raw_cards.is_empty() or raw_enemies.is_empty() or raw_encounters.is_empty():
		push_error("GameRepository failed validation: one or more required JSON tables are empty")
		is_valid = false
		return false

	gears_by_index.clear()
	ordered_gears.clear()
	for entry: Variant in raw_gears:
		if typeof(entry) == TYPE_DICTIONARY:
			var gear_dict: Dictionary = entry as Dictionary
			var idx: int = int(gear_dict.get("index", 0))
			gears_by_index[idx] = gear_dict
			ordered_gears.append(gear_dict)
	ordered_gears.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("index", 0)) < int(b.get("index", 0)))

	cards_by_id.clear()
	all_cards.clear()
	for entry: Variant in raw_cards:
		if typeof(entry) == TYPE_DICTIONARY:
			var card_dict: Dictionary = entry as Dictionary
			if card_dict.has("allowed_gears") and typeof(card_dict["allowed_gears"]) == TYPE_ARRAY:
				var norm_gears: Array[int] = []
				for gv: Variant in (card_dict["allowed_gears"] as Array):
					norm_gears.append(int(gv))
				card_dict["allowed_gears"] = norm_gears
			var cid: String = str(card_dict.get("id", ""))
			if not cid.is_empty():
				cards_by_id[cid] = card_dict
				all_cards.append(card_dict)

	enemies_by_id.clear()
	for entry: Variant in raw_enemies:
		if typeof(entry) == TYPE_DICTIONARY:
			var enemy_dict: Dictionary = entry as Dictionary
			var eid: String = str(enemy_dict.get("id", ""))
			if not eid.is_empty():
				enemies_by_id[eid] = enemy_dict

	encounters.clear()
	for entry: Variant in raw_encounters:
		if typeof(entry) == TYPE_DICTIONARY:
			encounters.append(entry as Dictionary)
	encounters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("stage", 0)) < int(b.get("stage", 0)))

	relics_by_id.clear()
	all_relics.clear()
	for entry: Variant in raw_relics:
		if typeof(entry) == TYPE_DICTIONARY:
			var relic_dict: Dictionary = entry as Dictionary
			var rid: String = str(relic_dict.get("id", ""))
			if not rid.is_empty():
				relics_by_id[rid] = relic_dict
				all_relics.append(relic_dict)

	consumables_by_id.clear()
	all_consumables.clear()
	var raw_cons: Array = gameplay().get("consumables", []) as Array
	for entry: Variant in raw_cons:
		if typeof(entry) == TYPE_DICTIONARY:
			var c_dict: Dictionary = entry as Dictionary
			var cid: String = str(c_dict.get("id", ""))
			if not cid.is_empty():
				consumables_by_id[cid] = c_dict
				all_consumables.append(c_dict)

	random_events_by_id.clear()
	all_random_events.clear()
	var raw_rand_events: Array = events_config.get("random_events", []) as Array
	for entry: Variant in raw_rand_events:
		if typeof(entry) == TYPE_DICTIONARY:
			var ev_dict: Dictionary = entry as Dictionary
			var evid: String = str(ev_dict.get("id", ""))
			if not evid.is_empty():
				random_events_by_id[evid] = ev_dict
				all_random_events.append(ev_dict)

	is_valid = not gears_by_index.is_empty() and not cards_by_id.is_empty() and not enemies_by_id.is_empty() and not all_random_events.is_empty()
	if not is_valid:
		push_error("GameRepository failed indexing required entities")
		return false
	_load_fonts()
	return is_valid

func _load_fonts() -> void:
	fonts.clear()
	var typo: Dictionary = cockpit.get("typography", {}) as Dictionary
	for role: String in ["display", "body_bold", "body", "mono"]:
		var path: String = str(typo.get(role, ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			push_error("Typography font missing for role '%s': %s" % [role, path])
			continue
		var loaded: Resource = ResourceLoader.load(path)
		if loaded is Font:
			fonts[role] = loaded
		else:
			push_error("Loaded resource is not a Font for role '%s': %s" % [role, path])
	var proj_theme: Theme = ThemeDB.get_project_theme()
	if proj_theme != null and fonts.has("body_bold"):
		proj_theme.default_font = fonts["body_bold"] as Font

func get_font(role: String = "body_bold") -> Font:
	if fonts.has(role):
		return fonts[role] as Font
	if fonts.has("body_bold"):
		return fonts["body_bold"] as Font
	return ThemeDB.fallback_font

func get_outline_color() -> Color:
	var typo: Dictionary = cockpit.get("typography", {}) as Dictionary
	return JsonConfigLoader.to_color(typo.get("outline_color", []), Color.BLACK)

func screen_style() -> Dictionary:
	return cockpit.get("screen_style", {}) as Dictionary

func gameplay() -> Dictionary:
	return config.get("gameplay", {}) as Dictionary

func workshop() -> Dictionary:
	return config.get("workshop", {}) as Dictionary

func audio_cfg() -> Dictionary:
	return config.get("audio", {}) as Dictionary

func title_menu_cfg() -> Dictionary:
	return title_menu

func get_gear(gear_index: int) -> Dictionary:
	if gears_by_index.has(gear_index):
		return gears_by_index[gear_index] as Dictionary
	push_error("Requested unknown gear index: %d" % gear_index)
	return gears_by_index.get(0, {}) as Dictionary

func get_card(card_id: String) -> Dictionary:
	if cards_by_id.has(card_id):
		return cards_by_id[card_id] as Dictionary
	push_error("Requested unknown card id: %s" % card_id)
	return {}

func get_enemy(enemy_id: String) -> Dictionary:
	if enemies_by_id.has(enemy_id):
		return enemies_by_id[enemy_id] as Dictionary
	push_error("Requested unknown enemy id: %s" % enemy_id)
	return {}

func get_relic(relic_id: String) -> Dictionary:
	if relics_by_id.has(relic_id):
		return relics_by_id[relic_id] as Dictionary
	return {}

func get_consumable(cons_id: String) -> Dictionary:
	if consumables_by_id.has(cons_id):
		return consumables_by_id[cons_id] as Dictionary
	return {}

func rest_site() -> Dictionary:
	return events_config.get("rest_site", {}) as Dictionary

func upgrade_site() -> Dictionary:
	return events_config.get("upgrade_site", {}) as Dictionary

func get_random_event(event_id: String) -> Dictionary:
	if random_events_by_id.has(event_id):
		return random_events_by_id[event_id] as Dictionary
	return all_random_events[0] if not all_random_events.is_empty() else {}

func encounter_for_stage(stage_num: int) -> Dictionary:
	for enc_entry: Dictionary in encounters:
		if int(enc_entry.get("stage", -1)) == stage_num:
			return enc_entry
	if not encounters.is_empty():
		var clamped_idx: int = clampi(stage_num - 1, 0, encounters.size() - 1)
		return encounters[clamped_idx]
	return {}

func get_ui_text(section: String, key: String) -> String:
	var sec_val: Variant = ui_strings.get(section, {})
	if typeof(sec_val) == TYPE_DICTIONARY:
		return str((sec_val as Dictionary).get(key, key))
	return key

func get_keyword_meta(keyword_id: String) -> Dictionary:
	var kw_sec: Variant = ui_strings.get("keywords", {})
	if typeof(kw_sec) == TYPE_DICTIONARY and (kw_sec as Dictionary).has(keyword_id):
		var entry: Variant = (kw_sec as Dictionary).get(keyword_id)
		if typeof(entry) == TYPE_DICTIONARY:
			return entry as Dictionary
	push_error("Requested unknown keyword metadata: %s" % keyword_id)
	return {"label": keyword_id.to_upper(), "color_key": "kw_utility", "glossary": ""}

func get_all_keywords() -> Dictionary:
	var kw_sec: Variant = ui_strings.get("keywords", {})
	if typeof(kw_sec) == TYPE_DICTIONARY:
		return kw_sec as Dictionary
	return {}

func get_category_short(category: String) -> String:
	var cats: Variant = ui_strings.get("categories", {})
	if typeof(cats) == TYPE_DICTIONARY:
		return str((cats as Dictionary).get(category, category.to_upper()))
	return category.to_upper()

func get_category_color(category: String) -> Color:
	return get_palette_color("cat_" + category, Color(0.24, 0.44, 0.62))

func get_palette_color(key: String, fallback: Color = Color.WHITE) -> Color:
	var pal: Dictionary = cockpit.get("palette", {}) as Dictionary
	return JsonConfigLoader.to_color(pal.get(key, []), fallback)

func load_model_scene(model_key_or_path: String) -> PackedScene:
	var models_map: Dictionary = cockpit.get("models", {}) as Dictionary
	var resolved_path: String = str(models_map.get(model_key_or_path, model_key_or_path))
	if model_cache.has(resolved_path):
		return model_cache[resolved_path] as PackedScene
	if resolved_path.is_empty() or not ResourceLoader.exists(resolved_path):
		push_error("Model resource missing: %s" % resolved_path)
		return null
	var res: Resource = ResourceLoader.load(resolved_path)
	if res is PackedScene:
		model_cache[resolved_path] = res
		return res as PackedScene
	push_error("Loaded resource is not a PackedScene: %s" % resolved_path)
	return null
