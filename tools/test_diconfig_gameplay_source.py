#!/usr/bin/env python3
"""Source contracts for DIConfig's server-wide gameplay overrides."""
import os
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_PATH = os.path.join(ROOT, "mods", "DIConfig", "Scripts", "main.lua")


class DIConfigGameplaySourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SOURCE_PATH, encoding="utf-8") as handle:
            cls.source = handle.read()

    def test_suspicion_controls_are_authoritative_and_verified(self):
        start = self.source.index("local function suppress_suspicion")
        stop = self.source.index("local function suppress_cover", start)
        suppression = self.source[start:stop]

        self.assertIn("pawn.SusEnableNPCCheck = false", suppression)
        self.assertIn("pawn.bIsSuspicious = false", suppression)
        self.assertIn("pawn.StaminaDrainRate = 0.0", suppression)
        self.assertIn("pawn.StaminaDrainRateMultiplier = 0.0", suppression)
        self.assertIn("pawn:ResetStaminaToMax()", suppression)
        self.assertIn("interacter.bCanTriggerBotSuspiciousness = false",
                      suppression)
        self.assertIn("after.stamina >= after.stamina_max", suppression)

    def test_cover_uses_only_crash_safe_scalar_state(self):
        start = self.source.index("local function suppress_cover")
        stop = self.source.index("local function apply_gameplay", start)
        suppression = self.source[start:stop]

        self.assertIn("pawn.bCheatDisableCover = true", suppression)
        self.assertIn("pawn.CoverRatio = 0.0", suppression)
        self.assertNotIn(":AllowCover(", suppression)
        self.assertNotIn(":IsUndercover(", suppression)
        self.assertIn("after.disabled == true", suppression)
        self.assertIn("after.ratio == 0", suppression)

    def test_gameplay_rules_run_for_all_active_match_spies(self):
        self.assertIn('FindAllOf("Spy")', self.source)
        self.assertIn("if not active_match() then return end", self.source)
        self.assertIn("LoopAsync(1000, function()", self.source)
        self.assertIn("pcall(apply_gameplay)", self.source)

    def test_settings_are_loaded_as_general_diconfig_values(self):
        self.assertIn("enabled(cfg.DisableSuspicion)", self.source)
        self.assertIn("enabled(cfg.DisableCover)", self.source)


if __name__ == "__main__":
    unittest.main()
