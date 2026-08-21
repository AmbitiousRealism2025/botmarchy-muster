#!/usr/bin/env python3
"""Botmarchy Muster snapshot — runs ON the gateway box.

Prints one JSON line summarizing every Hermes profile: enough for the
status-bar glance and the roster window's engage/skip decision.

Data source is the profiles' state.db (read-only, no HTTP, no session
token, no dashboard dependency). Working-state is a message-tail
heuristic: the newest message being a tool result or a very fresh user
message means a turn is in flight; an assistant message ending with
finish_reason 'stop' means idle.

Output contract (consumed by muster.sh / botmarchy-muster):
{
  "generated": <epoch>,
  "gateway": {"running": bool|null},
  "bots": [{
      "name": str,
      "last_role": str|null,
      "last_message": str,          # single line, <=80 chars
      "last_activity": epoch|null,
      "working": bool
  }]
}
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path

_HERMES_ROOT_CANDIDATES = [
    Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes"))) / "hermes-agent",
    Path.home() / ".local" / "hermes-agent",
]

for _root in _HERMES_ROOT_CANDIDATES:
    if (_root / "hermes_cli").is_dir():
        sys.path.insert(0, str(_root))
        break

from hermes_cli import profiles as profiles_mod  # noqa: E402

WORKING_WINDOW_SECONDS = 300  # fresh tail counts as working only this long
SNIPPET_LEN = 80


def one_line(text: str | None, limit: int = SNIPPET_LEN) -> str:
    line = " ".join((text or "").split())
    return line[: limit - 1] + "…" if len(line) > limit else line


def display_title(home: Path, fallback: str) -> str:
    """Bot title as the desktop roster shows it (ui_meta.hermes-bots.title)."""
    import re

    try:
        raw = (home / "profile.yaml").read_text()
    except OSError:
        return fallback

    match = re.search(r"^\s*title:\s*(.+)$", raw, re.MULTILINE)
    title = match.group(1).strip().strip("\"'") if match else ""

    return title or fallback


def summarize_profile(name: str, home: Path) -> dict:
    bot = {
        "name": display_title(home, name),
        "profile": name,
        "last_role": None,
        "last_message": "",
        "last_activity": None,
        "working": False,
    }
    db_path = home / "state.db"
    if not db_path.exists():
        return bot

    try:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return bot

    try:
        rows = db.execute(
            """
            SELECT m.role, m.finish_reason, m.timestamp, m.content
            FROM messages m
            WHERE m.active = 1 AND m.compacted = 0 AND m.content IS NOT NULL AND m.content != ''
            ORDER BY m.id DESC LIMIT 1
            """
        ).fetchall()
    except sqlite3.Error:
        return bot
    finally:
        db.close()

    if not rows:
        return bot

    role, finish_reason, ts, content = rows[0]
    bot["last_role"] = role
    bot["last_activity"] = ts
    bot["last_message"] = one_line(content)

    age = time.time() - (ts or 0)
    fresh = age < WORKING_WINDOW_SECONDS
    if role == "tool" and fresh:
        bot["working"] = True          # tool result awaiting the next step
    elif role == "user" and fresh:
        bot["working"] = True          # prompt just landed, turn starting
    elif role == "assistant" and finish_reason == "tool_calls" and fresh:
        bot["working"] = True          # model is calling tools right now

    return bot


def gateway_running() -> bool | None:
    try:
        import urllib.request

        with urllib.request.urlopen("http://127.0.0.1:9119/api/status", timeout=1.5) as resp:
            return bool(json.load(resp).get("gateway_running"))
    except Exception:
        return None


def main() -> int:
    os.environ.setdefault("HERMES_HOME", str(Path.home() / ".hermes"))
    try:
        infos = profiles_mod.list_profiles()
    except Exception:
        infos = []

    bots = [summarize_profile(i.name, Path(i.path)) for i in infos]
    bots.sort(key=lambda b: (not b["working"], -(b["last_activity"] or 0)))

    payload = json.dumps(
        {"generated": time.time(), "gateway": {"running": gateway_running()}, "bots": bots},
        separators=(",", ":"),
    )

    # Invocation marker for the bar widget's poll (debug/verification).
    # Atomic: tmp + replace, so a killed process can't leave it truncated.
    try:
        marker = Path.home() / ".cache" / "botmarchy-muster-last-run"
        tmp = marker.with_suffix(".tmp")
        tmp.write_text(str(time.time()) + "\n")
        os.replace(tmp, marker)
    except OSError:
        pass

    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
