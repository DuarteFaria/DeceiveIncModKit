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
        self.assertIn("component:Deactivate()", cleanup)
        self.assertIn("ai:IsActorTickEnabled()", cleanup)
        self.assertIn("component:IsComponentTickEnabled()", cleanup)

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

if __name__ == "__main__":
    unittest.main()
