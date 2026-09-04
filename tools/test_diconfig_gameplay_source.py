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
        self.assertIn("pawn.bNoStamTickOutOfCover = true", suppression)
        self.assertIn("pawn.bSusOnlyDrainUndercover = true", suppression)
        self.assertIn("pawn:ResetStaminaToMax()", suppression)
        self.assertIn("interacter.bCanTriggerBotSuspiciousness = false",
                      suppression)
        self.assertIn("after.stamina >= after.stamina_max", suppression)

    def test_cover_uses_crash_safe_replicated_state(self):
        start = self.source.index("local function suppress_cover")
        stop = self.source.index("local function apply_gameplay", start)
        suppression = self.source[start:stop]

        self.assertIn("pawn.bCheatDisableCover = true", suppression)
        self.assertIn("pawn.CoverRatio = 0.0", suppression)
        self.assertIn(
            "pawn.UndercoverReplicationData.bShouldBeUndercover = false",
            suppression)
        self.assertIn("pawn.UndercoverReplicationData.Flags = 0", suppression)
        self.assertNotIn(":AllowCover(", suppression)
        self.assertNotIn(":IsUndercover(", suppression)
        self.assertIn("after.disabled == true", suppression)
        self.assertIn("after.ratio == 0", suppression)

    def test_heat_is_prevented_at_sources_and_cleared(self):
        start = self.source.index("local function suppress_heat")
        stop = self.source.index("local function suppress_cover_regeneration",
                                 start)
        suppression = self.source[start:stop]
        self.assertIn("pawn:DecrementHeat(before.count)", suppression)
        self.assertIn("pawn.HeatState.HeatLevel = 0", suppression)
        self.assertIn("pawn.HeatState.HeatCount = 0", suppression)
        self.assertIn("pawn.HeatSetup.NPCDamageHeatPerPool", suppression)
        self.assertIn("pawn.HeatSetup.ScoldHeatPerSeccond = 0.0", suppression)
        self.assertIn("npc_damage[i] = 0", suppression)
        self.assertIn("sources_zero", suppression)

    def test_cover_regeneration_is_stalled_without_removing_cover(self):
        start = self.source.index("local function suppress_cover_regeneration")
        stop = self.source.index("local function suppress_suspicion", start)
        suppression = self.source[start:stop]
        for field in (
                "TimeBeforeStartingRecover", "TimeToRecoverIdling",
                "TimeToRecoverWalking", "TimeToRecoverRunning",
                "TimeToRecoverInCoverIdling", "TimeToRecoverInCoverWalking",
                "TimeToRecoverInCoverRunning"):
            self.assertIn(f'"{field}"', suppression)
        self.assertNotIn("CoverRatio = 0", suppression)
        self.assertNotIn("bCheatDisableCover", suppression)

    def test_disabled_cover_removes_only_stock_combat_protection(self):
        start = self.source.index("local function remove_combat_spawn_protection")
        stop = self.source.index("local function suppress_cover", start)
        cleanup = self.source[start:stop]
        self.assertIn("health.bIgnoreDamage = false", cleanup)
        self.assertIn("game_state.InvulnerabilityInstance", cleanup)
        self.assertIn("ShieldDisguiseDamageModifierInstance", cleanup)
        self.assertIn("ShieldDamageModifierInstance", cleanup)
        self.assertIn("health:RemoveDamageModifier", cleanup)

    def test_gameplay_rules_run_for_all_active_match_spies(self):
        self.assertIn('FindAllOf("Spy")', self.source)
        self.assertIn("local is_active, game_state = active_match()", self.source)
        self.assertIn("if not is_active then return end", self.source)
        self.assertIn("LoopAsync(100, function()", self.source)
        self.assertIn("pcall(apply_gameplay)", self.source)

    def test_damage_modifier_cleanup_is_rate_limited(self):
        self.assertIn("gameplay_last_combat_cleanup", self.source)
        self.assertIn("run_modifier_cleanup", self.source)
        self.assertIn("gameplay_last_combat_cleanup[key] = now", self.source)

    def test_settings_are_loaded_as_general_diconfig_values(self):
        self.assertIn("enabled(cfg.DisableSuspicion)", self.source)
        self.assertIn("enabled(cfg.DisableCover)", self.source)
        self.assertIn("enabled(cfg.DisableHeat)", self.source)
        self.assertIn("enabled(cfg.DisableCoverRegeneration)", self.source)
        self.assertIn('out:write("RemoveAmbientNPCs = 0\\n")', self.source)
        self.assertIn('tostring(cfg.RemoveAmbientNPCs)', self.source)


if __name__ == "__main__":
    unittest.main()
