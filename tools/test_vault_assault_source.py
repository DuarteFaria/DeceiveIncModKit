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

    def test_suspicion_setting_uses_verified_flags_not_global_toggle(self):
        start = self.source.index("local function suppress_suspicion_for_spy")
        stop = self.source.index("local function find_live_player_states", start)
        suppression = self.source[start:stop]

        self.assertIn("pawn.SusEnableNPCCheck = false", suppression)
        self.assertIn("pawn.bIsSuspicious = false", suppression)
        self.assertIn("pawn.StaminaDrainRate = 0.0", suppression)
        self.assertIn("pawn.StaminaDrainRateMultiplier = 0.0", suppression)
        self.assertIn("pawn:ResetStaminaToMax()", suppression)
        self.assertIn("interacter.bCanTriggerBotSuspiciousness = false",
                      suppression)
        self.assertIn("after.npc_check ~= false", suppression)
        self.assertIn("after.suspicious ~= false", suppression)
        self.assertIn("after.drain_multiplier ~= 0", suppression)
        self.assertIn("after.can_trigger ~= false", suppression)
        self.assertNotIn("CheatToggleSpySuspiciousSystem", self.source)

    def test_suspicion_is_maintained_on_existing_tick(self):
        start = self.source.index("vault_assault_tick = function()")
        stop = self.source.index("local carrier", start)
        tick = self.source[start:stop]

        self.assertIn("local spies = find_live_spies()", tick)
        self.assertIn("suppress_assault_suspicion(spies)", tick)
        self.assertLess(tick.index("local spies = find_live_spies()"),
                        tick.index("suppress_assault_suspicion(spies)"))

    def test_suspicion_setting_is_loaded_from_config(self):
        self.assertIn("settings.disablesuspicion", self.source)
        self.assertIn("disable_suspicion = value == \"1\"", self.source)


if __name__ == "__main__":
    unittest.main()
