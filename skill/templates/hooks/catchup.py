#!/usr/bin/env python3
"""Record merged PRs no work note claims, so non-Claude work still shows in STATUS. No LLM.

Scheduled runs use the user-owned copy `install.sh --job catchup` writes, importing its sibling render.py, never checkout code."""
import datetime
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python3 -I drops the script dir
import render  # noqa: E402

try:
    LIMIT = int(os.environ.get("SCAFFOLD_CATCHUP_LIMIT", "500"))
except ValueError:
    LIMIT = 500
MAX_DAYS = 31
KEEP = 50


def main(root):
    sc = root / ".scaffold"
    state = sc / ".hookstate"
    if not job_allowed(root) or render.state_unsafe(sc):
        return
    state.mkdir(exist_ok=True)
    today = utc_today()
    since = parse_day(read_text(state / "catchup-since").strip()) or today - datetime.timedelta(days=14)
    prs, cursor = fetch(root, max(since, today - datetime.timedelta(days=MAX_DAYS)), today)
    if prs is None:
        return
    claimed = claimed_branches(root, sc)
    entries = {u["number"]: u for u in render.load_json(state / "unclaimed.json", []) if isinstance(u, dict) and "number" in u}
    for p in prs:
        entries[p["number"]] = entry(p)
    keep = sorted((u for u in entries.values() if u["branch"] not in claimed), key=lambda u: u["merged_at"], reverse=True)[:KEEP]
    render.write_atomic(state / "unclaimed.json", json.dumps(keep, indent=1))
    render.write_atomic(state / "catchup-since", cursor.isoformat() + "\n")


def job_allowed(root):
    # A pull can write tracked paths under .scaffold/: act only for a registered, wholly untracked scaffold. Git failure raises.
    if render.git(root, "ls-files", "--", ".scaffold", strict=True).strip():
        return False
    home = Path(os.environ.get("SCAFFOLD_HOME") or Path.home() / ".claude")
    return str(root) in read_text(home / "scaffold" / "repos").splitlines()


def utc_today():
    # SCAFFOLD_TODAY=YYYY-MM-DD is a test seam. GitHub's merged: dates are UTC.
    return parse_day(os.environ.get("SCAFFOLD_TODAY", "")) or datetime.datetime.now(datetime.timezone.utc).date()


def parse_day(text):
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        return None


def fetch(root, first, today):
    # One UTC day per query: search order is not by merge date, so a full page can't be resumed by date. A full day is
    # re-read as 24 hour windows. Cursor = first day with a full hour (or a failure), else today; that day is retried next run.
    seen, cursor, day = {}, None, first
    while day <= today:
        got = page(root, f"merged:{day.isoformat()}")
        if got is None:
            if not seen and cursor is None and day == first:
                return None, first
            return list(seen.values()), cursor or day
        add(seen, got)
        if len(got) >= LIMIT:
            for h in range(24):
                w = f"{day.isoformat()}T{h:02d}"
                hour = page(root, f"merged:{w}:00:00Z..{w}:59:59Z")
                if hour is None:
                    return list(seen.values()), cursor or day
                add(seen, hour)
                if len(hour) >= LIMIT and cursor is None:
                    cursor = day
        day += datetime.timedelta(days=1)
    return list(seen.values()), cursor or today


def page(root, query):
    got = render.gh_json(root, ["pr", "list", "--state", "merged", "--search", query, "--limit", str(LIMIT),
                                "--json", "number,title,headRefName,mergedAt,author"])
    return got if isinstance(got, list) else None


def add(seen, prs):
    seen.update((p["number"], p) for p in prs if isinstance(p, dict) and "number" in p and "headRefName" in p and str(p.get("mergedAt", ""))[:10])


def entry(p):
    author = p.get("author") or {}
    return {"number": p["number"], "title": p.get("title", ""), "branch": p["headRefName"], "merged_at": p["mergedAt"][:10],
            "author": author.get("login", "") if isinstance(author, dict) else ""}


def claimed_branches(root, sc):
    out = set()
    for d in ("active", "queued", "completed"):
        for p in (sc / "work" / d).glob("*.md"):
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out.update(render.read_note(text, str(p.relative_to(root)))["branches"])
    return out


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]).resolve())
    except Exception:  # fail open, like render
        pass
