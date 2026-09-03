#!/usr/bin/env python3
"""
dimod_gui - small Tk front-end for the Deceive Inc. mod kit.

All logic lives in dimod.py; this only drives it and shows the log.
Run:  python dimod_gui.py     (or double-click dimod_gui.pyw)
"""
import io, json, os, queue, re, threading, contextlib, tkinter as tk
from tkinter import ttk, messagebox

import dimod

ANSI = re.compile(r"\x1b\[[0-9;]*m")
POLL_MS = 2000


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Deceive Inc. — Mod Kit")
        self.geometry("980x640")
        self.minsize(860, 560)

        try:
            ttk.Style().theme_use("vista")
        except tk.TclError:
            pass
        self.q = queue.Queue()
        self.busy = False
        self._log_size = 0
        self.profile_name = None
        self._last_pid = "init"
        self._last_ue4ss = None
        self._last_prof = None

        self._build()
        self._reload_profiles()
        self._tick()
        self.after(300, self._drain)

    # ---------------------------------------------------------------- ui

    def _build(self):
        root = ttk.Frame(self, padding=10)
        root.pack(fill="both", expand=True)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(1, weight=1)

        # ---- status bar
        bar = ttk.Frame(root)
        bar.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 10))
        self.lbl_server = ttk.Label(bar, text="server: ?", font=("Segoe UI", 10, "bold"))
        self.lbl_server.pack(side="left")
        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=12)
        self.lbl_ue4ss = ttk.Label(bar, text="UE4SS: ?")
        self.lbl_ue4ss.pack(side="left")
        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=12)
        self.lbl_active = ttk.Label(bar, text="profile: —")
        self.lbl_active.pack(side="left")

        # ---- left panel
        left = ttk.Frame(root)
        left.grid(row=1, column=0, sticky="nsw", padx=(0, 10))

        ttk.Label(left, text="Profiles", font=("Segoe UI", 10, "bold")).pack(anchor="w")
        self.lst = tk.Listbox(left, height=7, exportselection=False,
                              font=("Segoe UI", 10), activestyle="none")
        self.lst.pack(fill="x", pady=(4, 2))
        self.lst.bind("<<ListboxSelect>>", self._on_pick)

        self.lbl_desc = ttk.Label(left, text="", wraplength=280,
                                  foreground="#555", justify="left")
        self.lbl_desc.pack(anchor="w", pady=(0, 10))

        tf = ttk.LabelFrame(left, text="Timing (seconds)", padding=8)
        tf.pack(fill="x", pady=(0, 10))
        self.var_lobby = tk.StringVar(value="—")
        self.var_intro = tk.StringVar(value="—")
        for r, (txt, var) in enumerate((("Lobby wait", self.var_lobby),
                                        ("Intro phase", self.var_intro))):
            ttk.Label(tf, text=txt).grid(row=r, column=0, sticky="w", pady=2)
            ttk.Spinbox(tf, from_=1, to=600, width=7, textvariable=var).grid(
                row=r, column=1, sticky="e", padx=(10, 0))
        tf.columnconfigure(0, weight=1)
        ttk.Label(tf, text="defaults: 90 / 19", foreground="#888").grid(
            row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))

        mf = ttk.LabelFrame(left, text="Mods in this profile", padding=8)
        mf.pack(fill="x", pady=(0, 10))
        self.mod_vars = {}
        for m in dimod.our_mods():
            v = tk.BooleanVar(value=False)
            ttk.Checkbutton(mf, text=m, variable=v).pack(anchor="w")
            self.mod_vars[m] = v

        ttk.Button(left, text="Save changes to profile",
                   command=self._save_profile).pack(fill="x")

        # ---- right: log
        right = ttk.Frame(root)
        right.grid(row=1, column=1, sticky="nsew")
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)
        ttk.Label(right, text="Log", font=("Segoe UI", 10, "bold")).grid(
            row=0, column=0, sticky="w")
        wrap = ttk.Frame(right)
        wrap.grid(row=1, column=0, sticky="nsew", pady=(4, 0))
        wrap.rowconfigure(0, weight=1)
        wrap.columnconfigure(0, weight=1)
        self.txt = tk.Text(wrap, wrap="none", font=("Consolas", 9),
                           bg="#1e1e1e", fg="#d4d4d4", insertbackground="#d4d4d4",
                           relief="flat", padx=8, pady=6)
        self.txt.grid(row=0, column=0, sticky="nsew")
        sb = ttk.Scrollbar(wrap, command=self.txt.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.txt.config(yscrollcommand=sb.set)
        for tag, col in (("ok", "#4ec9b0"), ("warn", "#dcdcaa"),
                         ("err", "#f48771"), ("dim", "#808080")):
            self.txt.tag_config(tag, foreground=col)

        # ---- buttons
        btns = ttk.Frame(root)
        btns.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        self.buttons = {}
        for txt, fn, side in (("Apply", self._apply, "left"),
                              ("Apply + Restart", self._restart, "left"),
                              ("Start", self._start, "left"),
                              ("Stop", self._stop, "left"),
                              ("Restore stock", self._vanilla, "right")):
            b = ttk.Button(btns, text=txt, command=fn)
            b.pack(side=side, padx=(0, 6) if side == "left" else (6, 0))
            self.buttons[txt] = b

    # ------------------------------------------------------------ helpers

    def log(self, s, tag=None):
        self.txt.insert("end", s.rstrip("\n") + "\n", tag or ())
        self.txt.see("end")

    def _reload_profiles(self):
        keep = self.profile_name          # don't yank the user's selection away
        self.profiles = dimod.profiles()
        self.lst.delete(0, "end")
        for n in self.profiles:
            self.lst.insert("end", "  " + n)
        names = list(self.profiles)
        if not names:
            return
        target = keep if keep in names else dimod.load_state().get("profile")
        idx = names.index(target) if target in names else 0
        self.lst.selection_clear(0, "end")
        self.lst.selection_set(idx)
        self.lst.see(idx)
        self._on_pick()

    def _selected(self):
        s = self.lst.curselection()
        return list(self.profiles)[s[0]] if s else None

    def _on_pick(self, _=None):
        n = self._selected()
        if not n:
            return
        self.profile_name = n
        p = self.profiles[n]
        self.lbl_desc.config(text=p.get("description", ""))
        timing = (p.get("diconfig") or {}).get("Timing", {})
        self.var_lobby.set(str(timing.get("LobbyWaitTime", "")))
        self.var_intro.set(str(timing.get("IntroPhaseTime", "")))
        mods = p.get("mods", {})
        for m, v in self.mod_vars.items():
            v.set(bool(mods.get(m)))

    def _save_profile(self):
        n = self.profile_name
        if not n:
            return
        p = self.profiles[n]
        p["mods"] = {m: v.get() for m, v in self.mod_vars.items() if v.get()}
        timing = {}
        for key, var in (("LobbyWaitTime", self.var_lobby),
                         ("IntroPhaseTime", self.var_intro)):
            raw = var.get().strip()
            if raw and raw != "—":
                try:
                    timing[key] = int(float(raw))
                except ValueError:
                    messagebox.showerror("Bad value", f"{key} must be a number")
                    return
        if timing:
            p.setdefault("diconfig", {})["Timing"] = timing
        path = os.path.join(dimod.PROFILES, n + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(p, f, indent=2)
            # Trailing newline: profiles are tracked in git and json.dump does
            # not write one, so without this every save dirties the repo by a
            # single byte and shows up as a whitespace-only diff.
            f.write("\n")
        self.log(f"saved profile '{n}'", "ok")

    def _run(self, label, fn):
        """Run a dimod command on a worker thread, piping its stdout to the log."""
        if self.busy:
            self.log("busy - wait for the current action to finish", "warn")
            return
        self.busy = True
        for b in self.buttons.values():
            b.state(["disabled"])
        self.log("")
        self.log(f"--- {label} ---", "dim")

        def work():
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    fn()
            except Exception as e:
                buf.write(f"\nERROR: {e}\n")
            self.q.put(("out", ANSI.sub("", buf.getvalue())))
            self.q.put(("done", label))

        threading.Thread(target=work, daemon=True).start()

    def _drain(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "out":
                    for line in payload.splitlines():
                        if not line.strip():
                            continue
                        low = line.lower()
                        tag = ("err" if ("error" in low or "no such" in low or "cannot" in low)
                               else "warn" if ("!" in line or "already" in low)
                               else "ok" if ("applied" in low or "restored" in low or "stopped" in low)
                               else None)
                        self.log("  " + line.strip(), tag)
                elif kind == "done":
                    self.busy = False
                    for b in self.buttons.values():
                        b.state(["!disabled"])
                    self._reload_profiles()
        except queue.Empty:
            pass
        self.after(200, self._drain)

    # ------------------------------------------------------------ actions

    def _apply(self):
        n = self._selected()
        if n:
            self._save_profile()
            self._run(f"apply {n}", lambda: dimod.cmd_apply(n))

    def _restart(self):
        n = self._selected()
        if not n:
            return
        self._save_profile()

        def seq():
            dimod.cmd_stop()
            if dimod.cmd_apply(n) == 0:
                dimod.cmd_launch()
        self._run(f"restart {n}", seq)

    def _start(self):
        self._run("start server", dimod.cmd_launch)

    def _stop(self):
        self._run("stop server", dimod.cmd_stop)

    def _vanilla(self):
        if not messagebox.askyesno(
                "Restore stock",
                "Turn off all mods and restore the original TripwireServer.ini?\n\n"
                "Your current config is backed up into baseline\\ first.\n"
                "UE4SS stays installed (inert without mods)."):
            return
        self._run("restore stock", lambda: dimod.cmd_vanilla(False))

    # ------------------------------------------------------------ polling

    def _tick(self):
        # only touch widgets when something actually changed - repainting every
        # poll is what made this feel jittery
        pid = dimod.server_pid()
        if pid != self._last_pid:
            self._last_pid = pid
            self.lbl_server.config(
                text=f"server: running (pid {pid})" if pid else "server: stopped",
                foreground="#107c10" if pid else "#888")

        ue = dimod.ue4ss_installed()
        if ue != self._last_ue4ss:
            self._last_ue4ss = ue
            self.lbl_ue4ss.config(text="UE4SS: installed" if ue else "UE4SS: missing",
                                  foreground="#107c10" if ue else "#c50f1f")

        state = dimod.load_state()
        prof = state.get("profile") or "-"
        mode = state.get("launch_mode", "normal")
        shown = prof + (" [Solo-12 memory]" if mode == "solo12" else "")
        if shown != self._last_prof:
            self._last_prof = shown
            self.lbl_active.config(text="profile: " + shown)

        self._tail()
        self.after(POLL_MS, self._tick)

    def _tail(self):
        p = dimod.UE4SS_LOG
        if not os.path.isfile(p):
            return
        try:
            size = os.path.getsize(p)
            if size < self._log_size:      # rotated / recreated
                self._log_size = 0
            if size == self._log_size:
                return
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                f.seek(self._log_size)
                new = f.read()
            self._log_size = size
            for line in new.splitlines():
                if "[Lua]" not in line:
                    continue
                msg = line.split("[Lua]", 1)[1].strip()
                low = msg.lower()
                tag = ("err" if "error" in low or "fail" in low
                       else "ok" if "[ok]" in low or "neutralised" in low or "->" in msg
                       else None)
                self.log("  " + msg, tag)
        except OSError:
            pass


if __name__ == "__main__":
    App().mainloop()
