#!/usr/bin/env python3
"""Tk front-end for the Deceive Inc. mod kit.

All logic stays in ``dimod.py``; this window drives it and renders the
result.  Every action that writes a file or controls a process goes through
:meth:`App.dispatch`, which runs it on a worker thread and pipes its stdout
into the Kit log.  ``--dry-run`` turns that gateway into a logger, so the
whole window can be exercised without touching the game folder.

Run directly::

    python dimod_gui.py [--dry-run]
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
from copy import deepcopy
from tkinter import filedialog, messagebox, simpledialog, ttk

import dimod
from profile_schema import (FIELDS, GROUPS, MACHINE_FIELDS, Field,
                            MachineDraft, ProfileDraft, mod_fields,
                            section_fields, unknown_paths)


ANSI = re.compile(r"\x1b\[[0-9;]*m")
POLL_MS = 2000
DRAIN_MS = 200
GUI_STATE = os.path.join(dimod.KIT, ".gui-state.json")
# The order `dimod.py doctor` prints, so a row here and a line there agree.
DOCTOR_CHECKS = (dimod.check_platform, dimod.check_server, dimod.check_writable,
                 dimod.check_ue4ss, dimod.check_baseline, dimod.check_profile,
                 dimod.check_scrims)
# The two checks that are not pure reads: one writes a probe file, the other
# reaches the network.  A dry run reports them instead of running them.
DRY_RUN_SKIPPED = {"check_writable": "Win64 writable", "check_scrims": "scrims"}
# Where each machine-local field is read from and written to.  Named functions
# rather than a generic setter, so dimod keeps saying why each one is special.
MACHINE_IO = {
    "ini.Password": (lambda: dimod.server_password(), dimod.set_server_password),
    "env.SCRIMS_LOBBY_ID": (lambda: dimod.scrims_lobby(), dimod.set_scrims_lobby),
}
BG = "#ffffff"
SOFT = "#f6f7f9"
BORDER = "#d9dee7"
TEXT = "#20242b"
MUTED = "#68707d"
BLUE = "#0969c7"
GREEN = "#16803a"
RED = "#c43d4b"
AMBER = "#9a6700"


class LogWriter(io.TextIOBase):
    """Stdout replacement that hands whole lines to the UI thread.

    ``contextlib.redirect_stdout`` needs a file object, and Tk widgets may
    only be touched from the main thread, so a worker's prints land on a
    queue instead.  Buffering to a newline keeps a command's output arriving
    while it runs rather than in one block when it finishes.
    """

    def __init__(self, sink):
        self.sink = sink
        self.pending = ""

    def write(self, text):
        self.pending += text
        while "\n" in self.pending:
            line, self.pending = self.pending.split("\n", 1)
            self.sink.put(("out", line))
        return len(text)

    def flush(self):
        if self.pending:
            self.sink.put(("out", self.pending))
            self.pending = ""


class AccentButton(tk.Button):
    """Small native-Tk button used where ttk's Vista theme ignores colours."""

    def __init__(self, parent, **kwargs):
        super().__init__(
            parent, background=BLUE, foreground="#ffffff",
            activebackground="#075cad", activeforeground="#ffffff",
            disabledforeground="#dce8f4", relief="flat", borderwidth=0,
            highlightthickness=0, padx=15, pady=7,
            font=("Segoe UI", 9, "bold"), cursor="hand2", **kwargs)

    def state(self, states=None):
        if states is None:
            return ("disabled",) if self.cget("state") == "disabled" else ()
        if "disabled" in states:
            self.configure(state="disabled", background="#9bb9d6")
        elif "!disabled" in states:
            self.configure(state="normal", background=BLUE)
        return self.state()


class ScrollFrame(ttk.Frame):
    def __init__(self, parent):
        super().__init__(parent)
        self.canvas = tk.Canvas(
            self, highlightthickness=0, background=BG, yscrollincrement=1)
        scrollbar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.inner = ttk.Frame(self.canvas, style="Surface.TFrame")
        self.window = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self._region_job = None
        self._width_job = None
        self._pending_width = None
        self._last_width = None
        self.canvas.configure(yscrollcommand=scrollbar.set)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        scrollbar.grid(row=0, column=1, sticky="ns")
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        self.inner.bind("<Configure>", self._resize_region)
        self.canvas.bind("<Configure>", self._resize_inner)
        self.winfo_toplevel().bind("<MouseWheel>", self._wheel, add="+")

    def _resize_region(self, _event=None):
        if self._region_job is not None:
            self.after_cancel(self._region_job)
        self._region_job = self.after_idle(self._apply_region)

    def _apply_region(self):
        self._region_job = None
        width = self._last_width or self.canvas.winfo_width()
        self.canvas.configure(
            scrollregion=(0, 0, width, self.inner.winfo_reqheight()))

    def _resize_inner(self, event):
        self._pending_width = event.width
        if self._width_job is not None:
            self.after_cancel(self._width_job)
        self._width_job = self.after(30, self._apply_inner_width)

    def _apply_inner_width(self):
        self._width_job = None
        width = self._pending_width
        if width != self._last_width:
            self.canvas.itemconfigure(self.window, width=width)
            self._last_width = width

    def _wheel(self, event):
        widget = self.winfo_containing(event.x_root, event.y_root)
        while widget is not None and widget is not self:
            if (isinstance(widget, (ttk.Spinbox, ttk.Combobox, tk.Text)) and
                    widget.focus_get() is widget):
                # Its class binding has already handled the wheel.  Do not
                # scroll the page as well when the value control has focus.
                return "break"
            widget = widget.master
        if widget is not self or not event.delta:
            return None
        return self.scroll_delta(event.delta)

    def scroll_delta(self, delta):
        if not delta:
            return None
        pixels = -delta
        if 0 < abs(pixels) < 1:
            pixels = 1 if pixels > 0 else -1
        self.canvas.yview_scroll(int(pixels), "units")
        return "break"


class Collapsible(ttk.Frame):
    def __init__(self, parent, title, hint="", open_=True, on_open=None):
        super().__init__(parent, style="Card.TFrame", padding=(12, 9))
        self.open = open_
        self.on_open = on_open
        head = ttk.Frame(self, style="CardBody.TFrame")
        head.pack(fill="x")
        self.toggle = ttk.Button(head, text="", width=2, style="Disclosure.TButton",
                                 command=self.flip)
        self.toggle.pack(side="left")
        ttk.Label(head, text=title, style="Section.TLabel").pack(side="left")
        if hint:
            ttk.Label(head, text=hint, style="Hint.TLabel").pack(side="left", padx=(8, 0))
        self.rule = ttk.Separator(self, orient="horizontal")
        self.body = ttk.Frame(self, style="CardBody.TFrame", padding=(4, 9, 4, 3))
        self._show()

    def flip(self):
        self.open = not self.open
        self._show()
        if self.open and self.on_open:
            self.on_open()

    def _show(self):
        self.toggle.configure(text="▾" if self.open else "▸")
        if self.open:
            self.rule.pack(fill="x", pady=(7, 0))
            self.body.pack(fill="x")
        else:
            self.rule.pack_forget()
            self.body.pack_forget()


class OrderedMapPicker(ttk.Frame):
    """Friendly ordered-list editor that stores Tripwire's short map names."""

    LABELS = {
        "Hardsell": "Hard Sell",
        "Hardsell_Day": "Hard Sell — Day",
        "Silverreef": "Silver Reef",
        "Diamondspire": "Diamond Spire",
        "FragrantShore": "Fragrant Shore",
        "FragrantShore_Night": "Fragrant Shore — Night",
        "SoundEclipse": "Sound Eclipse",
        "Tutorial": "Tutorial (special)",
        "TrainingRange": "Training Range (special)",
        "PrivateLobby": "Private Lobby (special)",
    }

    def __init__(self, parent, choices, on_change):
        super().__init__(parent, style="CardBody.TFrame")
        self.choices = tuple(choices)
        self.on_change = on_change
        self.items = []
        self.columnconfigure(0, weight=1)

        add_row = ttk.Frame(self, style="CardBody.TFrame")
        add_row.grid(row=0, column=0, sticky="ew", pady=(0, 5))
        add_row.columnconfigure(0, weight=1)
        labels = [self.LABELS.get(name, name) for name in self.choices]
        self.available = ttk.Combobox(
            add_row, state="readonly", values=labels, width=28)
        if labels:
            self.available.current(0)
        self.available.grid(row=0, column=0, sticky="ew")
        ttk.Button(add_row, text="Add", command=self._add).grid(
            row=0, column=1, padx=(6, 0))

        list_row = ttk.Frame(self, style="CardBody.TFrame")
        list_row.grid(row=1, column=0, sticky="ew")
        list_row.columnconfigure(0, weight=1)
        self.listbox = tk.Listbox(
            list_row, height=5, exportselection=False, activestyle="dotbox",
            font=("Segoe UI", 9), background="#ffffff", foreground=TEXT,
            selectbackground="#dbeafe", selectforeground=TEXT,
            relief="flat", borderwidth=0, highlightthickness=1,
            highlightbackground=BORDER, highlightcolor=BLUE)
        self.listbox.grid(row=0, column=0, sticky="ew")
        controls = ttk.Frame(list_row, style="CardBody.TFrame")
        controls.grid(row=0, column=1, sticky="n", padx=(6, 0))
        ttk.Button(controls, text="Move up", command=lambda: self._move(-1)).pack(fill="x")
        ttk.Button(controls, text="Move down", command=lambda: self._move(1)).pack(
            fill="x", pady=4)
        ttk.Button(controls, text="Remove", command=self._remove).pack(fill="x")

    def get(self):
        return tuple(self.items)

    def set(self, values):
        self.items = list(values or ())
        self._render()

    def _render(self, selected=None):
        self.listbox.delete(0, "end")
        for name in self.items:
            self.listbox.insert("end", self.LABELS.get(name, name))
        if selected is not None and self.items:
            selected = max(0, min(selected, len(self.items) - 1))
            self.listbox.selection_set(selected)
            self.listbox.activate(selected)
            self.listbox.see(selected)

    def _add(self):
        index = self.available.current()
        if index < 0:
            return
        name = self.choices[index]
        if name in self.items:
            self._render(self.items.index(name))
            return
        self.items.append(name)
        self._render(len(self.items) - 1)
        self.on_change()

    def _selected(self):
        selection = self.listbox.curselection()
        return selection[0] if selection else None

    def _move(self, delta):
        index = self._selected()
        target = index + delta if index is not None else -1
        if index is None or target < 0 or target >= len(self.items):
            return
        self.items[index], self.items[target] = self.items[target], self.items[index]
        self._render(target)
        self.on_change()

    def _remove(self):
        index = self._selected()
        if index is None:
            return
        self.items.pop(index)
        self._render(min(index, len(self.items) - 1))
        self.on_change()


