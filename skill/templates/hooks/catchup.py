#!/usr/bin/env python3
"""Record merged PRs no work note claims, so non-Claude work still shows in STATUS. No LLM."""
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
MAX_PAGES = 10
KEEP = 50


def main(root):
    sc = root / ".scaffold"
    state = sc / ".hookstate"
    state.mkdir(exist_ok=True)
    today = datetime.date.today().isoformat()
    since = read_text(state / "catchup-since").strip() or (datetime.date.today() - datetime.timedelta(days=14)).isoformat()
    prs, complete = fetch(root, since, today)
    if prs is None:
        return
    claimed = claimed_branches(root, sc)
    entries = {u["number"]: u for u in render.load_json(state / "unclaimed.json", []) if isinstance(u, dict) and "number" in u}
    for p in prs:
        entries[p["number"]] = entry(p)
    keep = sorted((u for u in entries.values() if u["branch"] not in claimed), key=lambda u: u["merged_at"], reverse=True)[:KEEP]
    render.write_atomic(state / "unclaimed.json", json.dumps(keep, indent=1))
    if complete:
        render.write_atomic(state / "catchup-since", today + "\n")


def fetch(root, since, until):
    # Date-window paging: a full page re-queries up to its oldest merge day. (None, False) if the first call fails.
    seen = {}
    for page in range(MAX_PAGES):
        got = render.gh_json(root, ["pr", "list", "--state", "merged", "--search", f"merged:{since}..{until}", "--limit", str(LIMIT),
                                    "--json", "number,title,headRefName,mergedAt,author"])
        if not isinstance(got, list):
            return (None, False) if page == 0 else (list(seen.values()), False)
        got = [p for p in got if isinstance(p, dict) and "number" in p and "headRefName" in p and str(p.get("mergedAt", ""))[:10]]
        seen.update((p["number"], p) for p in got)
        if len(got) < LIMIT:
            return list(seen.values()), True
        until = min(p["mergedAt"][:10] for p in got)
    return list(seen.values()), False


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
