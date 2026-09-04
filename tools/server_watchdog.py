#!/usr/bin/env python3
"""Keep an opt-in local dedicated-server profile alive between matches.

The shipping server requests process exit after RESULT_SCREEN and when the last
human leaves an active match. This supervisor does not interfere with that
lifecycle: it waits for the process to finish and then runs the normal
launch-and-UE4SS-injection path again.
"""
import os
import subprocess
import sys
import time


KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if KIT not in sys.path:
    sys.path.insert(0, KIT)

import dimod


def append(message):
    with open(dimod.SERVER_WATCHDOG_LOG, "a", encoding="utf-8") as handle:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        handle.write(f"{stamp} {message}\n")


def stopped():
    return os.path.isfile(dimod.SERVER_WATCHDOG_STOP)


def launch_once():
    inject = os.path.join(KIT, "tools", "inject.py")
    proc = subprocess.Popen(
        [dimod.python_exe(), inject, "--launch"], cwd=KIT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace")
    lines = []
    while proc.poll() is None:
        if stopped():
            proc.terminate()
            proc.wait(timeout=5)
            return None
        line = proc.stdout.readline()
        if line:
            lines.append(line.rstrip())
        else:
            time.sleep(0.1)
    rest = proc.stdout.read()
    if rest:
        lines.extend(rest.splitlines())
    for line in lines:
        append("launch: " + line)
    if proc.returncode:
        append(f"launch/injection failed with exit code {proc.returncode}")
        return None
    pid = dimod.server_pid()
    if pid:
        append(f"tracking server pid {pid}")
    return pid


def clear_own_markers():
    try:
        with open(dimod.SERVER_WATCHDOG_PID, encoding="ascii") as handle:
            owns_pidfile = int(handle.read().strip()) == os.getpid()
    except Exception:
        owns_pidfile = False
    if owns_pidfile:
        for path in (dimod.SERVER_WATCHDOG_PID, dimod.SERVER_WATCHDOG_READY,
                     dimod.SERVER_WATCHDOG_STOP):
            try:
                os.remove(path)
            except OSError:
                pass


def main():
    append(f"supervisor started pid {os.getpid()} kit={KIT}")
    failures = 0
    try:
        while not stopped():
            started = time.monotonic()
            pid = launch_once()
            if not pid:
                if stopped():
                    break
                failures += 1
                delay = min(60, 3 * (2 ** min(failures - 1, 4)))
                append(f"no server after launch; retrying in {delay}s")
            else:
                failures = 0
                with open(dimod.SERVER_WATCHDOG_READY, "w", encoding="ascii") as handle:
                    handle.write(str(pid))
                while dimod.pid_alive(pid) and not stopped():
                    time.sleep(1)
                if stopped():
                    break
                runtime = time.monotonic() - started
                delay = 3 if runtime >= 30 else min(60, 30 - int(runtime))
                append(f"server pid {pid} exited after {runtime:.1f}s; "
                       f"relaunching in {delay}s")
            deadline = time.monotonic() + delay
            while time.monotonic() < deadline and not stopped():
                time.sleep(0.25)
    finally:
        append("supervisor stopped")
        clear_own_markers()


if __name__ == "__main__":
    main()
