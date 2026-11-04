#!/usr/bin/env python3
"""Build .scaffold/STATUS.md and board.json from work-note headers and merged PRs (spec D5, D6, D8)."""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KEYS = ("status", "branch", "waiting-on", "next")
BEGIN, END = "<!-- scaffold:generated -->", "<!-- /scaffold:generated -->"
CACHE_SECONDS = 600
MAX_BRANCH_LOOKUPS = 10
PR_FIELDS = "number,headRefName,mergedAt"


def main(root, base, mode):
    sc = root / ".scaffold"
    state = sc / ".hookstate"
    state.mkdir(parents=True, exist_ok=True)
    notes = committed_notes(root) if mode == "shared" else working_notes(root)
    now, last = split(notes, merged_history(root, state, notes, base), base)
    board = {"base": base_info(root), "now": now, "last_round": last, "unclaimed": load_json(state / "unclaimed.json", [])}
    digest = hashlib.sha256(json.dumps(board, sort_keys=True).encode()).hexdigest()
    stamped = dict(board, generated_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    write_atomic(state / "board.json", json.dumps(stamped, indent=1))
    write_atomic(state / "board.hash", digest + "\n")
    write_status(sc / "STATUS.md", root.name, markdown(board))


def working_notes(root):
    sc = root / ".scaffold"
    return [read_note(p.read_text(errors="replace"), str(p.relative_to(root))) for d in ("active", "queued") for p in sorted((sc / "work" / d).glob("*.md"))]


def committed_notes(root):
    # Everyone mode: only what HEAD carries reaches STATUS and the shared board; drafts stay local.
    listing = git(root, "ls-tree", "-r", "--name-only", "HEAD", "--", ".scaffold/work/active", ".scaffold/work/queued")
    return [read_note(git(root, "show", f"HEAD:{rel}"), rel) for rel in sorted(listing.splitlines()) if rel.endswith(".md")]


def read_note(text, rel):
    head = {}
    for line in text.replace("\r", "").splitlines()[:8]:
        key, _, value = line.partition(":")
        if key in KEYS and key not in head:
            head[key] = value.strip()
    note = {"task": Path(rel).stem, "path": rel}
    note.update({k.replace("-", "_"): head.get(k, "") for k in KEYS})
    note["branches"] = tokens(head.get("branch", ""))
    return note


def tokens(s):
    # Same separators as lib.sh branch_tokens.
    return [t for t in re.split(r"[\s,;()`]+", s) if t]


def split(notes, history, base):
    # The first listed branch decides whether a note is done (stacked PRs list the top branch first).
    now, last = [], []
    for note in notes:
        first = note["branches"][0] if note["branches"] else ""
        pr = history.get(first) if first and first != base else None
        if pr:
            last.append(dict(note, pr=pr["number"], merged_at=str(pr.get("mergedAt", ""))[:10]))
        else:
            now.append(note)
    last.sort(key=lambda n: n["merged_at"], reverse=True)
    return now, last


def merged_history(root, state, notes, base):
    # merged.json = {"base": HEAD sha, "history": {...}}; history only grows, so an old merge that drops out of the recent list stays done.
    cache = state / "merged.json"
    head = git(root, "rev-parse", "HEAD").strip()
    data = load_json(cache, {})
    data = data if isinstance(data, dict) else {}
    history = {k: v for k, v in (data.get("history") or {}).items() if isinstance(v, dict) and "number" in v} if isinstance(data.get("history"), dict) else {}
    if head and data.get("base") == head and cache_age(cache) < CACHE_SECONDS:
        return history
    deadline = time.monotonic() + gh_timeout()
    recent = gh_json(root, ["pr", "list", "--state", "merged", "--limit", "200", "--json", PR_FIELDS], deadline)
    if not isinstance(recent, list):
        return history
    record(history, recent)
    unresolved = []
    for n in notes:
        first = n["branches"][0] if n["branches"] else ""
        if first and first != base and first not in history and first not in unresolved:
            unresolved.append(first)
    lookup_branches(root, state / "lookups.json", history, unresolved, deadline)
    write_atomic(cache, json.dumps({"base": head, "history": history}))
    return history


def lookup_branches(root, path, history, unresolved, deadline):
    # {branch: last_checked_epoch}: oldest first (never checked = 0), so a long unresolved list is covered across runs.
    seen = load_json(path, {})
    seen = seen if isinstance(seen, dict) else {}
    age = lambda b: seen[b] if isinstance(seen.get(b), (int, float)) else 0
    for branch in sorted(unresolved, key=age)[:MAX_BRANCH_LOOKUPS]:
        if time.monotonic() >= deadline:
            break
        found = gh_json(root, ["pr", "list", "--state", "merged", "--head", branch, "--limit", "1", "--json", PR_FIELDS], deadline)
        record(history, [p for p in found or [] if isinstance(p, dict) and p.get("headRefName") == branch])
        seen[branch] = time.time()
    write_atomic(path, json.dumps(seen))


def record(history, prs):
    for pr in prs:
        if isinstance(pr, dict) and "number" in pr and "headRefName" in pr:
            history.setdefault(pr["headRefName"], {"number": pr["number"], "mergedAt": pr.get("mergedAt", "")})


def gh_timeout():
    try:
        return float(os.environ.get("SCAFFOLD_GH_TIMEOUT", "10"))
    except ValueError:
        return 10.0


def gh_json(root, args, deadline=None):
    # deadline is a time.monotonic() value; None = fresh SCAFFOLD_GH_TIMEOUT budget. None result on any failure.
    if deadline is None:
        deadline = time.monotonic() + gh_timeout()
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    try:
        out = subprocess.run(["gh"] + args, cwd=root, capture_output=True, text=True, timeout=remaining, check=True).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def git(root, *args):
    try:
        return subprocess.run(["git", "-C", str(root)] + list(args), capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def base_info(root):
    return {"branch": git(root, "branch", "--show-current").strip(), "commit": git(root, "rev-parse", "--short", "HEAD").strip()}


def load_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def cache_age(path):
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return float("inf")


def markdown(board):
    out = ["## Now", ""]
    out += [f"- **{n['task']}** — {n['status'] or '-'} | waiting: {n['waiting_on'] or '-'} | next: {n['next'] or '-'} (`{n['path']}`)" for n in board["now"]] or ["- (no work in progress)"]
    out += ["", "## Last round", ""]
    out += [f"- {n['merged_at']} **{n['task']}** — #{n['pr']}: {n['status'] or '-'}" for n in board["last_round"][:20]] or ["- (nothing merged yet)"]
    if board["unclaimed"]:
        out += ["", "## Merged without a work note", ""]
        out += [f"- {u['merged_at']} #{u['number']} {u['title']} ({u['author']})" for u in board["unclaimed"][:30]]
    return "\n".join(out)


def write_status(path, project, body):
    # newline="" keeps hand-written CRLF sections byte-for-byte.
    block = f"{BEGIN}\n_Generated {time.strftime('%Y-%m-%d %H:%M')} from work notes; edit the notes, not this block._\n\n{body}\n{END}"
    if path.exists():
        with open(path, newline="", encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
    else:
        text = f"# STATUS.md — {project}\n\n{BEGIN}\n{END}\n"
    if BEGIN in text and END in text:
        pre, rest = text.split(BEGIN, 1)
        text = pre + block + rest.split(END, 1)[1]
    else:
        text = text.rstrip("\r\n") + "\n\n" + block + "\n"
    write_atomic(path, text)


def write_atomic(path, text):
    # Temp file in the same directory + os.replace: readers never see a partial file; existing mode is kept.
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError:
        mode = 0o644
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, newline="", encoding="utf-8", errors="surrogateescape") as f:
        tmp = f.name
        try:
            f.write(text)
        except BaseException:
            f.close()
            os.unlink(tmp)
            raise
    os.chmod(tmp, mode)
    os.replace(tmp, path)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), sys.argv[2] if len(sys.argv) > 2 else "main", sys.argv[3] if len(sys.argv) > 3 else "local")
