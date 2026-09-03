#!/usr/bin/env python3
"""How `apply` writes TripwireServer.ini, driven through the real cmd_apply.

The bug that prompted these: `tripwire_remove` runs after `tripwire`, so a
profile carrying both for the same key deleted the value it had just written.
The GUI's map editor made that reachable - vanilla set a MapRotation and the
server then played its default pool.
"""
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import dimod

SECTION = "[/Script/DeceiveInc.TripwireServerSettings]"
# Identity keys are not profile-owned, so every case below expects them intact.
LIVE_INI = SECTION + "\nServerName=Scrims Night\nGameMode=Trio\nMapRotation=Silverreef\n"
BASELINE_INI = SECTION + "\nGameMode=Solo\nbIsPublic=False\n"


class ApplyIniTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.sandbox, True)
        win64 = self._folder("Win64")
        paths = {
            "KIT_MODS": self._folder("kit-mods"),      # empty: our_mods() -> []
            "PROFILES": self._folder("profiles"),
            "BASELINE": self._folder("baseline"),
            "WIN64": win64,
            "GAME_MODS": os.path.join(win64, "Mods"),
            "MODS_TXT": os.path.join(win64, "Mods", "mods.txt"),
            "DICONFIG": os.path.join(win64, "DIConfig.ini"),
            "TRIPWIRE": os.path.join(win64, "TripwireServer.ini"),
            "STATE": os.path.join(self.sandbox, ".deployed.json"),
        }
        for name, value in paths.items():
            self._patch(name, value)
        self._write(dimod.TRIPWIRE, LIVE_INI)
        self._write(os.path.join(dimod.BASELINE, "TripwireServer.ini.original"),
                    BASELINE_INI)

    def _folder(self, name):
        path = os.path.join(self.sandbox, name)
        os.makedirs(path, exist_ok=True)
        return path

    def _patch(self, name, value):
        previous = getattr(dimod, name)
        setattr(dimod, name, value)
        self.addCleanup(setattr, dimod, name, previous)

    @staticmethod
    def _write(path, text):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _apply(self, profile):
        self._write(os.path.join(dimod.PROFILES, "t.json"), json.dumps(profile))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = dimod.cmd_apply("t")
        self.assertEqual(0, code, buffer.getvalue())
        return dimod.read_ini_values(dimod.TRIPWIRE), buffer.getvalue()

    def _rotation(self):
        return [line.split("=", 1)[1]
                for line in open(dimod.TRIPWIRE, encoding="utf-8-sig")
                .read().splitlines()
                if line.startswith("MapRotation=")]

    def test_setting_a_key_beats_removing_it(self):
        values, output = self._apply({
            "tripwire": {"MapRotation": ["FragrantShore_Night"]},
            "tripwire_remove": ["MapRotation"],
        })
        self.assertEqual("FragrantShore_Night", values.get("MapRotation"))
        self.assertIn("tripwire_remove ignores MapRotation", output)

    def test_remove_still_works_for_a_key_the_profile_does_not_set(self):
        values, _ = self._apply({"tripwire": {"MaxPlayers": "8"},
                                 "tripwire_remove": ["ServerName"]})
        self.assertNotIn("ServerName", values)
        self.assertEqual("8", values["MaxPlayers"])

    def test_a_managed_key_absent_from_baseline_needs_no_tripwire_remove(self):
        # Why vanilla's "tripwire_remove": ["MapRotation"] was redundant from
        # the start: the reset already drops what the baseline does not carry.
        values, _ = self._apply({"tripwire": {"bIsPublic": "True"}})
        self.assertNotIn("MapRotation", values)
        self.assertEqual("Solo", values["GameMode"], "baseline was not restored")
        self.assertEqual("Scrims Night", values["ServerName"], "identity was lost")

    def test_a_rotation_is_written_as_one_line_per_map(self):
        # Comma-separating them makes the server take the whole string as a
        # single entry and fall back to its default pool (proven 2026-09-02).
        maps = ["Hardsell", "Silverreef", "Diamondspire"]
        self._apply({"tripwire": {"MapRotation": maps, "bRandomizeMap": "False"}})
        self.assertEqual(maps, self._rotation())

    def test_a_shorter_rotation_leaves_no_stale_entries(self):
        self._apply({"tripwire": {"MapRotation": ["Hardsell", "Silverreef"]}})
        self._apply({"tripwire": {"MapRotation": ["SoundEclipse"]}})
        self.assertEqual(["SoundEclipse"], self._rotation())


if __name__ == "__main__":
    unittest.main()
