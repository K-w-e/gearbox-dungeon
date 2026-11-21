class_name TransmissionSystem
extends RefCounted

var repo: GameRepository

func _init(repository: GameRepository) -> void:
	repo = repository

func min_gear() -> int:
	return int(repo.gameplay().get("min_gear", -1))

func max_gear() -> int:
	return int(repo.gameplay().get("max_gear", 6))

func min_rpm_units() -> int:
	return int(repo.gameplay().get("min_rpm_units", 0))

func max_rpm_units() -> int:
	return int(repo.gameplay().get("max_rpm_units", 8))

func clamp_gear(target_gear: int, gear_lock_max: int, gear_lock_min: int = -99) -> int:
	var lower_bound: int = min_gear()
	if gear_lock_min >= min_gear():
		lower_bound = maxi(lower_bound, gear_lock_min)
	var upper_bound: int = max_gear()
	if gear_lock_max >= min_gear():
		upper_bound = mini(upper_bound, gear_lock_max)
	return clampi(target_gear, lower_bound, maxi(lower_bound, upper_bound))

func evaluate_manual_shift(current_gear: int, target_gear: int, free_shift_available: bool, gear_lock_max: int, grind_hull_immune: bool, gear_lock_min: int = -99, bonus_free_range: int = 0) -> Dictionary:
	var result: Dictionary = {
		"allowed": false,
		"reason": "",
		"target_gear": target_gear,
		"steps": 0,
		"extra_grind_steps": 0,
		"hp_cost": 0,
		"heat_cost": 0,
		"uses_free_shift": false
	}
	if target_gear < min_gear() or target_gear > max_gear():
		result["reason"] = "Gear out of range"
		return result
	if target_gear == current_gear:
		result["reason"] = "Gear already engaged"
		return result
	if gear_lock_max >= min_gear() and target_gear > gear_lock_max:
		result["reason"] = "GEAR LOCK active (max %s)" % gear_short_name(gear_lock_max)
		return result
	if gear_lock_min >= min_gear() and target_gear < gear_lock_min:
		result["reason"] = "GEAR LOCK active (min %s)" % gear_short_name(gear_lock_min)
		return result

	var total_steps: int = absi(target_gear - current_gear)
	var free_range: int = int(repo.gameplay().get("free_manual_shift_range", 1)) + maxi(0, bonus_free_range)
	var covered_free: int = free_range if free_shift_available else 0
	var extra_steps: int = maxi(0, total_steps - covered_free)
	var hp_per_step: int = 0 if grind_hull_immune else int(repo.gameplay().get("grind_hp_cost_per_step", 3))
	var heat_per_step: int = int(repo.gameplay().get("grind_heat_cost_per_step", 1))

	result["allowed"] = true
	result["steps"] = total_steps
	result["extra_grind_steps"] = extra_steps
	result["hp_cost"] = extra_steps * hp_per_step
	result["heat_cost"] = extra_steps * heat_per_step
	result["uses_free_shift"] = free_shift_available
	return result

func effective_card_rpm_delta(card: Dictionary, current_gear: int) -> int:
	var base_delta: int = int(card.get("rpm_delta_units", 0))
	if base_delta < 0:
		var gear_data: Dictionary = repo.get_gear(current_gear)
		var reduction: int = int(gear_data.get("rpm_cost_reduction_units", 0))
		if reduction > 0:
			base_delta = mini(0, base_delta + reduction)
	return base_delta

func is_stall_risk(current_gear: int, rpm_units: int) -> bool:
	var gear_data: Dictionary = repo.get_gear(current_gear)
	var stall_threshold: int = int(gear_data.get("stall_rpm_units", 0))
	return stall_threshold > 0 and rpm_units < stall_threshold

func is_redline(current_gear: int, rpm_units: int) -> bool:
	var gear_data: Dictionary = repo.get_gear(current_gear)
	var redline_threshold: int = int(gear_data.get("redline_rpm_units", 8))
	return rpm_units >= redline_threshold

func is_optimal(current_gear: int, rpm_units: int) -> bool:
	var gear_data: Dictionary = repo.get_gear(current_gear)
	var opt_min: int = int(gear_data.get("optimal_min_units", 0))
	var opt_max: int = int(gear_data.get("optimal_max_units", 8))
	return rpm_units >= opt_min and rpm_units <= opt_max and not is_redline(current_gear, rpm_units)

func gear_short_name(gear_index: int) -> String:
	var gear_data: Dictionary = repo.get_gear(gear_index)
	return str(gear_data.get("short_name", str(gear_index)))

func gear_range_token(gear_index: int) -> String:
	if gear_index < 0:
		return "R"
	if gear_index == 0:
		return "N"
	return str(gear_index)

func format_allowed_gears(allowed: Array) -> String:
	if allowed.is_empty():
		return "-"
	var sorted_g: Array[int] = []
	for g_val: Variant in allowed:
		sorted_g.append(int(g_val))
	sorted_g.sort()
	var ranges: PackedStringArray = PackedStringArray()
	var start_g: int = sorted_g[0]
	var prev_g: int = sorted_g[0]
	for i: int in range(1, sorted_g.size()):
		var cur_g: int = sorted_g[i]
		if cur_g == prev_g + 1:
			prev_g = cur_g
		else:
			ranges.append(gear_range_token(start_g) if start_g == prev_g else ("%s-%s" % [gear_range_token(start_g), gear_range_token(prev_g)]))
			start_g = cur_g
			prev_g = cur_g
	ranges.append(gear_range_token(start_g) if start_g == prev_g else ("%s-%s" % [gear_range_token(start_g), gear_range_token(prev_g)]))
	return ", ".join(ranges)
