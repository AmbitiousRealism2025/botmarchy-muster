#!/usr/bin/env python3
"""Botmarchy Muster snapshot — runs ON the gateway box.

Prints one JSON line summarizing every Hermes profile: enough for the
status-bar glance and the roster window's engage/skip decision.

No network access of any kind: profiles' state.db opened read-only (URI
mode=ro, 2s lock timeout), plus a last-run marker under ~/.cache.

Data source is the profiles' state.db (read-only, no HTTP, no session
token, no dashboard dependency). Working-state is a message-tail
heuristic: the newest message being a tool result or a very fresh user
message means a turn is in flight; an assistant message ending with
finish_reason 'stop' means idle.

Output contract (consumed by muster.sh / botmarchy-muster):
{
  "generated": <epoch>,
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


_HEX_RE = __import__("re").compile(r"^#[0-9a-fA-F]{6}$")


def _avatar_meta(home: Path) -> dict | None:
    """The app writes avatars to ui_meta['hermes-bots'] in profile.yaml
    (shape + color; image/pet avatars are app-asset concepts the bar has no
    pipeline for — shape chips only, MP-5)."""
    try:
        import yaml  # PyYAML ships with the Hermes runtime

        meta = yaml.safe_load((home / "profile.yaml").read_text()) or {}
        hb = (meta.get("ui_meta") or {}).get("hermes-bots") or {}
        color = str(hb.get("color") or "")
        shape = str(hb.get("shape") or "")
        if _HEX_RE.match(color):
            return {"color": color.lower(), "shape": shape or "circle"}
    except Exception:
        pass
    return None


def summarize_profile(name: str, home: Path) -> dict:
    bot = {
        "name": display_title(home, name),
        "profile": name,
        "last_role": None,
        "last_message": "",
        "last_activity": None,
        "working": False,
        "avatar": _avatar_meta(home),
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


SNAPSHOT_VERSION = "0.1.7"

# Composite review P2.1: --ack hands its argument into the watermark keyed
# by profile id; ids are gateway directory names matching the CLI's
# _PROFILE_ID_RE shape. The ack path validates locally rather than trusting
# the caller (the panel already gates; this is the box-side backstop).
import re  # noqa: E402

_PROFILE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

# Unread watermark (MP-4): the LAST activity epoch delivered per profile.
# has_new = activity advanced past the watermark AND is fresher than a day
# (direct-app reads can't clear it — the 24h decay keeps stale news from
# sticking forever). The watermark does NOT advance on plain polls: the
# signal persists until the panel ACKS it (--ack <profile>, fired on
# engage) — a 10-second pulse would be useless at glance distance.
NEWS_DECAY_SECONDS = 86400


def _cache_dir() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    return Path(xdg) if xdg else Path.home() / ".cache"


def _watermark_path() -> Path:
    return _cache_dir() / "botmarchy" / "muster-delivered.json"


def _load_watermark() -> dict | None:
    try:
        data = json.loads(_watermark_path().read_text())
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _save_watermark(wm: dict) -> None:
    path = _watermark_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(wm, separators=(",", ":")))
    os.replace(tmp, path)


# Composite review P3.12: polls (read) and engage-acks (read-modify-write)
# can interleave — two concurrent runs can both base off the old watermark
# and the last writer erases the other's update (a lost ack resurrects the
# unread dot; a lost poll-init can flag the whole court). flock the RMW so
# watermark transitions are serialized. Lock is advisory and side-table
# (.lock file); a dead holder releases it via fd close.
import fcntl  # noqa: E402


class _watermark_lock:
    """Context manager: exclusive advisory lock for watermark RMW."""

    def __enter__(self):
        self._path = _watermark_path().with_suffix(".lock")
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = os.open(self._path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_exc):
        fcntl.flock(self._fd, fcntl.LOCK_UN)
        os.close(self._fd)
        return False


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--version", "-V"):
        print(SNAPSHOT_VERSION)
        return 0

    os.environ.setdefault("HERMES_HOME", str(Path.home() / ".hermes"))
    try:
        infos = profiles_mod.list_profiles()
    except Exception:
        infos = []

    bots = [summarize_profile(i.name, Path(i.path)) for i in infos]
    bots.sort(key=lambda b: (not b["working"], -(b["last_activity"] or 0)))

    if len(sys.argv) > 2 and sys.argv[1] == "--ack":
        target = sys.argv[2]
        if not _PROFILE_ID_RE.match(target):
            print("ack: invalid profile id", file=sys.stderr)
            return 1
        with _watermark_lock():
            wm = _load_watermark() or {}
            la = next((b["last_activity"] or 0 for b in bots if b["profile"] == target), None)
            if la is None:
                print(f"ack: unknown profile {target}", file=sys.stderr)
                return 1
            wm[target] = la
            _save_watermark(wm)
        print(f"acked {target} at {la}")
        return 0

    # The read-compute-write of has_new is part of the same serialized
    # section: without the lock, an ack landing between the read and the
    # first-run init write would be erased (P3.12).
    with _watermark_lock():
        wm = _load_watermark()
        if wm is None:
            # First run: initialize the watermark to current activity WITHOUT
            # flagging — deploying must not light up every bot at once.
            wm = {b["profile"]: b["last_activity"] or 0 for b in bots}
            _save_watermark(wm)
            initialized = True
        else:
            initialized = False

    if initialized:
        for b in bots:
            b["has_new"] = False
    else:
        now = time.time()
        for b in bots:
            la = b["last_activity"] or 0
            b["has_new"] = la > wm.get(b["profile"], 0) and (now - la) < NEWS_DECAY_SECONDS

    payload = json.dumps(
        {"generated": time.time(), "bots": bots},
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