class ProfileForm(ttk.Frame):
    """Schema renderer backed by an in-memory :class:`ProfileDraft`."""

    def __init__(self, parent, mod_names, on_change, on_open_profile,
                 on_open_balance):
        super().__init__(parent)
        self.mod_names = tuple(mod_names)
        self.profile_fields = FIELDS + mod_fields(self.mod_names)
        self.machine_fields = MACHINE_FIELDS
        self.fields = self.profile_fields + self.machine_fields
        self.on_change = on_change
        self.on_open_profile = on_open_profile
        self.on_open_balance = on_open_balance
        self.draft = None
        self.machine = MachineDraft({})
        self.vars = {}
        self.widgets = {}
        self.help_labels = {}
        self.sections = {}
        self._loading = False
        self._change_job = None
        self._visible_mods = None
        self._cached_profile = {}
        self._cached_errors = ["No profile selected"]
        self._cached_dirty = False
        self._raw_window = None
        self._raw_text = None
        try:
            self.current_server_name = dimod.read_ini_values(
                dimod.TRIPWIRE).get("ServerName", "")
        except OSError:
            self.current_server_name = ""

        self.scroll = ScrollFrame(self)
        self.scroll.pack(fill="both", expand=True)
        root = self.scroll.inner
        root.columnconfigure(0, weight=1)

        self.banner = tk.Label(root, anchor="w", justify="left", padx=10, pady=8,
                               background="#fff4ce", foreground="#5c4200")
        self.banner.grid(row=0, column=0, sticky="ew", padx=8, pady=(8, 4))
        self.unknown_warning = tk.Label(
            root, anchor="w", justify="left", padx=10, pady=6,
            background="#fff4ce", foreground=AMBER)

        body = ttk.Frame(root)
        body.grid(row=2, column=0, sticky="nsew", padx=8, pady=(4, 12))
        body.columnconfigure(0, weight=1)
        self._description(body, 0)
        self._server_section(body, 1)
        self._section(body, "timing", 2)
        self._mods_section(body, 3)
        self._maps_section(body, 4)
        self._section(body, "extraction", 5)
        self._section(body, "spectator", 6)
        self._section(body, "scoring", 7)
        self._section(body, "advanced", 8, open_=False)
        self._raw_section(body, 9)

    def _description(self, parent, row):
        field = next(field for field in FIELDS if field.path == "description")
        line = ttk.Frame(parent, style="Surface.TFrame")
        line.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        line.columnconfigure(0, weight=1)
        ttk.Label(line, text=field.label).grid(row=0, column=0, sticky="w")
        text = tk.Text(
            line, height=3, wrap="word", font=("Segoe UI", 9),
            background="#ffffff", foreground=TEXT, relief="flat",
            borderwidth=0, highlightthickness=1,
            highlightbackground=BORDER, highlightcolor=BLUE,
            padx=7, pady=6)
        text.grid(row=1, column=0, sticky="ew", pady=(3, 0))
        text.bind("<<Modified>>", self._description_changed)
        text.bind("<MouseWheel>", self._input_wheel)
        self.vars[field.path] = text
        self.widgets[field.path] = [text]

    def _section(self, parent, group, row, open_=True):
        title, hint = GROUPS[group]
        section = Collapsible(parent, title, hint, open_=open_)
        section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        section.body.columnconfigure(1, weight=1)
        self.sections[group] = section
        fields = section_fields(group)
        for index, field in enumerate(fields):
            self._field(section.body, field, index)
        if group == "scoring":
            # A missing .env used to fail silently: nothing synced the rotation
            # and nothing said why.  Presence only - the API key's value must
            # never reach a window.
            self.env_status = ttk.Label(
                section.body, style="Hint.TLabel", wraplength=700, justify="left")
            self.env_status.grid(row=len(fields) * 2, column=0, columnspan=2,
                                 sticky="w", pady=(6, 0))

    def refresh_env_status(self):
        label = getattr(self, "env_status", None)
        if label is None:
            return
        present, missing = dimod.scrims_env_state()
        if not present:
            text = "No .env in the kit root — scores and rotation cannot sync. " \
                   "Copy .env.example to .env and fill it in."
            colour = RED
        elif missing:
            text = "In .env but not set: " + ", ".join(missing)
            colour = AMBER
        else:
            text = "Scrims credentials are set in .env."
            colour = GREEN
        label.configure(text=text, foreground=colour)

    def _server_section(self, parent, row):
        title, hint = GROUPS["server"]
        section = Collapsible(parent, title, hint)
        section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        section.body.columnconfigure(0, weight=1, uniform="server")
        section.body.columnconfigure(1, weight=1, uniform="server")
        self.sections["server"] = section

        match = ttk.Frame(section.body, style="CardBody.TFrame")
        visibility = ttk.Frame(section.body, style="CardBody.TFrame")
        match.grid(row=0, column=0, sticky="new", padx=(0, 8))
        visibility.grid(row=0, column=1, sticky="new")
        match.columnconfigure(1, weight=1)
        visibility.columnconfigure(1, weight=1)
        ttk.Label(match, text="Match", style="Subsection.TLabel").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 3))
        ttk.Label(visibility, text="Visibility & lifetime", style="Subsection.TLabel").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 3))

        # Named rather than sliced: the two columns are an editorial choice,
        # and a slice silently reshuffles them whenever a field is added.
        columns = {
            match: ("tripwire.ServerName", "tripwire.GameMode",
                    "tripwire.MaxPlayers", "tripwire.BotsAmount",
                    "tripwire.BotsDifficulty", "tripwire.bFillWithBots"),
            visibility: ("tripwire.bIsPublic", "ini.Password",
                         "tripwire.bSandboxMode", "tripwire.bEnableUPnP",
                         "tripwire.AutoShutdownEmptyMinutes"),
        }
        by_path = {field.path: field for field in section_fields("server")}
        placed = {path for paths in columns.values() for path in paths}
        assert placed == set(by_path), f"server fields not laid out: {placed ^ set(by_path)}"
        for parent, paths in columns.items():
            for index, path in enumerate(paths, start=1):
                self._field(parent, by_path[path], index)

        balance = ttk.Frame(section.body, style="CardBody.TFrame")
        balance.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(9, 0))
        ttk.Button(balance, text="Open balance config",
                   command=self.on_open_balance).pack(side="left")
        ttk.Label(
            balance,
            text=("CommunityBalanceProfile.json · opens in "
                  "DeceiveIncBalanceUITool"),
            style="Hint.TLabel").pack(side="left", padx=(9, 0))

    def _maps_section(self, parent, row):
        section = Collapsible(
            parent, "Maps", "Choose maps and their play order")
        section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        section.body.columnconfigure(0, weight=1)
        self.sections["maps"] = section

        self.rotation_editor = ttk.Frame(section.body, style="CardBody.TFrame")
        self.rotation_editor.columnconfigure(1, weight=1)
        rotation_fields = [field for field in FIELDS if field.group == "rotation"]
        for index, field in enumerate(rotation_fields):
            self._field(self.rotation_editor, field, index)
        self.rotation_editor.grid(row=0, column=0, sticky="ew")

        self.rotation_owner_note = ttk.Label(
            section.body,
            text=("DIScore controls MapRotation and bRandomizeMap through "
                  "scrims sync for this profile."),
            style="Hint.TLabel", wraplength=700, justify="left")
        self.rotation_owner_note.grid(row=0, column=0, sticky="w")

    def _mods_section(self, parent, row):
        section = Collapsible(parent, "Mods", "What this profile turns on")
        section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        section.body.columnconfigure(1, weight=1)
        self.sections["mods"] = section
        for index, field in enumerate(mod_fields(self.mod_names)):
            variable = tk.BooleanVar()
            check = ttk.Checkbutton(section.body, text=field.label, variable=variable)
            check.grid(row=index, column=0, sticky="w", pady=3)
            info = dimod.MOD_INFO.get(field.label, {})
            help_text = info.get("description", "")
            ttk.Label(section.body, text=help_text, style="Hint.TLabel").grid(
                row=index, column=1, sticky="w", padx=(14, 4), pady=3)
            if info.get("experimental"):
                ttk.Label(section.body, text="EXPERIMENTAL", style="Experimental.TLabel").grid(
                    row=index, column=2, sticky="e", padx=(8, 0))
            self.vars[field.path] = variable
            self.widgets[field.path] = [check]
            variable.trace_add("write", self._variable_changed)

    def _field(self, parent, field: Field, row):
        base = row * 2
        if field.kind in ("bool", "bool01", "boolTF"):
            variable = tk.BooleanVar()
            widget = ttk.Checkbutton(parent, text=field.label, variable=variable)
            widget.grid(row=base, column=0, columnspan=2, sticky="w", pady=(3, 0))
            self.vars[field.path] = variable
            self.widgets[field.path] = [widget]
            variable.trace_add("write", self._variable_changed)
            if field.help:
                helper = ttk.Label(parent, text=field.help, style="Hint.TLabel")
                helper.grid(
                    row=base + 1, column=0, columnspan=2, sticky="w",
                    padx=(22, 0), pady=(0, 3))
                self.help_labels[field.path] = helper
            return

        ttk.Label(parent, text=field.label).grid(row=base, column=0, sticky="w", pady=3)
        if field.kind == "multi":
            variables = {}
            holder = ttk.Frame(parent, style="CardBody.TFrame")
            for choice in field.choices:
                variable = tk.BooleanVar()
                ttk.Checkbutton(holder, text=choice, variable=variable).pack(anchor="w")
                variable.trace_add("write", self._variable_changed)
                variables[choice] = variable
            widget = holder
            self.vars[field.path] = variables
            child_widgets = list(holder.winfo_children())
        elif field.kind == "ordered_maps":
            widget = OrderedMapPicker(parent, field.choices, self._changed)
            self.vars[field.path] = widget
            child_widgets = [widget]
        else:
            variable = tk.StringVar()
            if field.kind == "enum":
                widget = ttk.Combobox(parent, textvariable=variable, values=field.choices,
                                      state="readonly", width=19)
            elif field.kind == "int":
                widget = ttk.Spinbox(parent, textvariable=variable,
                                     from_=field.minimum, to=field.maximum, width=9)
            else:
                widget = ttk.Entry(parent, textvariable=variable)
            self.vars[field.path] = variable
            child_widgets = [widget]
            variable.trace_add("write", self._variable_changed)
            if field.kind in ("enum", "int"):
                widget.bind("<MouseWheel>", self._input_wheel)
        widget.grid(row=base, column=1, sticky="ew", padx=(10, 0), pady=3)
        self.widgets[field.path] = child_widgets
        helper = ttk.Label(parent, text=self._help_text(field), style="Hint.TLabel")
        helper.grid(row=base + 1, column=0, columnspan=2, sticky="w",
                    padx=(22, 0), pady=(0, 3))
        self.help_labels[field.path] = helper

    def _help_text(self, field):
        return field.help

    def _input_wheel(self, event):
        if event.widget.focus_get() is event.widget:
            return None
        # Widget-level bindings run before ttk's Spinbox/Combobox class
        # bindings, so returning break here prevents an accidental value edit.
        return self.scroll.scroll_delta(event.delta)

    def _description_changed(self, event):
        text = event.widget
        if not text.edit_modified():
            return
        text.edit_modified(False)
        self._changed()

    def _raw_section(self, parent, row):
        section = Collapsible(parent, "Raw JSON", "Read-only; complete profile", open_=False)
        section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        controls = ttk.Frame(section.body, style="CardBody.TFrame")
        controls.pack(fill="x")
        ttk.Button(controls, text="View raw JSON...",
                   command=self._open_raw_dialog).pack(side="left")
        ttk.Button(controls, text="Open in editor",
                   command=self.on_open_profile).pack(side="left", padx=(7, 0))

    def _open_raw_dialog(self):
        self._flush_changes()
        if self._raw_window is not None and self._raw_window.winfo_exists():
            self._raw_window.lift()
            self._raw_window.focus_force()
            return
        window = tk.Toplevel(self)
        window.title("Raw profile JSON")
        window.geometry("720x620")
        window.minsize(480, 320)
        window.transient(self.winfo_toplevel())
        toolbar = ttk.Frame(window, padding=(10, 8))
        toolbar.pack(fill="x")
        ttk.Button(toolbar, text="Open in editor",
                   command=self.on_open_profile).pack(side="left")
        ttk.Button(toolbar, text="Close", command=self._close_raw_dialog).pack(side="right")
        raw = tk.Text(window, wrap="none", font=("Consolas", 9),
                      background="#f8fafc", foreground=TEXT,
                      relief="flat", borderwidth=0, highlightthickness=1,
                      highlightbackground=BORDER, highlightcolor=BLUE,
                      padx=7, pady=6)
        raw.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self._raw_window = window
        self._raw_text = raw
        window.protocol("WM_DELETE_WINDOW", self._close_raw_dialog)
        self._set_raw(self._cached_profile)

    def _close_raw_dialog(self):
        if self._raw_window is not None:
            self._raw_window.destroy()
        self._raw_window = None
        self._raw_text = None

    def load(self, draft: ProfileDraft, machine: MachineDraft,
             selected, deployed, running):
        if self._change_job is not None:
            self.after_cancel(self._change_job)
            self._change_job = None
        self._loading = True
        self.draft = draft
        self.machine = machine
        for field in self.fields:
            value = (machine if field in self.machine_fields else draft).values[field.path]
            target = self.vars[field.path]
            if field.kind == "text":
                target.edit_modified(False)
                target.delete("1.0", "end")
                target.insert("1.0", value)
                target.mark_set("insert", "1.0")
                target.yview_moveto(0)
                target.edit_modified(False)
            elif field.kind == "multi":
                selected_values = set(value)
                for choice, variable in target.items():
                    variable.set(choice in selected_values)
            elif field.kind == "ordered_maps":
                target.set(value)
            else:
                target.set(value)
        self._loading = False
        unknown = unknown_paths(draft.original, self.profile_fields)
        if unknown:
            noun = "key" if len(unknown) == 1 else "keys"
            shown = ", ".join(f"`{path}`" for path in unknown)
            self.unknown_warning.configure(
                text=f"Unknown {noun} {shown}; edit in Raw JSON.")
            self.unknown_warning.grid(row=1, column=0, sticky="ew", padx=8, pady=(0, 4))
        else:
            self.unknown_warning.grid_remove()
        self.set_context(selected, deployed, running)
        self.refresh_env_status()
        self._visible_mods = None
        self._apply_changes()

    def set_context(self, selected, deployed, running):
        if selected == deployed and running:
            text = f"{selected} is deployed and the server is running."
            bg, fg = "#dff0d8", "#155724"
        elif selected == deployed:
            text = f"{selected} is deployed; the server is stopped."
            bg, fg = "#e8f1fb", "#174a7e"
        else:
            deployed_text = deployed or "nothing"
            text = (f"Selected {selected}; {deployed_text} is deployed. "
                    "Save & Deploy would switch profiles.")
            bg, fg = "#fff4ce", "#5c4200"
        self.banner.configure(text=text, background=bg, foreground=fg)

    def _read_widget(self, field):
        source = self.vars[field.path]
        if field.kind == "text":
            return source.get("1.0", "end-1c")
        if field.kind == "multi":
            return tuple(choice for choice in field.choices if source[choice].get())
        return source.get()

    def _variable_changed(self, *_args):
        self._changed()

    def _changed(self):
        if self._loading or self.draft is None:
            return
        if self._change_job is not None:
            self.after_cancel(self._change_job)
        self._change_job = self.after(60, self._apply_changes)

    def _flush_changes(self):
        if self._change_job is not None:
            self.after_cancel(self._change_job)
            self._change_job = None
            self._apply_changes()

    def _apply_changes(self):
        self._change_job = None
        if self._loading or self.draft is None:
            return
        for field in self.profile_fields:
            self.draft.set(field.path, self._read_widget(field))
        for field in self.machine_fields:
            self.machine.set(field.path, self._read_widget(field))
        profile, field_errors = self.draft.collect_with_errors()
        field_errors.update(self.machine.validation_errors())
        errors = list(field_errors.values())
        for field in self.fields:
            helper = self.help_labels.get(field.path)
            if helper is None:
                continue
            error = field_errors.get(field.path)
            helper.configure(text=error or self._help_text(field),
                             foreground=RED if error else MUTED)
        self._cached_profile = profile
        self._cached_errors = errors
        self._cached_dirty = (bool(errors) or profile != self.draft.original
                              or self.machine.dirty())
        if self._raw_window is not None and self._raw_window.winfo_exists():
            self._set_raw(profile)
        self._refresh_conditions()
        self.on_change(errors, self._cached_dirty)

    def _set_raw(self, profile):
        raw = self._raw_text
        if raw is None:
            return
        raw.configure(state="normal")
        raw.delete("1.0", "end")
        raw.insert("1.0", json.dumps(profile, indent=2) + "\n")
        raw.mark_set("insert", "1.0")
        raw.yview_moveto(0)
        raw.configure(state="disabled")

    def _refresh_conditions(self):
        active_mods = frozenset(
            name for name in self.mod_names
            if self.vars[f"mods.{name}"].get())
        if active_mods == self._visible_mods:
            return
        self._visible_mods = active_mods
        if "DIScore" in active_mods:
            self.rotation_editor.grid_remove()
            self.rotation_owner_note.grid()
        else:
            self.rotation_owner_note.grid_remove()
            self.rotation_editor.grid()
        for group, section in self.sections.items():
            requirements = {field.needs_mod
                            for field in section_fields(group)
                            if field.needs_mod}
            if requirements and not requirements.issubset(active_mods):
                section.grid_remove()
            else:
                section.grid()

    def collect(self):
        self._flush_changes()
        return self._cached_profile if self.draft else {}

    def machine_changes(self):
        """-> {path: value} for machine-local fields the user edited."""
        self._flush_changes()
        return self.machine.changes()

    def errors(self):
        self._flush_changes()
        return self._cached_errors

    def dirty(self):
        self._flush_changes()
        return bool(self.draft and self._cached_dirty)


