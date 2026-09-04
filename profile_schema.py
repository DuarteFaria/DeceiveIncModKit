"""Profile field metadata and lossless draft handling for ``dimod_gui``.

This module deliberately contains no Tk code, so the claim that opening and
collecting every real profile is lossless can be tested without a display,
and the GUI stays only a renderer for profile data.
"""
from copy import deepcopy
from dataclasses import dataclass
from typing import Optional


MISSING = object()


@dataclass(frozen=True)
class Field:
    path: str
    label: str
    kind: str = "str"
    group: str = "profile"
    minimum: Optional[int] = None
    maximum: Optional[int] = None
    choices: tuple[str, ...] = ()
    as_str: bool = False
    help: str = ""
    needs_mod: str | None = None
    advanced: bool = False
    remove_when_false: bool = False


FIELDS = (
    Field("description", "Description", "text", "profile"),
    Field("diconfig.Timing.LobbyWaitTime", "Lobby wait (s)", "int", "timing",
          1, 600, help="Default: 90", needs_mod="DIConfig"),
    Field("diconfig.Timing.IntroPhaseTime", "Intro phase (s)", "int", "timing",
          1, 600, help="Default: 19", needs_mod="DIConfig"),
    Field("diconfig.Extraction.Mode", "Behavior", "enum", "extraction",
          choices=("", "carrier_extraction", "vault_assault"),
          help="Choose the original carrier mode or 3v3 vault assault",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.AutoArm", "Auto-arm at match start", "bool01",
          "extraction", needs_mod="DIExtraction"),
    Field("diconfig.Extraction.AutoLoadout", "Auto-loadout mode players",
          "bool01", "extraction", needs_mod="DIExtraction"),
    Field("diconfig.Extraction.AssaultTime", "Assault time (s)", "int",
          "extraction", 10, 3600, help="Vault assault only; default: 120",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.SecuredTime", "Time after pickup (s)", "int",
          "extraction", 10, 3600, help="Vault assault only; default: 60",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.DefenderFaction", "Defender faction id", "int",
          "extraction", 0, 199, help="Vault assault only; first Trio team is 0",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.AttackerFaction", "Attacker faction id", "int",
          "extraction", 0, 199, help="Vault assault only; second Trio team is 1",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.TeleportDefenders", "Stage defenders at vault",
          "bool01", "extraction", needs_mod="DIExtraction"),
    Field("diconfig.Extraction.RemoveAmbientNPCs", "Remove ambient NPCs",
          "bool01", "extraction",
          help="Keeps player bots; removes wandering map NPCs",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.DisableSuspicion", "Disable suspicion",
          "bool01", "extraction",
          help="Vault assault only; keeps agents from becoming suspicious",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.Disguise", "Disguise", "enum", "extraction",
          choices=("", "green", "blue", "purple", "orange", "civilian",
                   "staff", "guard", "technician", "vip"),
          help="purple = technician",
          needs_mod="DIExtraction"),
    Field("diconfig.Extraction.Carrier", "Carrier (name substring)", "str",
          "extraction", help="Blank chooses automatically",
          needs_mod="DIExtraction"),
    Field("diconfig.Spectator.MaxSpectators", "Max spectators", "int",
          "spectator", 0, 16, needs_mod="DINativeStage2"),
    Field("scrims_watch", "Push scores to the scrims site", "bool", "scoring",
          help="Starts the watcher on launch", needs_mod="DIScore"),
    Field("tripwire.ServerName", "Server name", "str", "server"),
    Field("tripwire.GameMode", "Game mode", "enum", "server",
          choices=("Solo", "Duo", "Trio")),
    Field("tripwire.MaxPlayers", "Max players", "int", "server", 1, 12,
          as_str=True),
    Field("tripwire.BotsAmount", "Bots", "int", "server", 0, 11,
          as_str=True, help="Must be less than max players"),
    Field("tripwire.BotsDifficulty", "Bots difficulty", "enum", "server",
          choices=("", "Easy", "Normal", "Difficult")),
    Field("tripwire.bFillWithBots", "Fill with bots", "boolTF", "server"),
    Field("tripwire.bSandboxMode", "Sandbox mode", "boolTF", "server",
          help="Unlock all"),
    Field("tripwire.bIsPublic", "Public", "boolTF", "server"),
    Field("tripwire.bEnableUPnP", "UPnP port mapping", "boolTF", "server"),
    Field("tripwire.AutoShutdownEmptyMinutes", "Shut down after empty (min)",
          "int", "server", 0, 1440, as_str=True),
    Field("tripwire.MapRotation", "Rotation", "ordered_maps",
          "rotation",
          choices=("Hardsell", "Hardsell_Day", "Silverreef", "Diamondspire",
                   "FragrantShore", "FragrantShore_Night", "SoundEclipse",
                   "Tutorial", "TrainingRange", "PrivateLobby"),
          help="Maps play from top to bottom; use the buttons to reorder them"),
    Field("tripwire.bRandomizeMap", "Randomize this rotation", "boolTF",
          "rotation"),
    Field("tripwire_remove", "Remove from ini", "list", "advanced",
          help="Comma-separated keys", advanced=True),
    Field("native_modules", "Native modules", "multi", "advanced",
          choices=("DINativeSpectatorStage2", "DINativeSpectatorStage3"),
          advanced=True),
    Field("launch_mode", "Launch mode", "enum", "advanced",
          choices=("", "normal", "solo12"), advanced=True),
    Field("persistent_server", "Restart after server exit", "bool", "advanced",
          help="Relaunches after results or the last human leaves an active match",
          advanced=True),
)


