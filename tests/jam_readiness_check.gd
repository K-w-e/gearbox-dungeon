extends SceneTree

var _step: int = 0

func _process(_delta: float) -> bool:
	if _step == 1:
		quit(0)
		return true
	if _step > 1:
		return true
	_step = 1

	var profile_path: String = MainGame.PILOT_PROFILE_PATH
	var had_profile: bool = FileAccess.file_exists(profile_path)
	var backup_profile: PackedByteArray = FileAccess.get_file_as_bytes(profile_path) if had_profile else PackedByteArray()
	if had_profile:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(profile_path))

	var save_path: String = CombatEngine.ACTIVE_RUN_SAVE_PATH
	var had_save: bool = FileAccess.file_exists(save_path)
	var backup_save: PackedByteArray = FileAccess.get_file_as_bytes(save_path) if had_save else PackedByteArray()
	if had_save:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))

	var main_scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	assert(main_scene != null, "main.tscn must load")
	var game: MainGame = main_scene.instantiate() as MainGame
	root.add_child(game)

	# 1. Data & first-boot onboarding check
	assert(game.repo != null and game.repo.is_valid, "GameRepository must be valid")
	assert(game.hand_ctrl.get_parent() == game.cockpit_rig, "hand_ctrl must be parented under cockpit_rig")
	assert(game.terminal_ctrl.first_boot_tutorial_recommended, "First boot should highlight Guided Run")
	assert(game.terminal_ctrl.hotspots.size() >= 2, "Title hotspots must be populated")
	assert(str(game.terminal_ctrl.hotspots[0].get("title", "")).find("FIRST SHIFT") >= 0, "Slot [1] on first boot must be First Shift Guided Run")

	# 2. Start run with deterministic seed & verify first-boot Cockpit Popup Tour + 11-tier DAG
	game.engine.rng.seed = 20261112
	game._on_title_action("run:interceptor:0")
	assert(game.engine.mode == CombatEngine.MODE_COMBAT, "Must enter normal combat run")
	assert(not game.terminal_ctrl.first_boot_tutorial_recommended, "Onboarding flag should clear after starting")
	assert(game.tutorial_ctrl.is_active() and game.tutorial_ctrl.is_quick_mode and game.tutorial_ctrl.steps.size() == 3 and game.hud.tour_active and game.hud.tour_panel.visible, "First-boot normal run must automatically open 3-step Quick Cockpit Tour")
	game.tutorial_ctrl.stop()
	assert(not game.tutorial_ctrl.is_active() and not game.hud.tour_active, "Stopping Cockpit Tour must hide popup cleanly")

	var gear_before_wheel: int = game.engine.current_gear
	var wheel_ev: InputEventMouseButton = InputEventMouseButton.new()
	wheel_ev.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_ev.pressed = true
	game._unhandled_input(wheel_ev)
	assert(game.engine.current_gear == gear_before_wheel, "Mouse wheel in combat must NOT shift gears")

	assert(game.cycle_quality_preset() == "medium", "Quality cycle 1 must switch to medium")
	assert(game.cycle_quality_preset() == "low" and not game.world_props_ctrl.visible, "Low quality must hide tunnel props")
	assert(game.cycle_quality_preset() == "high" and game.world_props_ctrl.visible, "Quality cycle must wrap back to high")

	game.engine.stage_index = 0
	game._update_biome_atmosphere(0.5)
	assert(game.active_biome_id == "rust_tunnels", "Stage 0 must select rust_tunnels biome")
	game.engine.stage_index = 4
	game._update_biome_atmosphere(0.5)
	assert(game.active_biome_id == "chemical_conduits", "Stage 4 must select chemical_conduits biome")
	game.engine.stage_index = 7
	game._update_biome_atmosphere(0.5)
	assert(game.active_biome_id == "turbine_halls", "Stage 7 must select turbine_halls biome")
	game.engine.stage_index = 0
	game._update_biome_atmosphere(1.0)
	assert(game.engine.owned_consumables.size() == 1, "Starter consumable must be granted")
	assert(game.engine.rpm_units == 2, "Interceptor must start at exact 2,000 RPM (2 units), without +1 bug")

	var max_tier: int = 0
	var tier9_types: Array[String] = []
	for nd: Dictionary in game.engine.run_map_nodes:
		var stg: int = int(nd.get("stage_index", 0))
		max_tier = maxi(max_tier, stg)
		if stg == 9:
			tier9_types.append(str(nd.get("type", "")))
	assert(max_tier == 10, "Run DAG must have 11 tiers (stage_index 0..10)")
	assert(tier9_types.has("workshop") and tier9_types.has("rest"), "Pre-boss tier 9 must guarantee Workshop + Pit-Shelter")

	# 2b. Multi-seed Slay-the-Spire planar DAG & Sat-Nav checks
	for s_seed: int in range(100, 125):
		var test_rng: RandomNumberGenerator = RandomNumberGenerator.new()
		test_rng.seed = s_seed
		var dag: Array[Dictionary] = RunMapGenerator.generate_run_dag(game.repo, test_rng)
		assert(not dag.is_empty(), "DAG must generate for seed %d" % s_seed)
		var reach_from_start: Array[String] = RunMapGenerator.compute_reachable_ids(dag, "s0_b0")
		assert(reach_from_start.size() == dag.size(), "Every node must be reachable from s0_b0 (no orphans) on seed %d" % s_seed)
		var boss_id: String = str(dag[dag.size() - 1].get("id", ""))
		var anc_of_boss: Array[String] = RunMapGenerator.compute_ancestor_ids(dag, boss_id)
		assert(anc_of_boss.size() == dag.size(), "Every node must lead to Boss (no dead ends) on seed %d" % s_seed)

		var by_stg: Dictionary = {}
		for nd_chk: Dictionary in dag:
			var st_i: int = int(nd_chk.get("stage_index", 0))
			if not by_stg.has(st_i):
				by_stg[st_i] = []
			(by_stg[st_i] as Array).append(nd_chk)

		for st_i: int in range(10):
			var row_nodes: Array = by_stg.get(st_i, []) as Array
			var prev_max_target: int = -1
			for u_i: int in range(row_nodes.size()):
				var u_nd: Dictionary = row_nodes[u_i] as Dictionary
				var outs: Array = u_nd.get("next_ids", []) as Array
				assert(outs.size() >= 1 and outs.size() <= 2, "Every non-boss node must have 1..2 outgoing edges")
				var u_kind: String = RunMapGenerator.semantic_node_kind(u_nd)
				var prev_lane: float = -999.0
				for nxt_id_v: Variant in outs:
					var v_nd: Dictionary = RunMapGenerator.find_node(dag, str(nxt_id_v))
					var v_b: int = int(v_nd.get("branch_index", 0))
					var v_lane: float = float(v_nd.get("lane_norm", 0.0))
					assert(v_lane > prev_lane, "Outgoing next_ids must be ordered left-to-right")
					prev_lane = v_lane
					assert(v_b >= prev_max_target, "Planar DAG must have zero edge crossings on seed %d stage %d" % [s_seed, st_i])
					prev_max_target = maxi(prev_max_target, v_b)
					var v_kind: String = RunMapGenerator.semantic_node_kind(v_nd)
					if RunMapGenerator.NO_REPEAT_TYPES.has(u_kind):
						assert(u_kind != v_kind, "No consecutive %s -> %s allowed (seed %d)" % [u_kind, v_kind, s_seed])

	game.navigator_ctrl.set_zoomed(true)
	assert(game.navigator_ctrl.is_zoomed and game.navigator_ctrl.legend_rects.size() == 6, "Zoomed Sat-Nav must build 6 legend filter pills")
	var scroll_before: float = game.navigator_ctrl.target_scroll_stage
	game.navigator_ctrl.scroll_map(2.0)
	assert(game.navigator_ctrl.target_scroll_stage > scroll_before, "Sat-Nav scroll_map(+2.0) must advance target_scroll_stage")
	assert(not game.navigator_ctrl.describe_route_via_fork("s1_b0").is_empty(), "Sat-Nav must report VIA [1] LEFT for left branch target")
	game.navigator_ctrl.set_zoomed(false)

	# 3. Overhead Ticker priority & Predictive shift feedback
	game.overhead_ctrl.set_scanner_text("SCANNER TEST")
	assert(str(game.overhead_ctrl.resolve_ticker_state().get("mode", "")) == "scanner", "Scanner text must take ticker priority")
	game.overhead_ctrl.set_scanner_text("")

	var pred_txt: String = game.shifter_ctrl.describe_slot_hover(2)
	assert(pred_txt.find("CARDS READY") >= 0, "Slot hover must show predictive ready cards count")
	game.shifter_ctrl.set_hovered_slot(2)
	assert(game.engine.effective_gear() == 2, "Preview gear override must activate on slot hover")
	game.shifter_ctrl.set_hovered_slot(-99)
	assert(game.engine.effective_gear() == 1, "Preview gear override must reset")

	# 4. Standalone Right/Left Shift tap vs Shift+W combo
	var r_down: InputEventKey = InputEventKey.new()
	r_down.keycode = KEY_SHIFT
	r_down.location = KEY_LOCATION_RIGHT
	r_down.pressed = true
	game._unhandled_input(r_down)
	assert(game.engine.current_gear == 1, "Shift press alone must wait for release so combos work")
	var r_up: InputEventKey = InputEventKey.new()
	r_up.keycode = KEY_SHIFT
	r_up.location = KEY_LOCATION_RIGHT
	r_up.pressed = false
	game._unhandled_input(r_up)
	assert(game.engine.current_gear == 2, "Right Shift tap must upshift to 2nd")

	game.engine.free_shift_available = true
	var l_down: InputEventKey = InputEventKey.new()
	l_down.keycode = KEY_SHIFT
	l_down.location = KEY_LOCATION_LEFT
	l_down.pressed = true
	game._unhandled_input(l_down)
	var w_down: InputEventKey = InputEventKey.new()
	w_down.keycode = KEY_W
	w_down.shift_pressed = true
	w_down.pressed = true
	game._unhandled_input(w_down)
	var l_up: InputEventKey = InputEventKey.new()
	l_up.keycode = KEY_SHIFT
	l_up.location = KEY_LOCATION_LEFT
	l_up.pressed = false
	game._unhandled_input(l_up)
	assert(game.engine.current_gear == 3, "Shift+W must upshift once to 3rd without Left Shift release downshifting")

	# 5. Consumable [Z] hotkey & Card Footer states (ARMED / REDLINE)
	var rpm_before_z: int = game.engine.rpm_units
	var z_ev: InputEventKey = InputEventKey.new()
	z_ev.keycode = KEY_Z
	z_ev.pressed = true
	game._unhandled_input(z_ev)
	assert(game.engine.owned_consumables.is_empty() and game.engine.rpm_units > rpm_before_z, "[Z] must deploy slot 0 Nitro Shot")

	if not game.engine.hand.is_empty():
		game.engine.current_gear = 1
		game.engine.rpm_units = 6
		game.hand_ctrl._rebuild_hand()
		var c0: CardEmblemCanvas = game.hand_ctrl.card_nodes[0].get("card_canvas") as CardEmblemCanvas
		assert(c0.shortcut_badge.is_empty(), "Hand cards must not display keyboard play shortcut badges")
		if bool(game.hand_ctrl.card_nodes[0].get("playable", false)):
			assert(not c0.footer_text.is_empty(), "Playable card in Redline must display REDLINE footer")
		var hand_sz_before_key: int = game.engine.hand.size()
		var k1_ev: InputEventKey = InputEventKey.new()
		k1_ev.keycode = KEY_1
		k1_ev.pressed = true
		game._unhandled_input(k1_ev)
		game._unhandled_input(k1_ev)
		assert(game.engine.hand.size() == hand_sz_before_key, "Pressing [1] in combat must NOT play cards without dragging")
		var vm_card: Dictionary = game.repo.get_card(game.engine.hand[0])
		var vm: Dictionary = CardEffectFormatter.build_card_visual_model(game.repo, game.engine, vm_card)
		assert(not (vm.get("hero", {}) as Dictionary).is_empty(), "Card visual model must produce a hero readout")

	# 6. Mute, Master & Sub-bus volume checks + Chassis synthesis profiles
	game.audio_ctrl.set_engine_muted(false)
	game.audio_ctrl.set_master_volume(1.0)
	game.audio_ctrl.trigger_sfx("blocked", 0.8)
	assert(game.audio_ctrl.sfx_queue.size() > 0, "Unmuted trigger_sfx must enqueue sound")
	game.audio_ctrl.set_engine_muted(true)
	assert(game.audio_ctrl.sfx_queue.is_empty(), "Muting must clear SFX queue")
	game.audio_ctrl.trigger_sfx("alarm", 0.8)
	assert(game.audio_ctrl.sfx_queue.is_empty(), "Muted audio must block new SFX")
	game.audio_ctrl.set_engine_muted(false)
	assert(absf(game.audio_ctrl.cycle_volume_level() - 0.60) < 0.01, "Volume cycle step 1 -> 60%")
	assert(absf(game.audio_ctrl.cycle_engine_volume() - 0.60) < 0.01, "Engine sub-bus cycle -> 60%")
	assert(absf(game.audio_ctrl.cycle_sfx_volume() - 0.60) < 0.01, "SFX sub-bus cycle -> 60%")
	for ch_id: String in ["interceptor", "bulldozer", "turbo_proto"]:
		game.apply_chassis_visuals(ch_id)
		assert(game.audio_ctrl.active_chassis_id == ch_id, "Audio chassis profile must match active chassis")

	# 7. MFD Tabs (ENGINE | GEARS | GLOSSARY) & SubViewport settings
	var mfd_mat: StandardMaterial3D = game.dashboard_ctrl.mfd_screen_mesh.material_override as StandardMaterial3D
	assert(mfd_mat.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR, "ViewportTexture must use linear filter without dynamic mipmaps")
	game.dashboard_ctrl.set_active_tab(Dashboard3DController.TAB_GEARS)
	assert(game.dashboard_ctrl.active_tab == Dashboard3DController.TAB_GEARS, "MFD must switch to GEARS tab")
	game.dashboard_ctrl.set_active_tab(Dashboard3DController.TAB_GLOSSARY)
	assert(game.dashboard_ctrl.active_tab == Dashboard3DController.TAB_GLOSSARY, "MFD must switch to GLOSSARY tab")
	game.dashboard_ctrl.set_active_tab(Dashboard3DController.TAB_ENGINE)

	# 8. Real Pause freeze & Auto-Save -> Hangar -> CONTINUE RUN roundtrip
	game.engine.scrap = 123
	game.engine.upgrade_levels["colpo_acceleratore"] = 1
	var esc_ev: InputEventKey = InputEventKey.new()
	esc_ev.keycode = KEY_ESCAPE
	esc_ev.pressed = true
	game._unhandled_input(esc_ev)
	assert(game.terminal_ctrl.is_active() and game.terminal_ctrl.screen_mode == "pause_menu", "ESC in combat must deploy pause menu")
	assert(game.engine.sim_paused and not game.arena_ctrl.is_processing(), "Pause menu must freeze CombatEngine and world _process")
	game._unhandled_input(esc_ev)
	assert(not game.terminal_ctrl.is_active() and not game.engine.sim_paused and game.arena_ctrl.is_processing(), "Second ESC must unfreeze simulation")

	game._unhandled_input(esc_ev)
	game.terminal_ctrl.activate_row(3)
	assert(game.engine.mode == CombatEngine.MODE_TITLE, "Pause row [4] must return to Hangar title screen")
	assert(game.engine.has_saved_run(), "Returning to Hangar mid-run must preserve active_run.json")
	assert(str(game.terminal_ctrl.hotspots[0].get("title", "")).find("CONTINUE") >= 0, "Hangar slot [1] must offer CONTINUE ACTIVE SHIFT")
	game._on_title_action("continue")
	assert(game.engine.mode == CombatEngine.MODE_COMBAT and game.engine.scrap == 123, "CONTINUE must restore saved run state")
	assert(int(game.engine.upgrade_levels.get("colpo_acceleratore", 0)) == 1, "CONTINUE must restore card upgrades")

	# 9. Calculation bug checks (upgrade block bonus only if base_blk > 0, pre-upgraded preview, reward canister slot)
	game.engine.current_gear = 2 # 2nd gear has bonus_block_per_card = 0
	var atk_card: Dictionary = game.repo.get_card("colpo_acceleratore")
	var def_card: Dictionary = game.repo.get_card("marcia_ridotta")
	game.engine.upgrade_levels["colpo_acceleratore"] = 1
	game.engine.upgrade_levels["marcia_ridotta"] = 1
	var atk_prev: Dictionary = game.engine.calculate_card_preview(atk_card, false)
	var def_prev: Dictionary = game.engine.calculate_card_preview(def_card, false)
	assert(int(atk_prev.get("block", -1)) == 0, "Upgrading a 0-block attack card must NOT grant Shield")
	assert(int(def_prev.get("block", 0)) == 11, "Upgrading an 8-block defense card must grant 8+3=11 Shield")
	var pre_upg_prev: Dictionary = game.engine.calculate_card_preview(def_card, false, 1)
	assert(int(pre_upg_prev.get("block", 0)) == 14, "bonus_upgrade_level=1 must preview next upgrade tier")

	game.engine.mode = CombatEngine.MODE_REWARD
	game.engine.owned_consumables.clear()
	game.engine.pending_reward_consumable = "cryo_flush"
	game.engine.reward_cards_pre_upgraded = true
	game.terminal_ctrl._on_reward_cards_offered(["nos", "burnout", "tacco_punta"])
	assert(game.terminal_ctrl.hotspots.size() == 3, "Simplified reward screen must show only 3 card choices")
	for hs: Dictionary in game.terminal_ctrl.hotspots:
		assert(str(hs.get("kind", "")) == "reward_card", "All reward hotspots must be reward cards")

	# 10. Universal Pagination on DiegeticTerminal3D (>12 cards)
	game.engine.mode = CombatEngine.MODE_WORKSHOP
	game.engine.master_deck.clear()
	for i: int in range(14):
		game.engine.master_deck.append(str(game.repo.all_cards[i % game.repo.all_cards.size()].get("id", "")))
	game.terminal_ctrl._on_workshop_opened()
	game.terminal_ctrl.workshop_removing_card = true
	game.terminal_ctrl.page_offset = 0
	game.terminal_ctrl._rebuild_hotspots()
	assert(game.terminal_ctrl.step_page(1) and game.terminal_ctrl.page_offset == 6, "Workshop remove view must paginate to offset 6")
	assert(game.terminal_ctrl.step_page(1) and game.terminal_ctrl.page_offset == 12, "Workshop remove view must paginate to offset 12")
	assert(not game.terminal_ctrl.step_page(1), "Pagination must clamp at last page")
	assert(game.terminal_ctrl.step_page(-1) and game.terminal_ctrl.page_offset == 6, "Pagination [<] must step back to offset 6")
	game.terminal_ctrl.workshop_removing_card = false

	# 11. Deterministic Simulation of ALL 31 Cards + Recyclable Discard FX check
	var eng: CombatEngine = game.engine
	eng.rng.seed = 20261112
	assert(game.repo.all_cards.size() == 37, "Catalog must contain all 37 cards")
	assert(game.repo.all_relics.size() == 13, "Catalog must contain all 13 relics")
	assert(game.repo.enemies_by_id.size() == 18, "Catalog must contain all 18 enemies")

	var hand_children_before: int = game.hand_ctrl.get_child_count()
	var vfx_children_before: int = game.vfx_ctrl.get_child_count()
	var arena_children_before: int = game.arena_ctrl.get_child_count()

	for c_idx: int in range(game.repo.all_cards.size()):
		var cdata: Dictionary = game.repo.all_cards[c_idx]
		var cid: String = str(cdata.get("id", ""))
		eng._setup_combat_encounter({
			"stage": 2,
			"title": "Card Test",
			"type": "combat",
			"enemies": [
				{"enemy_id": "colosso_frizione", "lane_x": -1.0, "distance_z": -5.8},
				{"enemy_id": "scavenger_buggy", "lane_x": 1.0, "distance_z": -5.8}
			]
		})
		eng.hp = 70
		eng.max_hp = 70
		eng.block = 12
		eng.enemies[0]["hp"] = 500
		eng.enemies[0]["max_hp"] = 500
		eng.enemies[1]["hp"] = 500
		eng.enemies[1]["max_hp"] = 500

		var allowed: Array = cdata.get("allowed_gears", [1]) as Array
		var test_gear: int = int(allowed[0]) if not allowed.is_empty() else 1
		eng.current_gear = test_gear
		var red_u: int = int(game.repo.get_gear(test_gear).get("redline_rpm_units", 8))
		eng.rpm_units = red_u if bool(cdata.get("requires_redline", false)) else 6
		eng.heat = 2 if bool(cdata.get("consume_all_heat", false)) else 1
		if cid == "impatto_cinetico":
			eng.shift_surge_active = true
			eng.turn_torque_bonus = 2

		eng.hand = [cid, "colpo_acceleratore", "marcia_ridotta"]
		var chk: Dictionary = eng.can_play_card(0, false)
		assert(bool(chk.get("playable", false)), "Card '%s' must be playable in gear %d" % [cid, test_gear])

		var prev_calc: Dictionary = eng.calculate_card_preview(cdata, false)
		var e0_hp_before: int = int(eng.enemies[0]["hp"])
		var played: bool = eng.play_card(0, 0)
		assert(played, "play_card must succeed for '%s'" % cid)
		if eng.mode == CombatEngine.MODE_SHIFT_CHOICE:
			var s_opts: Array = cdata.get("choose_shift_options", [1]) as Array
			assert(eng.resolve_pending_shift_choice(int(s_opts[0])), "Shift choice must resolve for '%s'" % cid)
		if cid == "impatto_cinetico":
			var dealt: int = e0_hp_before - int(eng.enemies[0]["hp"])
			assert(dealt == int(prev_calc.get("damage", -1)), "consume_all_rpm actual damage (%d) must match preview (%d)" % [dealt, int(prev_calc.get("damage", -1))])
		game.vfx_ctrl._process(0.08)
		game.vfx_ctrl._process(0.15)
		game.arena_ctrl._process(0.10)

	game.hand_ctrl._clear_all_card_nodes()
	assert(game.hand_ctrl.card_nodes.is_empty() and game.hand_ctrl.slot_pool.size() >= 10, "Pooled hand must deactivate slots without freeing pool")
	assert(game.hand_ctrl.get_child_count() == hand_children_before, "Hand3DController must do zero node allocations across 31 card plays")
	assert(game.vfx_ctrl.get_child_count() == vfx_children_before, "VehicleVfxController must do zero node allocations across 31 card plays")
	assert(game.arena_ctrl.get_child_count() == arena_children_before, "DungeonArena3D must do zero node allocations across 31 card plays")
	for pooled_parent: Node in [game.hand_ctrl, game.vfx_ctrl, game.arena_ctrl]:
		for ch_node: Node in pooled_parent.get_children():
			assert(not ch_node.is_queued_for_deletion(), "Zero nodes may be queued for deletion in pooled controllers")

	# 12. Deterministic Simulation of Engine Stall & Overheat (including Overdrive 4+)
	eng.overdrive_level = 0
	eng._setup_combat_encounter({
		"stage": 1,
		"title": "Stall & Overheat Test",
		"type": "combat",
		"enemies": [{"enemy_id": "drone_istruzione", "lane_x": 0.0, "distance_z": -5.6}]
	})
	eng.enemies[0]["hp"] = 200
	eng.current_gear = 5
	eng.rpm_units = 1
	eng.block = 20
	assert(eng.has_stall_risk(), "5th gear at 1,000 RPM must flag stall risk")
	eng.end_player_turn()
	assert(eng.block == 0 and eng.current_gear == 0 and eng.rpm_units == 0 and eng.pending_draw_penalty == 1, "Stall must wipe Shield, force Neutral, 0 RPM, and queue draw penalty")

	eng._start_player_turn()
	var hp_pre_oh: int = eng.hp
	eng.current_gear = 4
	eng.heat = eng.max_heat() - 1
	eng._add_heat(1)
	assert(eng.heat == 0 and eng.current_gear == 0 and eng.hp == hp_pre_oh - 15, "Overheat must deal 15 piercing HP, reset Heat to 0, and force Neutral")

	# Overdrive 4 tightening check
	eng.overdrive_level = 4
	assert(eng.max_heat() == 4, "Overdrive >= 3 must tighten max_heat threshold by -1")

	# 13. Deterministic Simulation of ALL 3 Core Bosses & Intent Mechanics
	eng.overdrive_level = 0
	eng.rng.seed = 20261112
	for boss_id: String in ["boss_compattatore", "boss_leviathan_turbo", "boss_fornace_idraulica"]:
		var b_tmpl: Dictionary = game.repo.get_enemy(boss_id)
		assert(not b_tmpl.is_empty() and bool(b_tmpl.get("is_boss", false)), "Boss '%s' must exist" % boss_id)
		eng._setup_combat_encounter({
			"stage": 7,
			"title": "Boss Trial: " + boss_id,
			"type": "combat",
			"is_boss": true,
			"enemies": [{"enemy_id": boss_id, "lane_x": 0.0, "distance_z": -6.8}]
		})
		assert(eng.enemies.size() == 1, "Boss must spawn")
		var pattern: Array = b_tmpl.get("pattern", []) as Array
		assert(pattern.size() >= 3, "Boss '%s' must have at least 3 pattern steps" % boss_id)

		for step_i: int in range(pattern.size()):
			eng.hp = 70
			eng.max_hp = 70
			eng.block = 10
			eng.current_gear = 4
			eng.rpm_units = 5
			eng.heat = 0
			var boss_ref: Dictionary = eng.enemies[0]
			boss_ref["intent_index"] = step_i
			eng._refresh_boss_passive_states()
			var intent: Dictionary = eng.get_enemy_intent(boss_ref)
			if bool(intent.get("reflect_high_gear", false)):
				var hp_before_ref: int = eng.hp
				eng.block = 0
				eng._deal_damage_to_enemy(0, 10)
				assert(eng.hp < hp_before_ref, "Boss '%s' boss_wall must reflect damage above max_safe_gear" % boss_id)
			if str(intent.get("type", "")) == "boss_crush":
				eng.current_gear = 1
				var r_low: Vector2i = eng.effective_enemy_damage_range(boss_ref, intent)
				eng.current_gear = 5
				var r_high: Vector2i = eng.effective_enemy_damage_range(boss_ref, intent)
				assert(r_high.x < r_low.x, "boss_crush damage must scale down in higher gears")
			eng._resolve_single_enemy_intent(boss_ref, intent, 0)
			assert(eng.hp > 0, "Player must survive single controlled boss step for '%s'" % boss_id)

	# 14. Tailored Chassis Starter Decks check
	eng.start_new_run("interceptor", 0)
	var deck_int: Array[String] = eng.master_deck.duplicate()
	assert(deck_int.size() == 9 and deck_int.has("burnout"), "Interceptor V8 must load its 9-card Burnout/Volley starter deck")

	eng.start_new_run("bulldozer", 0)
	var deck_doz: Array[String] = eng.master_deck.duplicate()
	assert(deck_doz.size() == 9 and deck_doz.has("ariete_idraulico") and deck_doz.has("schianto_frontale") and deck_doz.has("corazza_reattiva"), "Bulldozer must load its 9-card Shield-Slam starter deck")

	eng.start_new_run("turbo_proto", 0)
	var deck_prt: Array[String] = eng.master_deck.duplicate()
	assert(deck_prt.size() == 9 and deck_prt.has("slalom_meccanico") and deck_prt.has("tacco_punta") and deck_prt.has("freno_motore"), "Sequential Prototype must load its 9-card Multi-Shift starter deck")
	var g4_ready_count: int = 0
	for p_cid: String in deck_prt:
		if (game.repo.get_card(p_cid).get("allowed_gears", []) as Array).has(4):
			g4_ready_count += 1
	assert(g4_ready_count >= 6, "Sequential Prototype starter deck must support 4th gear seamlessly (got %d/9)" % g4_ready_count)
	assert(deck_int != deck_doz and deck_doz != deck_prt, "All 3 chassis decks must be distinct")

	# 15. Interactive 7-Callout Cockpit Popup Tour on Normal Run + [H] & [I] Shortcuts
	var i_ev: InputEventKey = InputEventKey.new()
	i_ev.keycode = KEY_I
	i_ev.pressed = true
	game._unhandled_input(i_ev)
	assert(game.terminal_ctrl.is_active() and game.terminal_ctrl.screen_mode == "deck_preview", "Browser-safe [I] must open deck preview")
	game._unhandled_input(i_ev)
	assert(not game.terminal_ctrl.is_active(), "Second [I] must fold deck preview")

	game._on_title_action("run:bulldozer:0:tour")
	assert(eng.mode == CombatEngine.MODE_COMBAT and not eng.tutorial_active and eng.run_map_nodes.size() > 1, "Guided tour must run inside a real 11-tier normal run")
	assert(game.tutorial_ctrl.is_active() and game.tutorial_ctrl.steps.size() == 7, "Cockpit Tour must have 7 instrument callouts")
	var expected_keys: Array[String] = ["cards", "shifter", "gauges", "enemies", "overhead", "screens", "slam"]
	var space_ev: InputEventKey = InputEventKey.new()
	space_ev.keycode = KEY_SPACE
	space_ev.pressed = true
	var turn_before_tour: int = eng.turn_number
	for k_i: int in range(expected_keys.size()):
		assert(game.tutorial_ctrl.current_step_key() == expected_keys[k_i], "Tour step %d must highlight '%s'" % [k_i, expected_keys[k_i]])
		assert(game.hud.tour_panel.visible, "Tour popup panel must be visible on step %d" % k_i)
		game._process(0.016)
		game._unhandled_input(space_ev)
	assert(not game.tutorial_ctrl.is_active() and not game.hud.tour_panel.visible, "Final [SPACE] on step 7 must close Cockpit Tour")
	assert(eng.turn_number == turn_before_tour, "[SPACE] during Cockpit Tour must advance popups without ending Turn 1")

	var h_ev: InputEventKey = InputEventKey.new()
	h_ev.keycode = KEY_H
	h_ev.pressed = true
	game._unhandled_input(h_ev)
	assert(game.tutorial_ctrl.is_active() and game.hud.tour_panel.visible, "[H] in combat must reopen Cockpit Tour anytime")
	var t_ev: InputEventKey = InputEventKey.new()
	t_ev.keycode = KEY_T
	t_ev.pressed = true
	game._unhandled_input(t_ev)
	assert(not game.tutorial_ctrl.is_active() and eng.mode == CombatEngine.MODE_COMBAT, "[T] must dismiss Cockpit Tour while staying in the normal run")

	# 16. New Environmental & Mechanical Audio Synthesis check
	game.audio_ctrl.set_engine_muted(false)
	game.audio_ctrl.set_master_volume(1.0)
	game.audio_ctrl.set_sfx_bus_volume(1.0)
	game.audio_ctrl.set_environment_context("combat", 20.5, 2)
	assert(game.audio_ctrl.active_threat_tier == 2 and absf(game.audio_ctrl.target_speed_mps - 20.5) < 0.01, "Environment audio context must track speed and threat tier")
	for sfx_name: String in ["rev_match", "clutch_kick", "turbo_blowoff", "coolant_vent", "gun_burst", "steam_hiss", "weld_arc", "forge_anvil", "air_brake", "tire_screech", "hydraulic_servo"]:
		game.audio_ctrl.sfx_queue.clear()
		game.audio_ctrl.trigger_sfx(sfx_name, 0.9)
		assert(game.audio_ctrl.sfx_queue.size() == 1, "SFX '%s' must enqueue" % sfx_name)
		var kind_id: String = str(game.audio_ctrl.sfx_queue[0].get("type", ""))
		var s_val: float = game.audio_ctrl._sample_sfx(kind_id, 0.02, 0.25)
		assert(not is_nan(s_val) and not is_inf(s_val), "SFX '%s' sample must be valid float" % sfx_name)

	eng._setup_combat_encounter({
		"stage": 3,
		"title": "New Enemies & Relics Trial",
		"type": "combat",
		"enemies": [
			{"enemy_id": "ariete_trivella", "lane_x": -1.2, "distance_z": -5.9},
			{"enemy_id": "drone_crio_lama", "lane_x": 0.0, "distance_z": -6.0},
			{"enemy_id": "torretta_emp", "lane_x": 1.2, "distance_z": -6.1}
		]
	})
	assert(eng.enemies.size() == 3, "All 3 new enemy archetypes must spawn")
	for new_eid: String in ["ariete_trivella", "drone_crio_lama", "torretta_emp"]:
		var m_path: String = str(game.repo.get_enemy(new_eid).get("model_path", ""))
		assert(ResourceLoader.exists(m_path), "3D model must exist for '%s' at %s" % [new_eid, m_path])
	eng.owned_relics = ["differenziale_autobloccante", "rigenerazione_frenata", "collettore_titanio", "recupero_rottami"]
	eng.current_gear = 4
	eng.rpm_units = 2
	eng.block = 0
	eng.free_shift_available = true
	assert(eng.request_manual_shift(3), "Manual downshift must succeed")
	assert(eng.block >= 4 and eng.rpm_units >= 3, "Limited-Slip Diff (+4 Shield) & KERS (+1K RPM on downshift) must trigger")
	eng.current_gear = 1
	eng.rpm_units = 5
	var red_prev: Dictionary = eng.calculate_card_preview(game.repo.get_card("colpo_acceleratore"), false)
	eng.owned_relics.clear()
	var base_prev: Dictionary = eng.calculate_card_preview(game.repo.get_card("colpo_acceleratore"), false)
	assert(int(red_prev.get("damage", 0)) == int(base_prev.get("damage", 0)) + 5, "Titanium Manifold must add +5 Redline attack damage")

	eng.current_gear = 1
	eng.rpm_units = 2
	eng.heat = 0
	var cold_prev: int = int(eng.calculate_card_preview(game.repo.get_card("colpo_acceleratore"), false).get("damage", 0))
	eng.heat = 2
	var hot_prev: int = int(eng.calculate_card_preview(game.repo.get_card("colpo_acceleratore"), false).get("damage", 0))
	assert(hot_prev == cold_prev + 2, "Hot Engine (Heat >= 2) must grant +2 attack damage")
	eng.heat = 0
	eng.rpm_units = 4
	var red_boost_prev: int = int(eng.calculate_card_preview(game.repo.get_card("colpo_acceleratore"), false).get("damage", 0))
	assert(red_boost_prev == cold_prev + 4, "Redline Overboost must grant +4 universal attack damage")

	eng.current_gear = 2
	eng.rpm_units = 3
	eng.heat = 0
	eng.turns_in_same_gear = 1
	eng.shifts_this_turn = 0
	eng.end_player_turn()
	assert(eng.heat == 1, "Staying in the same non-Neutral gear for 2 turns without shifting must trigger +1 Lugging Heat")

	# Restore user files cleanly
	if had_profile:
		var wf: FileAccess = FileAccess.open(profile_path, FileAccess.WRITE)
		if wf != null:
			wf.store_buffer(backup_profile)
			wf.close()
	else:
		if FileAccess.file_exists(profile_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(profile_path))

	if had_save:
		var sf: FileAccess = FileAccess.open(save_path, FileAccess.WRITE)
		if sf != null:
			sf.store_buffer(backup_save)
			sf.close()
	else:
		if FileAccess.file_exists(save_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))

	print("JAM_READINESS_CHECK_PASSED (ALL 31 CARDS + 3 CHASSIS DECKS + 6-STEP TUTORIAL + ENV AUDIO + BOSSES)")
	game.queue_free()
	return false