class App(tk.Tk):
    def __init__(self, dry_run=False):
        super().__init__()
        self.dry_run = dry_run
        self.title("Deceive Inc. — Mod Kit" + (" — dry run" if dry_run else ""))
        self.geometry(self._saved_geometry())
        self.minsize(900, 650)
        self.configure(background=BG)
        self.protocol("WM_DELETE_WINDOW", self._close)
        self._configure_style()

        self.profiles = dimod.profiles()
        self.mod_names = tuple(dimod.our_mods())
        self.profile_fields = FIELDS + mod_fields(self.mod_names)
        try:
            server_name = dimod.read_ini_values(
                dimod.TRIPWIRE).get("ServerName", "")
        except OSError:
            server_name = ""
        self.profile_display_defaults = (
            {"tripwire.ServerName": server_name} if server_name else {})
        self.drafts = {name: ProfileDraft(
                           profile, self.profile_fields,
                           self.profile_display_defaults)
                       for name, profile in self.profiles.items()}
        self.dirty = {name: False for name in self.profiles}
        self.invalid = {name: False for name in self.profiles}
        # One draft for the whole window, not one per profile: the password
        # and the lobby id belong to this machine and do not change when the
        # selection does.
        self.machine = self._read_machine()
        self.profile_name = None
        self.balance_tool_path = self._saved_balance_tool()
        self._last_status = None
        self.log_views = {}
        self._log_offsets = {"UE4SS": 0, "DIScore": 0}
        self.action_groups = {}
        self.action_reasons = {}
        self.action_panels = {}
        self.action_enabled = {}
        # One action at a time: redirect_stdout is process-wide, so two
        # workers would interleave their output into the same log.
        self.busy = False
        self.output = queue.Queue()
        self._after_action = None

        self._build()
        self._load_profiles()
        if dry_run:
            self.log("Dry run. No action can write files or start/stop processes.",
                     "warn")
            self.log("Edit fields freely; changes exist only in this window.", "dim")
        # Offline at startup, so the window is usable before any network call.
        self._run_doctor(offline=True)
        self._tick()
        self.after(DRAIN_MS, self._drain)

    @staticmethod
    def _saved_geometry():
        try:
            with open(GUI_STATE, encoding="utf-8") as handle:
                geometry = json.load(handle).get("geometry", "")
            if isinstance(geometry, str) and re.fullmatch(
                    r"\d+x\d+(?:[+-]\d+){0,2}", geometry):
                return geometry
        except (OSError, ValueError, AttributeError):
            pass
        return "1000x780"

    @staticmethod
    def _saved_balance_tool():
        try:
            with open(GUI_STATE, encoding="utf-8") as handle:
                path = json.load(handle).get("balance_tool", "")
            return path if isinstance(path, str) else ""
        except (OSError, ValueError, AttributeError):
            return ""

    def _close(self):
        try:
            with open(GUI_STATE, "w", encoding="utf-8") as handle:
                json.dump({
                    "geometry": self.geometry(),
                    "balance_tool": self.balance_tool_path,
                }, handle, indent=2)
                handle.write("\n")
        except OSError as exc:
            self.log(f"Could not remember window geometry: {exc}", "warn")
        self.destroy()

    def _configure_style(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            try:
                style.theme_use("clam")
            except tk.TclError:
                pass
        style.configure(".", background=BG, foreground=TEXT,
                        font=("Segoe UI", 9))
        style.configure("TFrame", background=BG)
        style.configure("Surface.TFrame", background=BG)
        style.configure("Sidebar.TFrame", background=SOFT)
        style.configure("Topbar.TFrame", background=BG)
        style.configure("Actionbar.TFrame", background=SOFT)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Sidebar.TLabel", background=SOFT, foreground=TEXT)
        style.configure("Actionbar.TLabel", background=SOFT, foreground=MUTED)
        style.configure("TButton", background="#f4f6f8", foreground=TEXT,
                        borderwidth=1, padding=(11, 6), relief="flat")
        style.map("TButton",
                  background=[("active", "#e8ebef"), ("pressed", "#dde2e8")],
                  foreground=[("disabled", "#9aa1aa")])
        style.configure("Primary.TButton", background=BLUE, foreground="#ffffff",
                        font=("Segoe UI", 9, "bold"), borderwidth=0,
                        padding=(15, 7))
        style.map("Primary.TButton",
                  background=[("active", "#075cad"), ("pressed", "#064d91"),
                              ("disabled", "#a8bfd7")],
                  foreground=[("disabled", "#eef3f8")])
        style.configure("Disclosure.TButton", background=BG, foreground=MUTED,
                        borderwidth=0, padding=(0, 0), relief="flat")
        style.map("Disclosure.TButton",
                  background=[("active", BG), ("pressed", BG)],
                  foreground=[("active", BLUE)])
        style.configure("Card.TFrame", background=BG, relief="solid", borderwidth=1,
                        bordercolor=BORDER, lightcolor=BORDER, darkcolor=BORDER)
        style.configure("CardBody.TFrame", background=BG, relief="flat", borderwidth=0)
        style.configure("Section.TLabel", background=BG, foreground=TEXT,
                        font=("Segoe UI", 10, "bold"))
        style.configure("Subsection.TLabel", background=BG, foreground="#3d4652",
                        font=("Segoe UI", 9, "bold"))
        style.configure("Hint.TLabel", background=BG, foreground=MUTED,
                        font=("Segoe UI", 8))
        style.configure("Experimental.TLabel", background="#fff1c2", foreground=AMBER,
                        font=("Segoe UI", 7, "bold"), padding=(4, 1))
        style.configure("TEntry", fieldbackground="#ffffff", foreground=TEXT,
                        bordercolor=BORDER, lightcolor=BORDER, darkcolor=BORDER,
                        padding=(6, 5))
        style.configure("TCombobox", fieldbackground="#ffffff", foreground=TEXT,
                        arrowcolor=MUTED, padding=(5, 4))
        style.configure("TSpinbox", fieldbackground="#ffffff", foreground=TEXT,
                        arrowcolor=MUTED, padding=(5, 4))
        style.configure("TCheckbutton", background=BG, foreground=TEXT, padding=(0, 2))
        style.map("TCheckbutton", background=[("active", BG)])
        style.configure("TNotebook", background=BG, borderwidth=0, tabmargins=(0, 0, 0, 0))
        style.configure("TNotebook.Tab", background=SOFT, foreground=MUTED,
                        padding=(18, 8), borderwidth=0,
                        font=("Segoe UI", 9, "bold"))
        style.map("TNotebook.Tab",
                  background=[("selected", BG), ("active", "#edf1f5")],
                  foreground=[("selected", BLUE), ("active", TEXT)])
        style.configure("Log.TNotebook", background=BG, borderwidth=0,
                        tabmargins=(0, 0, 0, 0))
        style.configure("Log.TNotebook.Tab", background="#eceff3", foreground=MUTED,
                        padding=(11, 5), borderwidth=0,
                        font=("Segoe UI", 8, "bold"))
        style.map("Log.TNotebook.Tab",
                  background=[("selected", BG), ("active", "#e2e6eb")],
                  foreground=[("selected", BLUE), ("active", TEXT)])
        style.configure("TSeparator", background=BORDER)

    def _build(self):
        self._build_status()
        self._build_actions()
        pane = ttk.Panedwindow(self, orient="vertical", style="TPanedwindow")
        pane.pack(fill="both", expand=True)
        self.main_pane = pane

        upper = ttk.Frame(pane)
        upper.columnconfigure(1, weight=1)
        upper.rowconfigure(0, weight=1)
        pane.add(upper, weight=5)
        self._build_profiles(upper)

        self.tabs = ttk.Notebook(upper)
        self.tabs.grid(row=0, column=1, sticky="nsew", padx=(12, 14), pady=(14, 0))
        self.form = ProfileForm(
            self.tabs, self.mod_names, self._form_changed,
            self._open_profile, self._open_balance)
        self.tabs.add(self.form, text="Setup")
        self.run_scroll = ScrollFrame(self.tabs)
        self.tabs.add(self.run_scroll, text="Run")
        self.run_scroll.inner.columnconfigure(0, weight=1)
        self.run_tab = ttk.Frame(self.run_scroll.inner, padding=16)
        self.run_tab.grid(row=0, column=0, sticky="nsew")
        self._build_in_match()
        self._build_doctor()

        logs = ttk.Frame(pane)
        pane.add(logs, weight=1)
        self.logs_panel = logs
        self.logs_expanded = True
        self._logs_sash = None
        self._build_logs(logs)
        self.after_idle(lambda: self._set_initial_sash(pane))

    def _set_initial_sash(self, pane):
        try:
            position = max(430, self.winfo_height() - 240)
            pane.sashpos(0, position)
            self._logs_sash = pane.sashpos(0)
            if not self.logs_expanded:
                self._fit_collapsed_logs()
        except tk.TclError:
            pass

    def _build_status(self):
        bar = ttk.Frame(self, style="Topbar.TFrame", padding=(14, 10))
        bar.pack(fill="x")
        self.status_server = self._status_label(bar, "● Server: ?")
        self.status_ue4ss = self._status_label(bar, "● UE4SS: ?")
        self.status_deployed = self._status_label(bar, "● Deployed: —")
        self.status_scrims = self._status_label(bar, "● Scrims watcher: —")
        self.status_doctor = self._status_label(
            bar, "Doctor: checking...", side="right")
        ttk.Separator(self, orient="horizontal").pack(fill="x")

    @staticmethod
    def _status_label(parent, text, side="left"):
        label = ttk.Label(parent, text=text, foreground="#555",
                          font=("Segoe UI", 9))
        label.pack(side=side, padx=(0, 14) if side == "left" else (14, 0))
        return label

    def _build_profiles(self, parent):
        left = ttk.Frame(parent, width=225, padding=(14, 14, 12, 0),
                         style="Sidebar.TFrame")
        left.grid(row=0, column=0, sticky="nsw")
        # Children in this sidebar use pack.  Disabling grid propagation did
        # not constrain them, so the longer dirty-state message widened the
        # sidebar and made the whole Setup pane jump sideways.
        left.pack_propagate(False)
        ttk.Label(left, text="PROFILES", style="Sidebar.TLabel",
                  foreground=MUTED, font=("Segoe UI", 8, "bold")).pack(
                      anchor="w", pady=(1, 8))
        self.profile_list = tk.Listbox(left, exportselection=False, activestyle="none",
                                       font=("Segoe UI", 10), height=9,
                                       relief="flat", borderwidth=0,
                                       highlightthickness=1,
                                       highlightbackground=BORDER,
                                       highlightcolor=BORDER,
                                       background="#ffffff", foreground=TEXT,
                                       selectbackground=BLUE,
                                       selectforeground="#ffffff")
        self.profile_list.pack(fill="x")
        self.profile_list.bind("<<ListboxSelect>>", self._pick_profile)
        self.profile_list.bind("<Button-3>", self._profile_context)
        controls = ttk.Frame(left, style="Sidebar.TFrame")
        controls.pack(fill="x", pady=(8, 0))
        self.duplicate = ttk.Button(controls, text="Duplicate", command=self._duplicate)
        self.duplicate.pack(side="left", padx=(0, 5))
        self.profile_hint = ttk.Label(left,
                                      text="No unsaved changes\nThe files match this window",
                                      style="Sidebar.TLabel", foreground=MUTED,
                                      justify="left")
        self.profile_hint.pack(anchor="w", pady=(9, 0))

    @staticmethod
    def _panel(parent, title, hint=""):
        panel = ttk.Frame(parent, style="Card.TFrame", padding=12)
        head = ttk.Frame(panel, style="CardBody.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text=title, style="Section.TLabel").pack(side="left")
        if hint:
            ttk.Label(head, text=hint, style="Hint.TLabel").pack(
                side="left", padx=(9, 0))
        ttk.Separator(panel, orient="horizontal").pack(fill="x", pady=(8, 10))
        body = ttk.Frame(panel, style="CardBody.TFrame")
        body.pack(fill="both", expand=True)
        return panel, body

    def _build_in_match(self):
        self.run_tab.columnconfigure(0, weight=1)
        self.run_tab.columnconfigure(1, weight=1)
        self.match_banner = tk.Label(self.run_tab, anchor="w", padx=10, pady=8,
                                     background="#e5e5e5", foreground="#444")
        self.match_banner.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 10))

        extraction_panel, extraction = self._panel(
            self.run_tab, "Extraction", "Live carrier controls")
        self.action_panels["extraction"] = extraction_panel
        extraction_panel.grid(row=1, column=0, sticky="new", padx=(0, 6))
        extraction.columnconfigure(0, weight=1)
        extraction.columnconfigure(1, weight=1)
        ttk.Label(extraction, text="Player", foreground="#3d4652").grid(
            row=0, column=0, sticky="w")
        self.player = ttk.Entry(extraction)
        self.player.grid(row=0, column=1, sticky="ew", padx=(8, 0))
        ttk.Label(extraction, text="Name substring; blank chooses automatically.",
                  style="Hint.TLabel").grid(
                      row=1, column=0, columnspan=2, sticky="w", pady=(3, 7))
        self._action_button(extraction, "Trigger extraction", "extraction", 2, 0,
                            self._trigger_extraction)
        self._action_button(extraction, "Rescue player", "extraction", 2, 1,
                            self._rescue)
        self.action_reasons["extraction"] = ttk.Label(
            extraction, text="", style="Hint.TLabel")
        self.action_reasons["extraction"].grid(
            row=3, column=0, columnspan=2, sticky="w", pady=(8, 0))

        scoring_panel, scoring = self._panel(
            self.run_tab, "Scoring & scrims", "Reports and rotation")
        self.action_panels["scoring"] = scoring_panel
        scoring_panel.grid(row=1, column=1, sticky="new", padx=(6, 0))
        scoring.columnconfigure(0, weight=1)
        scoring.columnconfigure(1, weight=1)
        self._action_button(
            scoring, "Score report now", "scoring", 0, 0,
            lambda: self.dispatch("score report", dimod.cmd_score_report))
        self._action_button(
            scoring, "Sync rotation", "scoring", 0, 1,
            lambda: self.dispatch("sync rotation", dimod.sync_scrims_rotation))
        self._action_button(
            scoring, "Check scrims", "scoring", 1, 0,
            lambda: self.dispatch("check scrims", self._check_scrims))
        self.action_reasons["scoring"] = ttk.Label(scoring, text="", foreground=MUTED)
        self.action_reasons["scoring"].grid(
            row=2, column=0, columnspan=2, sticky="w", pady=(7, 0))

    def _build_doctor(self):
        doctor_panel, doctor = self._panel(
            self.run_tab, "Doctor", "Environment and deployment checks")
        doctor_panel.grid(row=2, column=0, columnspan=2, sticky="nsew", pady=(12, 0))
        doctor.columnconfigure(0, weight=1)
        head = ttk.Frame(doctor)
        head.grid(row=0, column=0, sticky="ew")
        self.offline = tk.BooleanVar(value=False)
        self.doctor_run = AccentButton(head, text="Run again",
                                       command=self._run_doctor)
        self.doctor_run.pack(side="left")
        ttk.Checkbutton(head, text="Offline", variable=self.offline).pack(side="left", padx=8)
        ttk.Label(head, text="Same checks, in the same order, as `dimod.py doctor`",
                  foreground=MUTED).pack(side="right")
        self.doctor_body = ttk.Frame(doctor)
        self.doctor_body.grid(row=1, column=0, sticky="ew", pady=(10, 0))

    def _run_doctor(self, offline=None):
        offline = self.offline.get() if offline is None else offline
        # Not through dispatch: these are the kit's own diagnostics, and a dry
        # run that could not report them would be the less useful mode.
        self._run("doctor", lambda: self._collect_checks(offline),
                  self._render_doctor)

    def _collect_checks(self, offline):
        """Run every doctor check.  Called on the worker thread.

        check_writable touches the disk and check_scrims can reach the
        network, so neither belongs on the UI thread even though both are
        quick when they succeed.
        """
        checks = []
        for check_fn in DOCTOR_CHECKS:
            skipped = DRY_RUN_SKIPPED.get(check_fn.__name__)
            if skipped and self.dry_run:
                checks.append(dimod.Check("warn", skipped, "skipped in dry run"))
                continue
            try:
                checks.extend(check_fn(net=not offline)
                              if check_fn is dimod.check_scrims else check_fn())
            except Exception as exc:
                checks.append(dimod.Check(
                    "fail", check_fn.__name__, f"{type(exc).__name__}: {exc}"))
        return checks

    def _render_doctor(self, checks):
        # Every row, whatever profile is selected.  The checks describe the
        # machine and the DEPLOYED profile; filtering them by the selection was
        # tried and hid live scrims failures the moment you clicked `vanilla`.
        checks = checks or []
        for child in self.doctor_body.winfo_children():
            child.destroy()
        colours = {"ok": GREEN, "warn": AMBER, "fail": RED}
        marks = {"ok": "ok", "warn": "warn", "fail": "FAIL"}
        for check in checks:
            line = ttk.Frame(self.doctor_body)
            line.pack(fill="x", pady=(2, 0))
            ttk.Label(line, text=marks.get(check.level, check.level), width=7,
                      foreground=colours.get(check.level, TEXT),
                      font=("Segoe UI", 9, "bold")).pack(side="left")
            ttk.Label(line, text=check.label, width=22).pack(side="left")
            ttk.Label(line, text=check.detail, foreground=MUTED,
                      wraplength=580, justify="left").pack(side="left", fill="x")
            if check.fix and check.level != "ok":
                ttk.Label(self.doctor_body, text="       -> " + check.fix,
                          foreground=MUTED, wraplength=760,
                          justify="left").pack(fill="x", padx=(26, 0))
        fails = sum(check.level == "fail" for check in checks)
        warns = sum(check.level == "warn" for check in checks)
        if fails:
            label, colour = f"Doctor: FAIL ({fails})", RED
        elif warns:
            label, colour = f"Doctor: ok · {warns} warning(s)", AMBER
        else:
            label, colour = "Doctor: ok", GREEN
        self.status_doctor.configure(text=label, foreground=colour)

    def _build_logs(self, parent):
        ttk.Separator(parent, orient="horizontal").pack(fill="x")
        toolbar = ttk.Frame(parent, padding=(14, 8))
        toolbar.pack(fill="x")
        self.logs_toggle = ttk.Button(
            toolbar, text="▾  LOGS", style="Disclosure.TButton",
            command=self._toggle_logs)
        self.logs_toggle.pack(side="left")
        ttk.Button(toolbar, text="Clear", command=self._clear_log).pack(side="right")
        ttk.Button(toolbar, text="Copy all", command=self._copy_log).pack(side="right", padx=5)
        self.autoscroll = tk.BooleanVar(value=True)
        ttk.Checkbutton(toolbar, text="Autoscroll", variable=self.autoscroll).pack(
            side="right", padx=5)
        self.log_tabs = ttk.Notebook(parent, style="Log.TNotebook")
        self.log_tabs.pack(fill="both", expand=True, padx=14, pady=(0, 10))
        for name in ("Kit", "UE4SS", "DIScore"):
            text = tk.Text(self.log_tabs, wrap="word", height=5, font=("Consolas", 9),
                           background="#17191d", foreground="#d7dce2",
                           insertbackground="#d4d4d4", relief="flat", padx=8, pady=6)
            for tag, colour in (("ok", "#4ec9b0"), ("warn", "#dcdcaa"),
                                ("err", "#f48771"), ("dim", "#808080")):
                text.tag_configure(tag, foreground=colour)
            self.log_tabs.add(text, text=name)
            text.configure(state="disabled")
            self.log_views[name] = text
        # No profile is selected while the shell is being built.  The tab is
        # revealed by _refresh_log_tabs only when the selected draft enables
        # DIScore.
        self.log_tabs.tab(self.log_views["DIScore"], state="hidden")

    def _toggle_logs(self):
        if self.logs_expanded:
            try:
                self._logs_sash = self.main_pane.sashpos(0)
            except tk.TclError:
                pass
            self.logs_expanded = False
            self.logs_toggle.configure(text="▸  LOGS")
            self.log_tabs.pack_forget()
            self.main_pane.pane(self.logs_panel, weight=0)
            self.after_idle(self._fit_collapsed_logs)
            return

        self.logs_expanded = True
        self.logs_toggle.configure(text="▾  LOGS")
        self.log_tabs.pack(fill="both", expand=True, padx=14, pady=(0, 10))
        self.main_pane.pane(self.logs_panel, weight=1)
        self.after_idle(self._restore_logs_sash)

    def _fit_collapsed_logs(self):
        if self.logs_expanded:
            return
        try:
            self.main_pane.sashpos(
                0, max(0, self.main_pane.winfo_height() -
                       self.logs_panel.winfo_reqheight()))
        except tk.TclError:
            pass

    def _restore_logs_sash(self):
        if not self.logs_expanded:
            return
        try:
            position = self._logs_sash
            if position is None:
                position = max(430, self.winfo_height() - 240)
            self.main_pane.sashpos(0, position)
        except tk.TclError:
            pass

    def _build_actions(self):
        bar = ttk.Frame(self, style="Actionbar.TFrame", padding=(14, 10))
        bar.pack(side="bottom", fill="x")
        ttk.Separator(self, orient="horizontal").pack(side="bottom", fill="x")
        self.save_deploy = AccentButton(bar, text="Save & Deploy  ▶",
                                        command=self._save_deploy)
        self.save_deploy.pack(side="left")
        self.start_stop = ttk.Button(bar, text="Start", command=self._start_stop)
        self.start_stop.pack(side="left", padx=(8, 0))
        self.save = ttk.Button(bar, text="Save", command=self._save)
        self.save.pack(side="left", padx=(8, 0))
        self.revert = ttk.Button(bar, text="Revert", command=self._revert)
        self.revert.pack(side="left", padx=(8, 0))
        self.more = ttk.Menubutton(bar, text="… More")
        menu = tk.Menu(self.more, tearoff=False)
        menu.add_command(label="Apply only", command=self._apply_only)
        menu.add_command(label="Restore stock", command=self._restore_stock)
        menu.add_separator()
        menu.add_command(label="Open Win64 folder",
                         command=lambda: self._open_path(dimod.WIN64))
        menu.add_command(label="Open profiles folder",
                         command=lambda: self._open_path(dimod.PROFILES))
        self.more.configure(menu=menu)
        self.more.pack(side="right")
        if self.dry_run:
            ttk.Label(bar, text="DRY RUN — action buttons only log calls",
                      style="Actionbar.TLabel", foreground=AMBER).pack(
                          side="right", padx=14)

    def _action_button(self, parent, label, group, row, column, command):
        button = ttk.Button(parent, text=label, command=command)
        button.grid(row=row, column=column, sticky="ew", padx=3, pady=3)
        self.action_groups.setdefault(group, []).append(button)
        return button

    def _player(self):
        """The carrier/rescue target; blank means 'let the mod choose'."""
        return self.player.get().strip() or None

    def _load_profiles(self):
        self._refresh_profile_list()
        names = list(self.profiles)
        if not names:
            self.log("No profiles found.", "err")
            self._refresh_buttons()
            return
        deployed = dimod.load_state().get("profile")
        target = deployed if deployed in names else names[0]
        self._select_profile(target)
        self._pick_profile()

    def _reload_profiles(self):
        """Re-read profiles from disk, keeping every unsaved edit.

        A profile the user is still editing outranks what is on disk: its
        draft is left alone and stays marked dirty.  Everything else is
        rebuilt, but only when the file actually differs, so an action that
        touched no profile does not reset the form under the user.
        """
        self.profiles = dimod.profiles()
        for name in list(self.drafts):
            if name not in self.profiles:
                del self.drafts[name]
                self.dirty.pop(name, None)
                self.invalid.pop(name, None)
        reloaded = set()
        for name, profile in self.profiles.items():
            if self.dirty.get(name):
                continue
            draft = self.drafts.get(name)
            if draft is not None and draft.original == profile:
                continue
            self.drafts[name] = ProfileDraft(
                profile, self.profile_fields, self.profile_display_defaults)
            self.dirty[name] = False
            self.invalid[name] = False
            reloaded.add(name)
        if self.profile_name not in self.profiles:
            self.profile_name = None
            self._load_profiles()
        elif self.profile_name in reloaded:
            self._reload_form()
        self._refresh_profile_list()

    def _mark_saved(self, name, profile=None):
        """Make what was just written the clean baseline for ``name``.

        Live this is exactly what was saved; in a dry run it is what would
        have been, so the window behaves the same either way.  ``profile`` is
        None when only a machine-local setting changed.
        """
        if profile is not None:
            self.profiles[name] = deepcopy(profile)
            # dimod.profiles() reads the folder in sorted order and every
            # index in this window comes from list(self.profiles), so a new
            # name has to land in its place rather than at the end.
            self.profiles = {key: self.profiles[key] for key in sorted(self.profiles)}
            self.drafts[name] = ProfileDraft(
                profile, self.profile_fields, self.profile_display_defaults)
        self.dirty[name] = False
        self.invalid[name] = False
        self.machine = MachineDraft(self.machine.values)
        if name == self.profile_name:
            self._reload_form()
        self._refresh_profile_list()
        self._refresh_buttons()

    def _discard(self, name):
        """Throw away unsaved edits to ``name`` without touching the disk."""
        self.drafts[name] = ProfileDraft(
            self.profiles[name], self.profile_fields, self.profile_display_defaults)
        # The machine-local fields are shown in the same form, so discarding
        # has to cover them too - otherwise an edited password keeps every
        # profile marked dirty and re-asks on every switch.
        self.machine = self._read_machine()
        self.dirty[name] = False
        self.invalid[name] = False

    @staticmethod
    def _read_machine():
        """Snapshot the machine-local settings the Setup tab can edit."""
        values = {}
        for path, (read, _write) in MACHINE_IO.items():
            try:
                values[path] = read()
            except OSError:
                values[path] = ""
        return MachineDraft(values)

    def _write_machine(self, changes):
        """Apply machine-local edits. Runs on the worker thread, inside a save."""
        for path, value in changes.items():
            MACHINE_IO[path][1](value)

    def _machine_confirmed(self, changes):
        """Ask before an edit that has a consequence beyond writing a file."""
        if "env.SCRIMS_LOBBY_ID" in changes and dimod.watcher_pid():
            return messagebox.askyesno(
                "Scrims watcher is running",
                "Changing the lobby id stops the running scrims watcher on its "
                "next tick, so it cannot push this scrim's scores to the "
                "previous lobby.\n\n"
                "You will need to restart the server for the new lobby.\n\n"
                "Change it anyway?")
        return True

    def _reload_form(self):
        if self.profile_name:
            self.form.load(self.drafts[self.profile_name], self.machine,
                           self.profile_name,
                           dimod.load_state().get("profile"),
                           bool(dimod.server_pid()))

    def _refresh_profile_list(self):
        selected = self.profile_name
        deployed = dimod.load_state().get("profile")
        self.profile_list.delete(0, "end")
        for name in self.profiles:
            prefix = "● " if name == deployed else "  "
            suffix = " *" if self.dirty.get(name) else ""
            self.profile_list.insert("end", prefix + name + suffix)
        if selected in self.profiles:
            index = list(self.profiles).index(selected)
            self.profile_list.selection_set(index)

    def _pick_profile(self, _event=None):
        selection = self.profile_list.curselection()
        if not selection:
            return
        name = list(self.profiles)[selection[0]]
        previous = self.profile_name
        if previous and name != previous:
            self.form.dirty()  # Flush a pending 60 ms edit before deciding.
            if self.dirty.get(previous):
                # Stay put until the question is answered: a save is a
                # dispatch and only finishes later.
                self._select_profile(previous)
                self._resolve_unsaved(previous, name)
                return
        self._show_profile(name)

    def _resolve_unsaved(self, previous, name):
        choice = messagebox.askyesnocancel(
            "Unsaved profile",
            f"Save changes to {previous!r} before switching to {name!r}?\n\n"
            "Yes: save, No: discard, Cancel: stay here.")
        if choice is None:
            return
        if not choice:
            self._discard(previous)
            self._show_profile(name)
            return
        profile, errors = self.form.collect(), self.form.errors()
        if errors:
            self.log("Cannot save: " + "; ".join(errors), "err")
            return
        self.dispatch(f"save {previous!r}",
                      lambda: self._write_profile(previous, profile),
                      after=lambda: self._save_then_show(previous, profile, name))

    def _save_then_show(self, saved, profile, name):
        self._mark_saved(saved, profile)
        self._show_profile(name)

    def _show_profile(self, name):
        if name not in self.profiles:
            return
        self.profile_name = name
        deployed = dimod.load_state().get("profile")
        pid = dimod.server_pid()
        self.form.load(self.drafts[name], self.machine, name, deployed, bool(pid))
        self._select_profile(name)
        self._refresh_profile_list()
        self._refresh_match_state(pid, deployed)

    def _profile_context(self, event):
        index = self.profile_list.nearest(event.y)
        if index < 0:
            return
        name = list(self.profiles)[index]
        self._open_path(dimod.profile_path(name))

    def _open_profile(self):
        if self.profile_name:
            self._open_path(dimod.profile_path(self.profile_name))

    def _open_balance(self):
        profile = dimod.BALANCE_PROFILE
        if not os.path.isfile(profile):
            messagebox.showerror(
                "Balance config not found",
                f"The server balance profile does not exist:\n\n{profile}\n\n"
                "Start the dedicated server once to generate it.")
            return
        tool = self._find_balance_tool()
        if not tool:
            tool = filedialog.askopenfilename(
                title="Locate DeceiveIncBalanceUITool.exe",
                filetypes=[("Deceive Inc Balance UI Tool",
                            "DeceiveIncBalanceUITool.exe"),
                           ("Applications", "*.exe")])
            if not tool:
                return
            self.balance_tool_path = tool
        try:
            subprocess.Popen(
                [tool, profile], cwd=os.path.dirname(profile))
            self.log(
                f"Opened balance config with {os.path.basename(tool)}. "
                "If the tool shows no file, use File > Open Balance File; "
                "its picker will start in the correct folder.",
                "ok")
        except OSError as exc:
            self.balance_tool_path = ""
            messagebox.showerror(
                "Could not open balance config",
                f"Could not launch {tool}:\n\n{exc}")

    def _find_balance_tool(self):
        executable = "DeceiveIncBalanceUITool.exe"
        candidates = (
            self.balance_tool_path,
            os.environ.get("DECEIVE_BALANCE_UI_TOOL", ""),
            shutil.which(executable) or "",
            os.path.join(dimod.KIT, "tools", executable),
            os.path.join(dimod.KIT, executable),
            os.path.join(dimod.SERVER, executable),
            os.path.join(dimod.WIN64, executable),
        )
        for candidate in candidates:
            if candidate and os.path.isfile(candidate):
                self.balance_tool_path = os.path.abspath(candidate)
                return self.balance_tool_path
        return ""

    def _open_path(self, path):
        try:
            os.startfile(path)
        except (AttributeError, OSError) as exc:
            self.log(f"Could not open {path}: {exc}", "err")

    def _select_profile(self, name):
        if name not in self.profiles:
            return
        self.profile_list.selection_clear(0, "end")
        index = list(self.profiles).index(name)
        self.profile_list.selection_set(index)
        self.profile_list.see(index)

    def _form_changed(self, errors, dirty):
        if not self.profile_name:
            return
        changed = self.dirty.get(self.profile_name) != dirty
        self.dirty[self.profile_name] = dirty
        self.invalid[self.profile_name] = bool(errors)
        if changed:
            self._refresh_profile_list()
        count = sum(self.dirty.values())
        if count:
            self.profile_hint.configure(
                text=f"{count} profile(s) changed *\nSave writes them to disk")
        else:
            self.profile_hint.configure(
                text="No unsaved changes\nThe files match this window")
        self._refresh_buttons()
        self._refresh_run_sections()

    def _refresh_buttons(self):
        """One place decides what is clickable.

        Busy wins over everything else: the stdout redirect is process-wide,
        so a second action started now would interleave its output with the
        first one's.
        """
        selected = bool(self.profile_name)
        dirty = selected and bool(self.dirty.get(self.profile_name))
        for widget, enabled in (
                (self.save_deploy, selected),
                (self.start_stop, True),
                (self.save, dirty),
                (self.revert, dirty),
                (self.more, True),
                (self.duplicate, selected),
                (self.doctor_run, True)):
            self._enable(widget, enabled)
        for group, buttons in self.action_groups.items():
            for button in buttons:
                self._enable(button, self.action_enabled.get(group, False))

    def _enable(self, widget, enabled):
        widget.state(["!disabled"] if enabled and not self.busy else ["disabled"])

    def _refresh_run_sections(self):
        profile = self.form.collect() if self.profile_name else {}
        mods = profile.get("mods", {})
        extraction = bool(mods.get("DIExtraction"))
        scoring = bool(mods.get("DIScore"))
        self._refresh_log_tabs(scoring)
        for panel in self.action_panels.values():
            panel.grid_remove()
        if extraction and scoring:
            self.action_panels["extraction"].grid(
                row=1, column=0, columnspan=1, sticky="new", padx=(0, 6))
            self.action_panels["scoring"].grid(
                row=1, column=1, columnspan=1, sticky="new", padx=(6, 0))
        elif extraction:
            self.action_panels["extraction"].grid(
                row=1, column=0, columnspan=2, sticky="new", padx=0)
        elif scoring:
            self.action_panels["scoring"].grid(
                row=1, column=0, columnspan=2, sticky="new", padx=0)

    def _refresh_log_tabs(self, scoring_enabled):
        """Show the DIScore stream only when the selected draft enables it."""
        view = self.log_views.get("DIScore")
        if view is not None:
            self.log_tabs.tab(
                view, state="normal" if scoring_enabled else "hidden")

    def _refresh_match_state(self, pid=None, deployed=None):
        pid = dimod.server_pid() if pid is None else pid
        deployed = dimod.load_state().get("profile") if deployed is None else deployed
        selected = self.profile_name
        live = bool(pid) and selected == deployed
        if live:
            text = f"{selected} is deployed and running — matching actions are available."
            bg, fg = "#dff0d8", "#155724"
        elif not pid:
            text = "Start the server to enable in-match actions."
            bg, fg = "#fff4ce", "#5c4200"
        else:
            text = f"Deploy {selected} first; the running server uses {deployed or 'no profile'}."
            bg, fg = "#fff4ce", "#5c4200"
        self.match_banner.configure(text=text, background=bg, foreground=fg)
        profile = self.profiles.get(deployed, {}) if live else {}
        mods = profile.get("mods", {})
        enabled = self.action_enabled = {
            "extraction": live and bool(mods.get("DIExtraction")),
            "scoring": live and bool(mods.get("DIScore")),
        }
        for group in self.action_groups:
            if not pid:
                reason = "Start the server to enable these actions."
            elif selected != deployed:
                reason = f"Deploy {selected} first."
            elif not enabled[group]:
                required = "DIExtraction" if group == "extraction" else "DIScore"
                reason = f"The deployed profile does not enable {required}."
            elif group == "scoring":
                reason = "Scrims Check reports reachability and lineup state in the Kit log."
            else:
                reason = "Ready. Player names are matched by substring."
            self.action_reasons[group].configure(
                text=reason, foreground=GREEN if enabled[group] else MUTED)
        self._refresh_buttons()

    def _save_deploy(self):
        """Save if needed, then stop, apply and launch as one action."""
        name = self.profile_name
        if not name:
            return
        edits = self._pending_edits("deploy")
        if edits is None:
            return
        profile, machine = edits

        def sequence():
            if profile is not None:
                self._write_profile(name, profile)
            self._write_machine(machine)
            dimod.cmd_stop()
            # Only launch what actually applied; a failed apply leaves the
            # game folder on the previous profile.
            if dimod.cmd_apply(name) == 0:
                dimod.cmd_launch()

        self.dispatch(
            f"deploy {name!r}" + (" (saving first)" if profile is not None else ""),
            sequence, after=lambda: self._mark_saved(name, profile))

    def _save(self):
        name = self.profile_name
        if not name:
            return
        edits = self._pending_edits("save")
        if edits is None:
            return
        profile, machine = edits

        def write():
            if profile is not None:
                self._write_profile(name, profile)
            self._write_machine(machine)

        self.dispatch(f"save {name!r}", write,
                      after=lambda: self._mark_saved(name, profile))

    def _pending_edits(self, verb):
        """-> (profile or None, machine changes), or None to abort.

        The profile is None when only a machine-local setting changed, so a
        password edit does not rewrite - and re-date - an untouched profile
        JSON that git is tracking.
        """
        name = self.profile_name
        errors = self.form.errors()
        if errors:
            self.log(f"Cannot {verb}: " + "; ".join(errors), "err")
            return None
        machine = self.form.machine_changes()
        if machine and not self._machine_confirmed(machine):
            return None
        profile = self.form.collect()
        return (profile if profile != self.drafts[name].original else None), machine

    def _revert(self):
        name = self.profile_name
        if not name:
            return
        self._discard(name)
        self._reload_form()
        self._refresh_profile_list()
        self.log(f"Reverted {name!r} to its on-disk values.", "ok")

    def _apply_only(self):
        name = self.profile_name
        if not name:
            return
        if dimod.server_pid() and not messagebox.askyesno(
                "Apply while the server runs",
                "The server is running; this takes effect on the next start.\n\n"
                "Apply anyway?"):
            return
        self.dispatch(f"apply {name!r}", lambda: dimod.cmd_apply(name))

    def _restore_stock(self):
        if not messagebox.askyesno(
                "Restore stock",
                "Turn off all mods and restore the original TripwireServer.ini?\n\n"
                "Your current config is backed up into baseline\\ first.\n"
                "UE4SS stays installed (inert without mods)."):
            return
        self.dispatch("restore stock", lambda: dimod.cmd_vanilla(False))

    def _duplicate(self):
        source = self.profile_name
        if not source:
            return
        name = simpledialog.askstring(
            "Duplicate profile", f"Name for the copy of {source!r}:", parent=self)
        if name is None:
            return
        name = name.strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            messagebox.showerror(
                "Bad profile name",
                "Use letters, digits, hyphen and underscore only — the name "
                "becomes a file in the profiles folder.")
            return
        if name in self.profiles or os.path.exists(dimod.profile_path(name)):
            messagebox.showerror("Name taken", f"{name}.json already exists.")
            return
        # A copy of what is on disk, not of the draft: Duplicate is not a
        # second way to save unreviewed edits.
        profile = deepcopy(self.profiles[source])
        self.dispatch(f"duplicate {source!r} as {name!r}",
                      lambda: self._write_profile(name, profile),
                      after=lambda: self._adopt_profile(name, profile))

    def _adopt_profile(self, name, profile):
        self._mark_saved(name, profile)
        self._show_profile(name)

    @staticmethod
    def _write_profile(name, data):
        print(f"  wrote {os.path.basename(dimod.save_profile(name, data))}")

    def _start_stop(self):
        if dimod.server_pid():
            self.dispatch("stop server", dimod.cmd_stop)
        else:
            self.dispatch("start server", dimod.cmd_launch)

    def _trigger_extraction(self):
        player = self._player()
        self.dispatch(f"trigger extraction ({player or 'first human player'})",
                      lambda: dimod.cmd_trigger_extraction(player))

    def _rescue(self):
        player = self._player()
        self.dispatch(f"rescue ({player or 'first human player'})",
                      lambda: dimod.cmd_rescue(player))

    def _check_scrims(self):
        """Read-only reachability probe, run on the worker thread.

        Only the pusher's own reasoning reaches the log: it puts notes on
        stderr and the rotation on stdout, and it redacts the API key itself.
        Nothing from the environment is printed here.
        """
        pusher = os.path.join(dimod.KIT, "tools", "scrims_push.py")
        if not os.path.isfile(pusher):
            print("  ! tools/scrims_push.py is missing")
            return 1
        result = subprocess.run(
            [dimod.python_exe(), pusher, "--print-rotation"],
            capture_output=True, text=True, cwd=dimod.KIT,
            # No console flash: the kit is normally started with pythonw.exe.
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        for line in (result.stderr or "").splitlines():
            print("  " + line)
        if result.returncode == 0:
            maps = [m for m in (result.stdout or "").strip().split(",") if m]
            print(f"  scrims reachable; {len(maps)} map(s) left in the lineup")
        elif result.returncode == dimod.EXIT_LINEUP_DONE:
            print("  scrims reachable; the lineup is finished")
        else:
            print(f"  ! scrims check failed (exit {result.returncode})")
        return result.returncode

    def dispatch(self, label, fn, after=None):
        """The gateway for every action that writes a file or moves a process.

        In a dry run nothing happens beyond the log line, but ``after`` still
        runs, so the window shows the state the action would have produced.
        Live, ``after`` runs once the worker has finished and the profiles
        have been re-read from disk.  It takes no arguments; a command's
        return value is reported through its own output.
        """
        if self.dry_run:
            self.log("would run: " + label, "warn")
            if after is not None:
                after()
            return
        self._run(label, fn, lambda _result: self._after_dispatch(after))

    def _run(self, label, fn, after=None):
        """Run ``fn`` on a worker thread with its stdout piped into the log.

        ``after`` runs back on the UI thread with ``fn``'s return value.  Use
        this directly only for actions that read; anything that writes goes
        through :meth:`dispatch` so ``--dry-run`` can gate it.
        """
        if self.busy:
            self.log("busy — wait for the current action to finish", "warn")
            return False
        self.busy = True
        self._after_action = after
        self._refresh_buttons()
        self.log(f"--- {label} ---", "dim")

        def work():
            writer = LogWriter(self.output)
            result = None
            try:
                with contextlib.redirect_stdout(writer):
                    result = fn()
            except Exception as exc:
                # Under pythonw.exe there is no console, so an escaping
                # traceback would simply vanish.
                writer.write(f"ERROR: {type(exc).__name__}: {exc}\n")
            writer.flush()
            self.output.put(("done", result))

        threading.Thread(target=work, daemon=True).start()
        return True

    def _drain(self):
        try:
            while True:
                kind, payload = self.output.get_nowait()
                if kind == "out":
                    line = ANSI.sub("", payload).rstrip()
                    if line.strip():
                        self.log(line, self._log_tag(line))
                else:
                    self._finish(payload)
        except queue.Empty:
            pass
        except Exception as exc:
            self.log(f"log drain failed: {type(exc).__name__}: {exc}", "err")
        self.after(DRAIN_MS, self._drain)

    def _finish(self, result):
        self.busy = False
        after, self._after_action = self._after_action, None
        try:
            if after is not None:
                after(result)
        except Exception as exc:
            self.log(f"ERROR: {type(exc).__name__}: {exc}", "err")
        self._refresh_status(force=True)
        self._refresh_buttons()

    def _after_dispatch(self, after):
        """Re-read what the action may have changed, then run its own hook.

        `cmd_apply` rewrites .deployed.json and a save rewrites a profile, so
        the window has to reflect disk again without a restart.
        """
        machine = self._read_machine()
        moved = machine.values != self.machine.values
        if moved:
            # `vanilla` restores the stock ini, so the password can vanish
            # underneath the form without anyone editing the field.
            self.machine = machine
        self._reload_profiles()
        if moved:
            self._reload_form()
        if after is not None:
            after()

    def log(self, message, tag=None, stream="Kit"):
        view = self.log_views.get(stream)
        if view is None:
            return
        stamp = time.strftime("%H:%M:%S")
        view.configure(state="normal")
        view.insert("end", f"{stamp}  {message.rstrip()}\n", tag or ())
        self._trim_log(view)
        if self.autoscroll.get():
            view.see("end")
        view.configure(state="disabled")

    @staticmethod
    def _trim_log(view):
        line_count = int(view.index("end-1c").split(".")[0])
        if line_count > 5000:
            view.delete("1.0", f"{line_count - 5000 + 1}.0")

    @staticmethod
    def _log_tag(line):
        shown = line.lstrip()
        low = shown.lower()
        # `refused:` is how every gated dimod command declines, so it is the
        # line the Run tab produces most often when something is not ready.
        if (shown.startswith("ERROR") or low.startswith("error:") or
                low.startswith("refused:")):
            return "err"
        if shown.startswith("!"):
            return "warn"
        if (low.startswith("applied") or low.startswith("[ok]") or
                shown.startswith("->")):
            return "ok"
        if shown.startswith(("[DIConfig]", "[DIScore]", "[DIExtraction]")):
            return "dim"
        return None

    def _tail_logs(self):
        paths = {
            "UE4SS": dimod.UE4SS_LOG,
            "DIScore": os.path.join(dimod.WIN64, "DIScore.log"),
        }
        for stream, path in paths.items():
            try:
                if not os.path.isfile(path):
                    continue
                size = os.path.getsize(path)
                offset = self._log_offsets[stream]
                if size < offset:
                    offset = 0
                if size == offset:
                    continue
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(offset)
                    new = handle.read()
                self._log_offsets[stream] = size
                lines = []
                for line in new.splitlines():
                    if stream == "UE4SS":
                        if "[Lua]" not in line:
                            continue
                        line = line.split("[Lua]", 1)[1].strip()
                    lines.append((line, self._log_tag(line)))
                if not lines:
                    continue
                view = self.log_views[stream]
                stamp = time.strftime("%H:%M:%S")
                view.configure(state="normal")
                for line, tag in lines:
                    view.insert("end", f"{stamp}  {line.rstrip()}\n", tag or ())
                self._trim_log(view)
                if self.autoscroll.get():
                    view.see("end")
                view.configure(state="disabled")
            except OSError:
                pass

    def _clear_log(self):
        view = self._current_log()
        view.configure(state="normal")
        view.delete("1.0", "end")
        view.configure(state="disabled")

    def _copy_log(self):
        text = self._current_log().get("1.0", "end-1c")
        self.clipboard_clear()
        self.clipboard_append(text)

    def _current_log(self):
        tab_id = self.log_tabs.select()
        return self.nametowidget(tab_id)

    def _tick(self):
        try:
            self._refresh_status()
            self._tail_logs()
        except Exception as exc:
            self.log(f"status refresh failed: {type(exc).__name__}: {exc}", "err")
        self.after(POLL_MS, self._tick)

    def _refresh_status(self, force=False):
        """Repaint the status strip, but only when something actually moved.

        `force` is for the end of a dispatch, where waiting up to POLL_MS to
        show the profile that was just deployed would look broken.
        """
        pid = dimod.server_pid()
        ue4ss = dimod.ue4ss_installed()
        deployed = dimod.load_state().get("profile")
        watcher = dimod.watcher_pid()
        status = (pid, ue4ss, deployed, watcher)
        if status == self._last_status and not force:
            return
        self._last_status = status
        self.status_server.configure(
            text=f"● Server running · pid {pid}" if pid else "● Server stopped",
            foreground=GREEN if pid else "#555")
        self.status_ue4ss.configure(
            text="● UE4SS installed" if ue4ss else "● UE4SS missing",
            foreground=GREEN if ue4ss else RED)
        self.status_deployed.configure(
            text=f"● Deployed: {deployed or '—'}", foreground="#175a9c")
        self.status_scrims.configure(
            text=f"● Scrims watcher: {watcher or '—'}",
            foreground=GREEN if watcher else "#555")
        self.start_stop.configure(text="Stop" if pid else "Start")
        if self.profile_name:
            self.form.set_context(self.profile_name, deployed, bool(pid))
            self._refresh_match_state(pid, deployed)
        self._refresh_profile_list()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Tk front-end for the Deceive Inc. mod kit.")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="log every write and process action instead of running it")
    args = parser.parse_args(argv)
    App(dry_run=args.dry_run).mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