GROUPS = {
    "profile": ("Profile", ""),
    "timing": ("Timing", "DIConfig.ini overrides"),
    "extraction": ("Extraction", "Enabled by DIExtraction"),
    "spectator": ("Spectator", "Enabled by DINativeStage2"),
    "scoring": ("Scoring", "Enabled by DIScore"),
    "server": ("Server", "TripwireServer.ini settings owned by this profile"),
    "advanced": ("Advanced", "Less common profile keys"),
}


# Fields the form edits that are NOT profile data.  Both live on this machine
# and must never reach a profile JSON, because profiles are tracked in git: the
# join password is a TripwireServer.ini identity key that survives profile
# switches, and the lobby id belongs to the gitignored .env.  They are kept out
# of FIELDS so ProfileDraft cannot round-trip them into a profile by accident.
MACHINE_FIELDS = (
    Field("ini.Password", "Join password", "str", "server",
          help="Blank means anyone can join. Saved to TripwireServer.ini on "
               "this machine, not into the profile"),
    Field("env.SCRIMS_LOBBY_ID", "Scrims lobby id", "str", "scoring",
          needs_mod="DIScore",
          help="From the lobby's URL on the scrims site. Saved to .env"),
)


def section_fields(group, extra=()):
    """Every field shown under one section heading, profile and machine alike."""
    return tuple(field for field in tuple(FIELDS) + tuple(extra) + MACHINE_FIELDS
                 if field.group == group)


class MachineDraft:
    """Edit buffer for machine-local values, mirroring ProfileDraft's contract.

    Deliberately dumb: these are single strings with no encoding to preserve,
    so all this has to do is remember what was read and report what changed.
    """

    def __init__(self, values, fields=MACHINE_FIELDS):
        self.fields = tuple(fields)
        self.initial = {field.path: str(values.get(field.path, ""))
                        for field in self.fields}
        self.values = dict(self.initial)

    def set(self, path, value):
        self.values[path] = str(value)

    def changes(self):
        """-> {path: value} for the fields the user actually edited.

        Only changed fields, so opening a profile and pressing Save never
        rewrites a password or a lobby id that was already correct.
        """
        return {path: value for path, value in self.values.items()
                if value != self.initial[path]}

    def validation_errors(self):
        errors = {}
        for field in self.fields:
            value = self.values[field.path]
            if value != value.strip():
                errors[field.path] = f"{field.label} cannot start or end with a space"
            elif "\n" in value or "\r" in value:
                errors[field.path] = f"{field.label} cannot contain a line break"
        return errors

    def dirty(self):
        return bool(self.changes())


def mod_fields(mod_names):
    return tuple(Field(f"mods.{name}", name, "bool", "mods",
                       remove_when_false=True) for name in mod_names)


def get_path(data, path, default=MISSING):
    value = data
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return default
        value = value[part]
    return value


def _set_path(data, path, value):
    parts = path.split(".")
    parent = data
    for part in parts[:-1]:
        child = parent.get(part)
        if not isinstance(child, dict):
            child = {}
            parent[part] = child
        parent = child
    parent[parts[-1]] = value


def _delete_path(data, path):
    parts = path.split(".")
    parent = data
    for part in parts[:-1]:
        if not isinstance(parent, dict) or part not in parent:
            return
        parent = parent[part]
    if isinstance(parent, dict):
        parent.pop(parts[-1], None)


def display_value(field, value):
    if value is MISSING:
        if field.kind in ("bool", "bool01", "boolTF"):
            return False
        if field.kind == "multi":
            return ()
        return ""
    if field.kind == "boolTF":
        return str(value).strip().lower() == "true"
    if field.kind == "bool01":
        try:
            return bool(int(value))
        except (TypeError, ValueError):
            return bool(value)
    if field.kind == "bool":
        return bool(value)
    if field.kind == "list":
        return ", ".join(str(item) for item in (value or []))
    if field.kind == "ordered_maps":
        return tuple(value or ())
    if field.kind == "multi":
        return tuple(value or ())
    return str(value)


