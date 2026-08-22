#!/usr/bin/env python3
"""Botmarchy usage record — writes the record the Omarchy agents panel renders.

Runs ON the gateway box (like muster-snapshot). Aggregates EVERY court
profile's state.db into the omarchy agents-usage record contract (one JSON
printed to stdout; the local writer drops it into
~/.local/state/omarchy/agents/usage/botmarchy.json on the desktop).

Read-only: state.db opens with URI mode=ro (2s busy timeout). Token numbers
come from session_model_usage (per-model input/output/cache_read/cache_write
actually billed) — never invented; days roll up from messages.timestamp.

Record contract (observed from omarchy-agent-usage-update's claude/codex
records): schemaVersion, id, name, updatedAt, ready, hasLocalStats,
usageStatusText, tierLabel, todayPrompts, todaySessions, todayTotalTokens,
todayTokensByModel, recentDays[{date,messageCount}], modelUsage{model:{…}},
totalPrompts, totalSessions, activeDays, activeDates.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

USAGE_VERSION = "0.1.1"

_HERMES_ROOT_CANDIDATES = [
    Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes"))) / "hermes-agent",
    Path.home() / ".local" / "hermes-agent",
]

for _root in _HERMES_ROOT_CANDIDATES:
    if (_root / "hermes_cli").is_dir():
        sys.path.insert(0, str(_root))
        break

try:
    from hermes_cli import profiles as profiles_mod  # noqa: E402
except Exception:  # pragma: no cover
    profiles_mod = None

# ── profile discovery (mirrors muster-snapshot) ────────────────────────────


def profile_roots() -> list[tuple[str, Path]]:
    if profiles_mod is not None:
        try:
            return [(i.name, Path(i.path)) for i in profiles_mod.list_profiles()]
        except Exception:
            pass
    home = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
    roots = [("default", home)]
    for p in sorted((home / "profiles").glob("*")):
        if p.is_dir():
            roots.append((p.name, p))
    return roots


# ── aggregation ─────────────────────────────────────────────────────────────

def _connect(home: Path) -> sqlite3.Connection | None:
    db_path = home / "state.db"
    if not db_path.exists():
        return None

    try:
        return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return None


def _day(ts: float | int | None) -> str | None:
    if not ts:
        return None

    try:
        return _dt.datetime.fromtimestamp(float(ts), tz=_dt.timezone.utc).astimezone().strftime("%Y-%m-%d")
    except (ValueError, OverflowError, OSError):
        return None


def aggregate() -> dict:
    model_usage: dict[str, dict[str, int]] = {}
    day_messages: dict[str, int] = {}
    day_sessions: dict[str, set[str]] = {}
    today_models: dict[str, int] = {}
    today = _day(time.time())
    today_prompt_count = 0
    total_prompts = 0
    total_sessions = 0

    for _name, home in profile_roots():
        db = _connect(home)

        if db is None:
            continue

        try:
            # Per-model billed token usage (exact — cache splits included).
            try:
                for model, inp, outp, cr, cw in db.execute(
                    "SELECT model, SUM(input_tokens), SUM(output_tokens), "
                    "SUM(cache_read_tokens), SUM(cache_write_tokens) "
                    "FROM session_model_usage GROUP BY model"
                ):
                    row = model_usage.setdefault(model, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0})
                    row["inputTokens"] += int(inp or 0)
                    row["outputTokens"] += int(outp or 0)
                    row["cacheReadInputTokens"] += int(cr or 0)
                    row["cacheCreationInputTokens"] += int(cw or 0)
            except sqlite3.Error:
                pass  # older schema: leave zeros rather than invent numbers

            # Message counts by day + per-model today token rollup + prompt
            # totals. NOTE: messages has NO model column (models live on
            # sessions / session_model_usage) — join via session_id →
            # sessions.model.
            # Composite review P2.16: today_tokens_by_model used to count
            # PROMPTS (one per user message) while todayTotalTokens summed
            # real token_count — incompatible units in one record. Both are
            # tokens now: token_count summed per session-model, matching
            # todayTotalTokens exactly.
            try:
                for ts, role, model, sid, tcount in db.execute(
                    "SELECT m.timestamp, m.role, s.model, m.session_id, m.token_count "
                    "FROM messages m LEFT JOIN sessions s ON m.session_id = s.id"
                ):
                    d = _day(ts)

                    if d:
                        day_messages[d] = day_messages.get(d, 0) + 1

                        if sid:
                            day_sessions.setdefault(d, set()).add(sid)

                        if d == today:
                            if model:
                                today_models[model] = today_models.get(model, 0) + int(tcount or 0)
                            if role == "user":
                                today_prompt_count += 1

                    if role == "user":
                        total_prompts += 1
            except sqlite3.Error:
                pass

            try:
                total_sessions += int(db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0])
            except sqlite3.Error:
                pass
        finally:
            db.close()

    # todayTotalTokens: tokens billed to models with activity today. The
    # billed table is cumulative, so use messages' token_count for today.
    today_total = 0

    for _name, home in profile_roots():
        db = _connect(home)

        if db is None:
            continue

        try:
            start = _dt.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()

            try:
                for (n,) in db.execute(
                    "SELECT COALESCE(SUM(token_count), 0) FROM messages WHERE timestamp >= ? AND token_count IS NOT NULL",
                    (start,),
                ):
                    today_total += int(n or 0)
            except sqlite3.Error:
                pass
        finally:
            db.close()

    days = sorted(day_messages)
    recent = days[-7:]

    return {
        "schemaVersion": 1,
        "id": "botmarchy",
        "name": "Botmarchy",
        "updatedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "ready": True,
        "hasLocalStats": True,
        "tierLabel": "",
        "usageStatusText": f"{len(profile_roots())} bots" if profile_roots() else "No bots yet",
        "todayPrompts": today_prompt_count,
        "todaySessions": len(day_sessions.get(today, set())),
        "todayTotalTokens": today_total,
        "todayTokensByModel": today_models,
        "recentDays": [{"date": d, "messageCount": day_messages.get(d, 0)} for d in recent],
        "modelUsage": model_usage,
        "totalPrompts": total_prompts,
        "totalSessions": total_sessions,
        "activeDays": len(days),
        "activeDates": days,
    }


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--version", "-V"):
        print(USAGE_VERSION)
        return 0

    print(json.dumps(aggregate(), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
