#!/usr/bin/env python3
"""Machine-local settings: the join password and the scrims lobby id.

Neither is profile data. The password is a TripwireServer.ini identity key
that survives profile switches, and the lobby id lives in the gitignored
.env - profiles are tracked, so a test here guards against either leaking
into one.
"""
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import dimod
from profile_schema import FIELDS, MACHINE_FIELDS, MachineDraft, ProfileDraft

EXAMPLE_ENV = """\
# Comments and unrelated settings must survive an edit.
SCRIMS_API_KEY=sk_live_do_not_touch

SCRIMS_BASE_URL=https://example.convex.site
SCRIMS_LOBBY_ID=lobby_old
"""


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.sandbox, True)
        self.env = os.path.join(self.sandbox, ".env")
        previous = dimod.ENV
        dimod.ENV = self.env
        self.addCleanup(setattr, dimod, "ENV", previous)

    def _write(self, text):
        with open(self.env, "w", encoding="utf-8") as handle:
            handle.write(text)

    def test_editing_one_key_leaves_the_rest_byte_identical(self):
        self._write(EXAMPLE_ENV)
        dimod.write_env("SCRIMS_LOBBY_ID", "lobby_new")
        after = open(self.env, encoding="utf-8").read()
        self.assertEqual(EXAMPLE_ENV.replace("lobby_old", "lobby_new"), after)
        self.assertEqual("lobby_new", dimod.read_env("SCRIMS_LOBBY_ID"))
        self.assertIn("sk_live_do_not_touch", after, "the API key was disturbed")

    def test_a_missing_key_is_appended_and_a_missing_file_is_created(self):
        self._write("SCRIMS_API_KEY=k\n")
        dimod.write_env("SCRIMS_LOBBY_ID", "lobby_1")
        self.assertEqual("lobby_1", dimod.read_env("SCRIMS_LOBBY_ID"))
        self.assertEqual("k", dimod.read_env("SCRIMS_API_KEY"))

        os.remove(self.env)
        dimod.write_env("SCRIMS_LOBBY_ID", "lobby_2")
        self.assertEqual("lobby_2", dimod.read_env("SCRIMS_LOBBY_ID"))

    def test_quotes_are_stripped_and_comments_ignored(self):
        self._write('#SCRIMS_LOBBY_ID=commented_out\nSCRIMS_LOBBY_ID="quoted"\n')
        self.assertEqual("quoted", dimod.read_env("SCRIMS_LOBBY_ID"))
        dimod.write_env("SCRIMS_LOBBY_ID", "plain")
        body = open(self.env, encoding="utf-8").read()
        self.assertIn("#SCRIMS_LOBBY_ID=commented_out", body,
                      "a commented line must not be treated as the setting")
        self.assertEqual("plain", dimod.read_env("SCRIMS_LOBBY_ID"))

    def test_a_line_break_is_refused_rather_than_corrupting_the_file(self):
        self._write(EXAMPLE_ENV)
        with self.assertRaises(ValueError):
            dimod.write_env("SCRIMS_LOBBY_ID", "a\nSCRIMS_API_KEY=stolen")
        self.assertEqual(EXAMPLE_ENV, open(self.env, encoding="utf-8").read())

    def test_missing_settings_are_reported_by_name_only(self):
        self.assertEqual((False, ["SCRIMS_API_KEY", "SCRIMS_BASE_URL",
                                  "SCRIMS_LOBBY_ID"]), dimod.scrims_env_state())
        self._write("SCRIMS_API_KEY=k\nSCRIMS_BASE_URL=\n")
        present, missing = dimod.scrims_env_state()
        self.assertTrue(present)
        self.assertEqual(["SCRIMS_BASE_URL", "SCRIMS_LOBBY_ID"], missing)


class PasswordTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.sandbox, True)
        self.ini = os.path.join(self.sandbox, "tw.ini")
        with open(self.ini, "w", encoding="utf-8") as handle:
            handle.write("[/Script/DeceiveInc.TripwireServerSettings]\n"
                         "ServerName=Mine\nGameMode=Trio\n")
        previous = dimod.TRIPWIRE
        dimod.TRIPWIRE = self.ini
        self.addCleanup(setattr, dimod, "TRIPWIRE", previous)

    def test_setting_and_clearing_the_password(self):
        self.assertEqual("", dimod.server_password())
        dimod.set_server_password("  hunter2  ")
        self.assertEqual("hunter2", dimod.server_password())
        self.assertEqual("Mine", dimod.read_ini_values(self.ini)["ServerName"])

        dimod.set_server_password("")
        self.assertEqual("", dimod.server_password())
        self.assertNotIn("Password", dimod.read_ini_values(self.ini))

    def test_the_password_is_not_a_profile_owned_key(self):
        # If Password ever joins MANAGED_TRIPWIRE_KEYS, applying a profile
        # would reset it to baseline and silently drop it.
        self.assertNotIn("Password", dimod.MANAGED_TRIPWIRE_KEYS)


class MachineDraftTests(unittest.TestCase):
    def test_only_edited_fields_are_reported(self):
        draft = MachineDraft({"ini.Password": "old",
                              "env.SCRIMS_LOBBY_ID": "lobby_1"})
        self.assertFalse(draft.dirty())
        self.assertEqual({}, draft.changes())
        draft.set("ini.Password", "new")
        self.assertTrue(draft.dirty())
        self.assertEqual({"ini.Password": "new"}, draft.changes())

    def test_a_line_break_is_an_inline_error(self):
        draft = MachineDraft({"env.SCRIMS_LOBBY_ID": ""})
        draft.set("env.SCRIMS_LOBBY_ID", "a\nb")
        self.assertIn("env.SCRIMS_LOBBY_ID", draft.validation_errors())

    def test_machine_paths_can_never_reach_a_profile(self):
        paths = {field.path for field in MACHINE_FIELDS}
        self.assertFalse(paths & {field.path for field in FIELDS})
        profile = {"tripwire": {"ServerName": "Mine"}}
        draft = ProfileDraft(profile, FIELDS)
        for path in paths:
            self.assertNotIn(path, draft.values)
        collected, errors = draft.collect()
        self.assertEqual([], errors)
        self.assertEqual(profile, collected)
        self.assertNotIn("Password", collected.get("tripwire", {}))


if __name__ == "__main__":
    unittest.main()
