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


if __name__ == "__main__":
    unittest.main()