def parse_value(field, value):
    if field.kind == "int":
        raw = str(value).strip()
        if not raw:
            return MISSING
        try:
            number = int(raw)
        except ValueError:
            raise ValueError(f"{field.label} must be a whole number") from None
        if field.minimum is not None and number < field.minimum:
            raise ValueError(f"{field.label} must be at least {field.minimum}")
        if field.maximum is not None and number > field.maximum:
            raise ValueError(f"{field.label} must be at most {field.maximum}")
        return str(number) if field.as_str else number
    if field.kind == "bool01":
        return 1 if value else 0
    if field.kind == "boolTF":
        return "True" if value else "False"
    if field.kind == "bool":
        return bool(value)
    if field.kind == "list":
        return [item.strip() for item in str(value).split(",") if item.strip()]
    if field.kind == "ordered_maps":
        if isinstance(value, str):
            items = [item.strip() for item in value.split(",") if item.strip()]
        else:
            items = list(value)
        invalid = [item for item in items if item not in field.choices]
        if invalid:
            raise ValueError(
                f"{field.label} contains unknown map(s): {', '.join(invalid)}")
        if len(items) != len(set(items)):
            raise ValueError(f"{field.label} cannot contain duplicate maps")
        return items if items else MISSING
    if field.kind == "multi":
        return [choice for choice in field.choices if choice in value]
    raw = str(value)
    if not raw and field.path != "description":
        return MISSING
    if field.kind == "enum" and raw not in field.choices:
        # Existing unknown enum values remain round-trippable.  A newly typed
        # value is caught because it differs from the initial display value.
        raise ValueError(f"{field.label} must be one of: " +
                         ", ".join(choice or "(blank)" for choice in field.choices))
    return raw


class ProfileDraft:
    """An editable, order-preserving profile copy used by the Phase 0 form."""

    def __init__(self, profile, fields=FIELDS, display_defaults=None):
        self.original = deepcopy(profile)
        self.fields = tuple(fields)
        display_defaults = display_defaults or {}
        self.initial = {
            field.path: display_value(
                field,
                (display_defaults[field.path]
                 if get_path(profile, field.path) is MISSING and
                 field.path in display_defaults
                 else get_path(profile, field.path)))
            for field in self.fields
        }
        self.values = deepcopy(self.initial)

    def set(self, path, value):
        self.values[path] = value

    def validation_errors(self):
        errors = {}
        for field in self.fields:
            current = self.values[field.path]
            # A profile may contain a legacy enum/range value.  Preserve it
            # losslessly until the user actually edits that field.
            if current == self.initial[field.path]:
                continue
            try:
                parse_value(field, current)
            except ValueError as exc:
                errors[field.path] = str(exc)

        max_players = self.values.get("tripwire.MaxPlayers", "")
        bots = self.values.get("tripwire.BotsAmount", "")
        try:
            cross_field_changed = (
                max_players != self.initial.get("tripwire.MaxPlayers", "") or
                bots != self.initial.get("tripwire.BotsAmount", "")
            )
            if (cross_field_changed and str(max_players).strip() and
                    str(bots).strip() and int(bots) >= int(max_players)):
                errors["tripwire.BotsAmount"] = "Bots must be less than max players"
        except (TypeError, ValueError):
            pass
        return errors

    def collect_with_errors(self):
        """Collect once and retain field-to-error information for the UI."""
        result = deepcopy(self.original)
        field_errors = self.validation_errors()
        for field in self.fields:
            current = self.values[field.path]
            if current == self.initial[field.path]:
                continue
            if field.path in field_errors:
                continue
            try:
                parsed = parse_value(field, current)
            except ValueError:
                continue
            if parsed is MISSING or (field.remove_when_false and not parsed):
                _delete_path(result, field.path)
            else:
                _set_path(result, field.path, parsed)

        return result, field_errors

    def collect(self):
        result, field_errors = self.collect_with_errors()
        return result, list(field_errors.values())

    def dirty(self):
        result, errors = self.collect()
        return bool(errors) or result != self.original


def unknown_paths(profile, fields=FIELDS):
    """Return leaf paths that have no schema entry.

    Unknown data is still preserved by :class:`ProfileDraft`; the Setup tab
    surfaces it as an authoring error and points the user to Raw JSON.
    """
    known = {field.path for field in fields}
    known_prefixes = {".".join(path.split(".")[:index])
                      for path in known
                      for index in range(1, len(path.split(".")))}
    out = []

    def walk(value, prefix=""):
        if isinstance(value, dict):
            if prefix and not value and prefix not in known_prefixes:
                out.append(prefix)
                return
            for key, child in value.items():
                path = f"{prefix}.{key}" if prefix else key
                walk(child, path)
        elif prefix not in known:
            out.append(prefix)

    walk(profile)
    return out
