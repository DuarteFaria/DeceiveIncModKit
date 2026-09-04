#!/usr/bin/env python3
"""Profile-model and window checks for dimod_gui."""
import json
import os
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import dimod
from profile_schema import FIELDS, ProfileDraft, mod_fields, unknown_paths


class ProfileDraftTests(unittest.TestCase):
    def test_remove_ambient_npcs_is_a_gameplay_rule(self):
        fields = {field.path: field for field in FIELDS}
        self.assertIn("diconfig.Gameplay.RemoveAmbientNPCs", fields)
        self.assertNotIn("diconfig.Extraction.RemoveAmbientNPCs", fields)
        rule = fields["diconfig.Gameplay.RemoveAmbientNPCs"]
        self.assertEqual("gameplay", rule.group)
        self.assertEqual("DIExtraction", rule.needs_mod)

    def test_profile_helpers_use_stable_json_and_reject_traversal(self):
        previous = dimod.PROFILES
        try:
            with tempfile.TemporaryDirectory() as folder:
                dimod.PROFILES = folder
                profile = {"description": "test", "mods": {"DIConfig": True}}
                path = dimod.save_profile("sample", profile)
                self.assertEqual(os.path.join(folder, "sample.json"), path)
                with open(path, encoding="utf-8") as handle:
                    self.assertEqual(json.dumps(profile, indent=2) + "\n", handle.read())
                with self.assertRaises(ValueError):
                    dimod.profile_path(os.path.join("..", "outside"))
        finally:
            dimod.PROFILES = previous

    def test_every_profile_round_trips_without_changes(self):
        fields = FIELDS + mod_fields(dimod.our_mods())
        for name, profile in dimod.profiles().items():
            with self.subTest(profile=name):
                draft = ProfileDraft(profile, fields)
                collected, errors = draft.collect()
                self.assertEqual([], errors)
                self.assertEqual(profile, collected)
                path = os.path.join(dimod.PROFILES, name + ".json")
                with open(path, encoding="utf-8") as handle:
                    original_text = handle.read()
                rendered = json.dumps(collected, indent=2) + "\n"
                self.assertEqual(original_text, rendered)
                self.assertFalse(draft.dirty())
                self.assertEqual([], unknown_paths(profile, fields))

    def test_tripwire_numbers_remain_strings(self):
        draft = ProfileDraft({"tripwire": {"MaxPlayers": "8"}}, FIELDS)
        draft.set("tripwire.MaxPlayers", "10")
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual("10", collected["tripwire"]["MaxPlayers"])

    def test_map_rotation_preserves_order_and_rejects_unknown_maps(self):
        draft = ProfileDraft({"tripwire": {}}, FIELDS)
        draft.set("tripwire.MapRotation", "SoundEclipse, Hardsell, Silverreef")
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual(
            ["SoundEclipse", "Hardsell", "Silverreef"],
            collected["tripwire"]["MapRotation"])

        draft.set("tripwire.MapRotation", "SoundEclipse, NotAMap")
        _collected, errors = draft.collect()
        self.assertTrue(any("NotAMap" in error for error in errors))

    def test_server_name_can_be_owned_or_left_to_the_live_ini(self):
        draft = ProfileDraft({"tripwire": {}}, FIELDS)
        draft.set("tripwire.ServerName", "Scrims Night")
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual("Scrims Night", collected["tripwire"]["ServerName"])

        draft = ProfileDraft(
            {"tripwire": {"ServerName": "Old Name"}}, FIELDS)
        draft.set("tripwire.ServerName", "")
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertNotIn("ServerName", collected["tripwire"])

    def test_live_server_name_is_displayed_without_owning_or_dirtying_it(self):
        profile = {"tripwire": {"MaxPlayers": "8"}}
        draft = ProfileDraft(
            profile, FIELDS,
            {"tripwire.ServerName": "Existing Server"})
        self.assertEqual("Existing Server", draft.values["tripwire.ServerName"])
        self.assertFalse(draft.dirty())
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual(profile, collected)

        draft.set("tripwire.ServerName", "Friday Scrims")
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual("Friday Scrims", collected["tripwire"]["ServerName"])

    def test_unknown_keys_are_preserved(self):
        profile = {"future": {"some_key": [1, 2, 3]}}
        collected, errors = ProfileDraft(profile, FIELDS).collect()
        self.assertEqual([], errors)
        self.assertEqual(profile, collected)
        self.assertEqual(["future.some_key"], unknown_paths(profile, FIELDS))

    def test_empty_unknown_group_is_reported(self):
        self.assertEqual(["future"], unknown_paths({"future": {}}, FIELDS))

    def test_mod_can_be_removed_without_writing_false(self):
        fields = FIELDS + mod_fields(("DIConfig",))
        draft = ProfileDraft({"mods": {"DIConfig": True}}, fields)
        draft.set("mods.DIConfig", False)
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual({}, collected["mods"])

    def test_cross_field_validation_is_inline_ready(self):
        profile = {"tripwire": {"MaxPlayers": "8", "BotsAmount": "7"}}
        draft = ProfileDraft(profile, FIELDS)
        draft.set("tripwire.BotsAmount", "8")
        _collected, errors = draft.collect()
        self.assertIn("Bots must be less than max players", errors)

    def test_existing_unknown_enum_is_valid_until_edited(self):
        profile = {"tripwire": {"GameMode": "LegacyMode"}}
        draft = ProfileDraft(profile, FIELDS)
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual(profile, collected)
        self.assertFalse(draft.dirty())

        draft.set("tripwire.GameMode", "AnotherLegacyMode")
        _collected, errors = draft.collect()
        self.assertTrue(errors)


class WindowTests(unittest.TestCase):
    """The one check the profile model cannot make: that the window builds.

    Every wiring mistake in the Tk layer - a button naming a method that no
    longer exists, a refresh that runs before the widget it touches - shows
    up here rather than only when somebody double-clicks Mod Kit.bat.
    """

    def test_window_builds_and_closes_in_dry_run(self):
        try:
            import tkinter as tk
            tk.Tk().destroy()
        except Exception as exc:                      # no display, or no Tk
            self.skipTest(f"Tk is unavailable: {exc}")

        import dimod_gui
        app = dimod_gui.App(dry_run=True)
        try:
            app.withdraw()                            # do not steal focus
            # Pumping until the startup doctor lands exercises the whole
            # worker-thread-to-queue-to-drain path, not just the layout.
            deadline = time.monotonic() + 15
            while app.busy and time.monotonic() < deadline:
                app.update()
                time.sleep(0.02)
            self.assertFalse(app.busy, "the startup doctor never finished")
            self.assertTrue(app.dry_run)
        finally:
            app.destroy()


if __name__ == "__main__":
    unittest.main()
