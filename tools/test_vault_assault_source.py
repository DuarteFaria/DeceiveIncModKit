#!/usr/bin/env python3
"""Source-level safety contracts for the UE4SS-only vault-assault code.

The game object model is only available inside the dedicated server, so these
checks protect the ordering of high-risk reflected calls without pretending to
mock Unreal objects in Python.
"""
import os
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_PATH = os.path.join(ROOT, "mods", "DIExtraction", "Scripts", "main.lua")


class VaultAssaultSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SOURCE_PATH, encoding="utf-8") as handle:
            cls.source = handle.read()

    def test_bot_branch_completes_without_calling_bulk_resource_grant(self):
        start = self.source.index("local function prepare_assault_spies")
        stop = self.source.index("local function set_phase_time", start)
        prepare = self.source[start:stop]

        bot_branch = prepare.index("if is_bot_spy(pawn) then")
        human_branch = prepare.index("elseif human_controller_of_spy(pawn)",
                                     bot_branch)
        bulk_grant = prepare.index("grant_full_resources_to_pawn(", human_branch)

        self.assertLess(bot_branch, human_branch)
        self.assertLess(human_branch, bulk_grant)
        self.assertIn("assault_loadout_prepared[key] = true",
                      prepare[bot_branch:human_branch])
        self.assertNotIn("grant_full_resources_to_pawn(",
                         prepare[bot_branch:human_branch])

    def test_bot_detection_uses_both_stock_flags(self):
        start = self.source.index("local function is_bot_spy")
        stop = self.source.index("local function human_controller_of_spy", start)
        detector = self.source[start:stop]
        self.assertIn("pawn.bIsBot", detector)
        self.assertIn("state.bIsABot", detector)

    def test_attackers_use_one_cached_live_vault_door_per_match(self):
        start = self.source.index("local function choose_attacker_spawn")
        stop = self.source.index(
            "local function teleport_attacker_to_vault_entrance", start)
        chooser = self.source[start:stop]
        self.assertIn('FindAllOf("BP_VaultDoorBase_C")', chooser)
        self.assertIn("if assault_attacker_spawn ~= nil", chooser)
        self.assertIn("assault_attacker_spawn = selected", chooser)
        self.assertGreaterEqual(self.source.count("assault_attacker_spawn = nil"),
                                2)

    def test_attacker_spawn_is_outside_the_selected_door(self):
        start = self.source.index(
            "local function teleport_attacker_to_vault_entrance")
        stop = self.source.index(
            "-- Query the live pickup source", start)
        teleport = self.source[start:stop]
        self.assertIn("spawn.outward_x * distance", teleport)
        self.assertIn("spawn.outward_y * distance", teleport)
        self.assertIn("K2_TeleportTo", teleport)

        prepare_start = self.source.index("local function prepare_assault_spies")
        prepare_stop = self.source.index("local function set_phase_time",
                                         prepare_start)
        prepare = self.source[prepare_start:prepare_stop]
        self.assertIn("faction == assault_attacker_faction and not staged",
                      prepare)
        self.assertIn("teleport_attacker_to_vault_entrance(pawn, slot)",
                      prepare)

    def test_ambient_cleanup_stops_the_real_npc_ai_stack(self):
        start = self.source.index("local function stop_npc_component")
        stop = self.source.index("local function reset_vault_assault_state",
                                 start)
        cleanup = self.source[start:stop]

        self.assertIn("npc.NPCAI", cleanup)
        self.assertIn("ai.BehaviorMachine", cleanup)
        self.assertIn("ai.AdditionalComponents", cleanup)
        self.assertIn("ai:SetActorTickEnabled(false)", cleanup)
        self.assertIn("component:SetComponentTickEnabled(false)", cleanup)
        self.assertNotIn("component:Deactivate()", cleanup)
        self.assertIn("ai:IsActorTickEnabled()", cleanup)
        self.assertIn("component:IsComponentTickEnabled()", cleanup)

    def test_ambient_spawn_source_and_guard_weapons_are_neutralized(self):
        start = self.source.index("local function neutralize_npc_guard_component")
        stop = self.source.index("local function reset_vault_assault_state", start)
        cleanup = self.source[start:stop]
        self.assertIn(
            'FindAllOf("DIPopulationManagerNpcSpawnDataAsset")', cleanup)
        self.assertIn("asset.SpawnNPCLevelData.SpawnCount = 0", cleanup)
        self.assertIn("manager.SpawnNPCLevelData.SpawnCount = 0", cleanup)
        self.assertIn("instance.SpawnNPCLevelData.SpawnCount = 0", cleanup)
        self.assertIn("weapon.Damage = 0.0", cleanup)
        self.assertIn("weapon.CriticalDamage = 0.0", cleanup)
        self.assertIn("weapon.LimbDamage = 0.0", cleanup)
        self.assertIn("component.EncounterMeleeDamage = 0.0", cleanup)
        self.assertIn("weapon:PrimaryEnd()", cleanup)

        config = self.source.index("pcall(load_config)")
        early_override = self.source.index(
            "disable_ambient_npc_spawn_assets()", config)
        self.assertGreater(early_override, config)

    def test_ambient_cleanup_keeps_population_actors_registered(self):
        start = self.source.index("local function stop_npc_component")
        stop = self.source.index("local function reset_vault_assault_state",
                                 start)
        cleanup = self.source[start:stop]

        self.assertIn('FindAllOf("PopulationManager")', cleanup)
        self.assertIn("manager.AllNPCs", cleanup)
        self.assertNotIn(":K2_DestroyActor(", cleanup)
        self.assertNotIn(":DestroyActor(", cleanup)
        self.assertNotIn(":UnPossess(", cleanup)

    def test_failed_ai_shutdown_is_not_hidden(self):
        start = self.source.index("local function remove_ambient_npcs_tick")
        stop = self.source.index("local function reset_vault_assault_state",
                                 start)
        cleanup = self.source[start:stop]
        ai_gate = cleanup.index("if ai_ok then")
        hide = cleanup.index("npc:SetActorHiddenInGame(true)")
        self.assertLess(ai_gate, hide)

    def test_npc_cleanup_is_batched_off_the_round_flow(self):
        self.assertIn("local AMBIENT_NPC_CLEANUP_BATCH = 2", self.source)
        self.assertIn(
            "if attempted >= AMBIENT_NPC_CLEANUP_BATCH then break end",
            self.source)
        self.assertIn("assault_npc_cleanup_cursor", self.source)
        self.assertIn("assault_npc_cleanup_cursor = last_index + 1",
                      self.source)
        tick_start = self.source.index("vault_assault_tick = function()")
        tick_stop = self.source.index("local function consume_trigger", tick_start)
        self.assertNotIn("remove_ambient_npcs_tick()",
                         self.source[tick_start:tick_stop])
        config = self.source.index("pcall(load_config)")
        self.assertIn("LoopAsync(100, function()", self.source[config:])

    def test_npc_removal_is_a_server_wide_gameplay_rule(self):
        self.assertIn("gameplay_settings.removeambientnpcs", self.source)
        self.assertIn("ambient_setting = settings.removeambientnpcs", self.source)
        config = self.source.index("pcall(load_config)")
        background = self.source[config:]
        self.assertIn("if remove_ambient_npcs then", background)
        self.assertNotIn(
            'extraction_mode == "vault_assault" and remove_ambient_npcs',
            background)
        start_play = self.source.index(
            'RegisterHook("/Script/Engine.GameModeBase:StartPlay"')
        load_config = self.source.index("local function load_config", start_play)
        reset = self.source[start_play:load_config]
        self.assertIn("if armed or remove_ambient_npcs then", reset)

    def test_npc_combat_is_disabled_before_batched_cleanup(self):
        self.assertIn('FindAllOf("EncounterManager")', self.source)
        self.assertIn('FindAllOf("EncounterDataAsset")', self.source)
        self.assertIn("game_state.EncounterManager", self.source)
        self.assertIn("data.bAllowShooting = false", self.source)
        self.assertIn("data.bAllowMelee = false", self.source)
        self.assertIn("heat[j].bAllowShooting = false", self.source)
        self.assertIn("heat[j].bAllowMelee = false", self.source)
        self.assertIn("component.CurrentInvestigationType = 0", self.source)
        self.assertIn("component.CurrentInvestigationState = 5", self.source)
        loop = self.source.index("LoopAsync(100, function()")
        disable = self.source.index("pcall(disable_ambient_npc_combat)", loop)
        cleanup = self.source.index("pcall(remove_ambient_npcs_tick)", loop)
        self.assertLess(disable, cleanup)

    def test_players_are_prepared_before_vault_phase_advance(self):
        start = self.source.index("vault_assault_tick = function()")
        stop = self.source.index("if phase >= PHASE_BY_NAME.RESULT_SCREEN", start)
        locked = self.source[start:stop]
        prepare = locked.index("prepare_assault_spies(spies, pickup_source)")
        advance = locked.index("game_state:AdvancePhase(true)")
        self.assertLess(prepare, advance)

if __name__ == "__main__":
    unittest.main()
