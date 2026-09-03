#!/usr/bin/env python3
"""Phase 0 prototype of the Deceive Inc. mod-kit GUI.

The old ``dimod_gui.py`` remains the production launcher.  This prototype
loads real profiles and has live, lossless form state.  Safe reads run for
real; writes and process-control actions are routed through
:meth:`App.dispatch`.  While ``DRY_RUN`` is true that method only writes the
call it would make to the Kit log.

Run directly to try it::

    python dimod_gui2.py
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import dimod
from profile_schema import (FIELDS, GROUPS, Field, ProfileDraft, mod_fields,
                            unknown_paths)


DRY_RUN = True
POLL_MS = 2000
GUI_STATE = os.path.join(dimod.KIT, ".gui-state.json")
BG = "#ffffff"
SOFT = "#f6f7f9"
BORDER = "#d9dee7"
TEXT = "#20242b"
MUTED = "#68707d"
BLUE = "#0969c7"
GREEN = "#16803a"
RED = "#c43d4b"
AMBER = "#9a6700"


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
        self.fields = FIELDS + mod_fields(self.mod_names)
        self.on_change = on_change
        self.on_open_profile = on_open_profile
        self.on_open_balance = on_open_balance
        self.draft = None
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
        fields = [field for field in FIELDS if field.group == group]
        for index, field in enumerate(fields):
            self._field(section.body, field, index)

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

        fields = [field for field in FIELDS if field.group == "server"]
        for index, field in enumerate(fields[:6], start=1):
            self._field(match, field, index)
        for index, field in enumerate(fields[6:], start=1):
            self._field(visibility, field, index)

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

    def load(self, draft: ProfileDraft, selected, deployed, running):
        if self._change_job is not None:
            self.after_cancel(self._change_job)
            self._change_job = None
        self._loading = True
        self.draft = draft
        for field in self.fields:
            value = draft.values[field.path]
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
        unknown = unknown_paths(draft.original, self.fields)
        if unknown:
            noun = "key" if len(unknown) == 1 else "keys"
            shown = ", ".join(f"`{path}`" for path in unknown)
            self.unknown_warning.configure(
                text=f"Unknown {noun} {shown}; edit in Raw JSON.")
            self.unknown_warning.grid(row=1, column=0, sticky="ew", padx=8, pady=(0, 4))
        else:
            self.unknown_warning.grid_remove()
        self.set_context(selected, deployed, running)
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
        for field in self.fields:
            self.draft.set(field.path, self._read_widget(field))
        profile, field_errors = self.draft.collect_with_errors()
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
        self._cached_dirty = bool(errors) or profile != self.draft.original
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
            requirements = {field.needs_mod for field in FIELDS
                            if field.group == group and field.needs_mod}
            if requirements and not requirements.issubset(active_mods):
                section.grid_remove()
            else:
                section.grid()

    def collect(self):
        self._flush_changes()
        return self._cached_profile if self.draft else {}

    def errors(self):
        self._flush_changes()
        return self._cached_errors

    def dirty(self):
        self._flush_changes()
        return bool(self.draft and self._cached_dirty)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Deceive Inc. — Mod Kit (Phase 0 prototype)")
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
        self.profile_name = None
        self.balance_tool_path = self._saved_balance_tool()
        self._last_status = None
        self.log_views = {}
        self._log_offsets = {"UE4SS": 0, "DIScore": 0}
        self.action_groups = {}
        self.action_reasons = {}
        self.action_panels = {}

        self._build()
        self._load_profiles()
        self.log("Phase 0 is in dry-run mode. No action can write files or start/stop processes.",
                 "warn")
        self.log("Edit fields freely; changes exist only in this window.", "dim")
        self._run_doctor()
        self._tick()

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
        self.run_tab = ttk.Frame(self.tabs, padding=16)
        self.tabs.add(self.run_tab, text="Run")
        self._build_in_match()
        self._build_doctor()

        logs = ttk.Frame(pane)
        pane.add(logs, weight=1)
        self._build_logs(logs)
        self.after_idle(lambda: self._set_initial_sash(pane))

    def _set_initial_sash(self, pane):
        try:
            pane.sashpos(0, max(430, self.winfo_height() - 240))
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
        self._dry_button(controls, "Duplicate", lambda: (
            f"duplicate profile {self.profile_name!r}"), side="left")
        self.profile_hint = ttk.Label(left, text="No unsaved changes\nChanges are memory-only",
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
                            lambda: f"dimod.cmd_trigger_extraction({self._player_repr()})")
        self._action_button(extraction, "Rescue player", "extraction", 2, 1,
                            lambda: f"dimod.cmd_rescue({self._player_repr()})")
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
        self._action_button(scoring, "Score report now", "scoring", 0, 0,
                            lambda: "dimod.cmd_score_report()")
        self._action_button(scoring, "Sync rotation", "scoring", 0, 1,
                            lambda: "dimod.sync_scrims_rotation()")
        self._action_button(scoring, "Check scrims", "scoring", 1, 0,
                            lambda: "tools.scrims_push --print-rotation")
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
        AccentButton(head, text="Run again", command=self._run_doctor).pack(side="left")
        ttk.Checkbutton(head, text="Offline", variable=self.offline).pack(side="left", padx=8)
        ttk.Label(head, text="Write and network checks stay gated in dry run",
                  foreground=MUTED).pack(side="right")
        self.doctor_body = ttk.Frame(doctor)
        self.doctor_body.grid(row=1, column=0, sticky="ew", pady=(10, 0))

    def _run_doctor(self):
        checks = []
        for check_fn in (dimod.check_platform, dimod.check_server,
                         dimod.check_ue4ss, dimod.check_baseline,
                         dimod.check_profile):
            try:
                checks.extend(check_fn())
            except Exception as exc:
                checks.append(dimod.Check(
                    "fail", check_fn.__name__,
                    f"{type(exc).__name__}: {exc}"))
        if DRY_RUN:
            checks.extend((
                dimod.Check("warn", "Win64 writable", "skipped in dry run"),
                dimod.Check("warn", "scrims", "skipped in dry run"),
            ))
        else:
            checks.extend(dimod.check_writable())
            checks.extend(dimod.check_scrims(net=not self.offline.get()))
        self._render_doctor(checks)

    def _render_doctor(self, checks):
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
        ttk.Label(toolbar, text="LOGS", foreground=MUTED,
                  font=("Segoe UI", 8, "bold")).pack(side="left")
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
        more = ttk.Menubutton(bar, text="… More")
        menu = tk.Menu(more, tearoff=False)
        menu.add_command(label="Apply only", command=lambda: self.dispatch(
            f"dimod.cmd_apply({self.profile_name!r})"))
        menu.add_command(label="Restore stock", command=lambda: self.dispatch(
            "dimod.cmd_vanilla(False)"))
        menu.add_separator()
        menu.add_command(label="Open Win64 folder",
                         command=lambda: self._open_path(dimod.WIN64))
        menu.add_command(label="Open profiles folder",
                         command=lambda: self._open_path(dimod.PROFILES))
        more.configure(menu=menu)
        more.pack(side="right")
        ttk.Label(bar, text="DRY RUN — action buttons only log calls",
                  style="Actionbar.TLabel", foreground=AMBER).pack(
                      side="right", padx=14)

    def _dry_button(self, parent, label, call, side=None, style=None):
        command = lambda: self.dispatch(call() if callable(call) else call)
        if style == "Primary.TButton":
            button = AccentButton(parent, text=label, command=command)
        else:
            button = ttk.Button(parent, text=label, command=command, style=style)
        if side:
            button.pack(side=side, padx=(0, 5))
        return button

    def _action_button(self, parent, label, group, row, column, call):
        button = ttk.Button(parent, text=label, command=lambda: self.dispatch(call()))
        button.grid(row=row, column=column, sticky="ew", padx=3, pady=3)
        self.action_groups.setdefault(group, []).append(button)
        return button

    def _player_repr(self):
        value = self.player.get().strip()
        return repr(value) if value else "None"

    def _load_profiles(self):
        self._refresh_profile_list()
        names = list(self.profiles)
        if not names:
            self.log("No profiles found.", "err")
            return
        deployed = dimod.load_state().get("profile")
        target = deployed if deployed in names else names[0]
        index = names.index(target)
        self.profile_list.selection_set(index)
        self._pick_profile()

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
        if previous:
            self.form.dirty()  # Flush a pending 60 ms edit before deciding.
        if previous and name != previous and self.dirty.get(previous):
            choice = messagebox.askyesnocancel(
                "Unsaved profile",
                f"Save changes to {previous!r} before switching?\n\n"
                "Yes: simulate Save, No: discard, Cancel: stay here.")
            if choice is None:
                self.profile_list.selection_clear(0, "end")
                self.profile_list.selection_set(list(self.profiles).index(previous))
                return
            if choice:
                profile, errors = self.form.collect(), self.form.errors()
                if errors:
                    self.log("Cannot simulate save: " + "; ".join(errors), "err")
                    self._select_profile(previous)
                    return
                self.dispatch(f"dimod.save_profile({previous!r}, "
                              f"<{len(json.dumps(profile))} bytes>)")
                self.drafts[previous] = ProfileDraft(
                    profile, self.profile_fields, self.profile_display_defaults)
                self.dirty[previous] = False
                self.invalid[previous] = False
            else:
                self.drafts[previous] = ProfileDraft(
                    self.profiles[previous], self.profile_fields,
                    self.profile_display_defaults)
                self.dirty[previous] = False
                self.invalid[previous] = False
        self.profile_name = name
        deployed = dimod.load_state().get("profile")
        pid = dimod.server_pid()
        self.form.load(self.drafts[name], name, deployed, bool(pid))
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
        self.profile_list.selection_clear(0, "end")
        self.profile_list.selection_set(list(self.profiles).index(name))

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
            self.profile_hint.configure(text=f"{count} profile(s) changed *\nMemory-only; nothing is saved")
        else:
            self.profile_hint.configure(text="No unsaved changes\nChanges are memory-only")
        self.save.state(["!disabled"] if dirty else ["disabled"])
        self.revert.state(["!disabled"] if dirty else ["disabled"])
        self.save_deploy.state(["!disabled"])
        self._refresh_run_sections()

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
        enabled = {
            "extraction": live and bool(mods.get("DIExtraction")),
            "scoring": live and bool(mods.get("DIScore")),
        }
        for group, buttons in self.action_groups.items():
            for button in buttons:
                button.state(["!disabled"] if enabled[group] else ["disabled"])
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

    def _save_deploy(self):
        if not self.profile_name:
            return
        profile, errors = self.form.collect(), self.form.errors()
        if errors:
            self.log("Cannot simulate deploy: " + "; ".join(errors), "err")
            return
        name = self.profile_name
        self.dispatch(f"dimod.save_profile({name!r}, <{len(json.dumps(profile))} bytes>); "
                      f"dimod.cmd_stop(); dimod.cmd_apply({name!r}); dimod.cmd_launch()")
        if DRY_RUN:
            self._mark_simulated_save(name, profile)

    def _save(self):
        if self.profile_name:
            profile, errors = self.form.collect(), self.form.errors()
            if errors:
                self.log("Cannot simulate save: " + "; ".join(errors), "err")
                return
            self.dispatch(f"dimod.save_profile({self.profile_name!r}, "
                          f"<{len(json.dumps(profile))} bytes>)")
            if DRY_RUN:
                self._mark_simulated_save(self.profile_name, profile)

    def _revert(self):
        if self.profile_name:
            name = self.profile_name
            self.drafts[name] = ProfileDraft(
                self.profiles[name], self.profile_fields,
                self.profile_display_defaults)
            self.dirty[name] = False
            self.invalid[name] = False
            deployed = dimod.load_state().get("profile")
            self.form.load(self.drafts[name], name, deployed,
                           bool(dimod.server_pid()))
            self._refresh_profile_list()
            self.log(f"Reverted {name!r} to its on-disk values.", "ok")

    def _mark_simulated_save(self, name, profile):
        """Make a dry-run save the new in-memory baseline until Revert."""
        self.drafts[name] = ProfileDraft(
            profile, self.profile_fields, self.profile_display_defaults)
        self.dirty[name] = False
        self.invalid[name] = False
        if name == self.profile_name:
            deployed = dimod.load_state().get("profile")
            self.form.load(self.drafts[name], name, deployed,
                           bool(dimod.server_pid()))
        self._refresh_profile_list()

    def _start_stop(self):
        self.dispatch("dimod.cmd_stop()" if dimod.server_pid() else "dimod.cmd_launch()")

    def dispatch(self, call):
        """Single gateway for all backend actions in this prototype."""
        if DRY_RUN:
            self.log("would run: " + call, "warn")
            return
        # Phase 0 intentionally has no live execution branch.  Keeping this
        # explicit prevents somebody from changing the constant and assuming
        # the prototype is production-wired.
        self.log("ERROR: live execution is not wired in Phase 0", "err")

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
        if shown.startswith("ERROR") or low.startswith("error:"):
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
            pid = dimod.server_pid()
            ue4ss = dimod.ue4ss_installed()
            deployed = dimod.load_state().get("profile")
            watcher = dimod.watcher_pid()
            status = (pid, ue4ss, deployed, watcher)
            if status != self._last_status:
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
            self._tail_logs()
        except Exception as exc:
            self.log(f"status refresh failed: {type(exc).__name__}: {exc}", "err")
        self.after(POLL_MS, self._tick)


if __name__ == "__main__":
    App().mainloop()
