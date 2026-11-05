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
WORK_DIRS = ("active", "queued", "completed")


def main(root, base, mode):
    if mode not in ("local", "shared"):
        return  # fail closed: an unknown mode must not read drafts
    sc = root / ".scaffold"
    state = sc / ".hookstate"
    if state_unsafe(sc):
        return
    state.mkdir(parents=True, exist_ok=True)
    notes = working_notes(root) if mode == "local" else committed_notes(root)  # raises on git failure: nothing replaced
    history, open_branches = merged_history(root, state, notes, base)
    now, last = split(notes, history, open_branches, base)
    board = {"base": base_info(root), "now": now, "last_round": last, "unclaimed": load_json(state / "unclaimed.json", [])}
    digest = hashlib.sha256(json.dumps(board, sort_keys=True).encode()).hexdigest()
    stamped = dict(board, generated_at=time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    payload = json.dumps(stamped, indent=1)
    write_atomic(state / "board.json", payload)
    snapshot(state, digest, payload)
    write_atomic(state / "board.hash", digest + "\n")
    write_status(sc / "STATUS.md", root.name, markdown(board))


def snapshot(state, digest, payload):
    # Immutable per-hash board copy that brief asks to push and ack: a concurrent rebuild cannot change what is acked.
    # Written here, not in brief, so name and content come from one computation. Keeps the 3 newest.
    snap = state / ("board-push-%s.json" % digest)
    if snap.exists():
        os.utime(snap)
    else:
        write_atomic(snap, payload)
    try:
        old = sorted(state.glob("board-push-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[3:]
        for p in old:
            if p != snap:
                p.unlink()
    except OSError:
        pass  # a concurrent session pruned first


def effective_mode(root):
    # Same rule as lib.sh effective_mode: a tracked config is everyone mode. Git failure raises, so nothing is written.
    return "shared" if git(root, "ls-files", "--", ".scaffold/config", strict=True).strip() else "local"


def state_unsafe(sc):
    # Force-added symlinks survive .gitignore: never read or write through one under .scaffold/ (same list as lib.sh state_safe).
    for d in ("", ".hookstate", "work", "work/active", "work/queued", "work/completed", "inbox"):
        p = sc / d
        if p.is_symlink() or (p.exists() and not p.is_dir()):
            return True
    hs = sc / ".hookstate"
    return (sc / "STATUS.md").is_symlink() or (hs.is_dir() and any(p.is_symlink() for p in hs.iterdir()))


def working_notes(root):
    sc = root / ".scaffold"
    notes = []
    for d in WORK_DIRS:
        for p in sorted((sc / "work" / d).glob("*.md")):
            try:
                notes.append(read_note(p.read_text(encoding="utf-8", errors="replace"), str(p.relative_to(root))))
            except OSError:
                continue
    return notes


def committed_notes(root):
    # Everyone mode: only what HEAD carries reaches STATUS and the shared board; drafts stay local.
    listing = git(root, "ls-tree", "-r", "-z", "--name-only", "HEAD", "--", *(".scaffold/work/" + d for d in WORK_DIRS), strict=True)
    return [read_note(git(root, "show", f"HEAD:{rel}", strict=True), rel) for rel in sorted(listing.split("\0")) if rel.endswith(".md")]


def read_note(text, rel):
    head = {}
    for line in text.replace("\r", "").split("\n")[:8]:  # not splitlines(): bash head -n 8 splits on \n only
        key, _, value = line.partition(":")
        if key in KEYS and key not in head:
            head[key] = value.strip(" \t\n\v\f\r")
    note = {"task": Path(rel).stem, "path": rel}
    note.update({k.replace("-", "_"): head.get(k, "") for k in KEYS})
    note["branches"] = tokens(head.get("branch", ""))
    return note


def tokens(s):
    # Same separators as lib.sh branch_tokens.
    return [t for t in re.split(r"[ \t\r,;()`]+", s) if t]


def split(notes, history, open_branches, base):
    # The first listed branch decides whether a note is done (stacked PRs list the top branch first); an open PR on it
    # means the branch name was reused for new work. Completed notes only feed Last round.
    now, last = [], []
    for note in notes:
        first = note["branches"][0] if note["branches"] else ""
        pr = history.get(first) if first and first != base and first not in open_branches else None
        if pr:
            last.append(dict(note, pr=pr["number"], merged_at=str(pr.get("mergedAt", ""))[:10]))
        elif not note["path"].startswith(".scaffold/work/completed/"):
            now.append(note)
    last.sort(key=lambda n: n["merged_at"], reverse=True)
    return now, last


def merged_history(root, state, notes, base):
    # merged.json = {"base": HEAD sha, "history": {...}, "open": [branch, ...]}; history only grows, so an old merge that
    # drops out of the recent list stays done. Returns (history, open-PR branches); a failed open-PR call keeps the cached set.
    cache = state / "merged.json"
    head = git(root, "rev-parse", "HEAD").strip()
    data = load_json(cache, {})
    data = data if isinstance(data, dict) else {}
    history = {k: v for k, v in (data.get("history") or {}).items() if isinstance(v, dict) and "number" in v} if isinstance(data.get("history"), dict) else {}
    open_branches = {b for b in data.get("open") or [] if isinstance(b, str)} if isinstance(data.get("open"), list) else set()
    if head and data.get("base") == head and cache_age(cache) < CACHE_SECONDS:
        return history, open_branches
    deadline = time.monotonic() + gh_timeout()
    recent = gh_json(root, ["pr", "list", "--state", "merged", "--limit", "200", "--json", PR_FIELDS], deadline)
    if not isinstance(recent, list):
        return history, open_branches
    record(history, recent)
    found = gh_json(root, ["pr", "list", "--state", "open", "--limit", "200", "--json", "headRefName,number"], deadline)
    if isinstance(found, list):
        open_branches = {p["headRefName"] for p in found if isinstance(p, dict) and isinstance(p.get("headRefName"), str)}
    unresolved = []
    for n in notes:
        first = n["branches"][0] if n["branches"] else ""
        if first and first != base and first not in history and first not in unresolved:
            unresolved.append(first)
    lookup_branches(root, state / "lookups.json", history, unresolved, deadline)
    write_atomic(cache, json.dumps({"base": head, "history": history, "open": sorted(open_branches)}))
    return history, open_branches


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
    # Latest merge per branch: a reused branch name reports its newest PR.
    for pr in prs:
        if isinstance(pr, dict) and "number" in pr and "headRefName" in pr:
            cur = history.get(pr["headRefName"])
            if cur is None or str(pr.get("mergedAt", "")) > str(cur.get("mergedAt", "")):
                history[pr["headRefName"]] = {"number": pr["number"], "mergedAt": pr.get("mergedAt", "")}


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
        out = subprocess.run(["gh"] + args, cwd=root, capture_output=True, timeout=remaining, check=True).stdout
        return json.loads(out.decode("utf-8", errors="replace"))
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def git(root, *args, strict=False):
    # strict: any failure raises, so a partial committed-tree read never replaces STATUS or the board.
    try:
        res = subprocess.run(["git", "-C", str(root)] + list(args), capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        if strict:
            raise
        return ""
    if strict and res.returncode != 0:
        raise RuntimeError("git %s failed" % args[0])
    return res.stdout.decode("utf-8", errors="replace")


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
    out += [f"- **{c(n['task'])}** — {c(n['status'])} | waiting: {c(n['waiting_on'])} | next: {c(n['next'])} (`{c(n['path'])}`)" for n in board["now"]] or ["- (no work in progress)"]
    out += ["", "## Last round", ""]
    out += [f"- {c(n['merged_at'])} **{c(n['task'])}** — #{c(n['pr'])}: {c(n['status'])}" for n in board["last_round"][:20]] or ["- (nothing merged yet)"]
    if board["unclaimed"]:
        out += ["", "## Merged without a work note", ""]
        out += [f"- {c(u.get('merged_at'))} #{c(u.get('number'))} {c(u.get('title'))} ({c(u.get('author'))})" for u in board["unclaimed"][:30]]
    return "\n".join(out)


def c(value):
    # Note text is untrusted: one line, and no "<!--" so it can never form a generated-block marker.
    return " ".join(str(value if value is not None else "").split()).replace("<!--", "<! --") or "-"


def write_status(path, project, body):
    # newline="" keeps hand-written CRLF sections byte-for-byte.
    block = f"{BEGIN}\n_Generated {time.strftime('%Y-%m-%d %H:%M')} from work notes; edit the notes, not this block._\n\n{body}\n{END}"
    if path.exists():
        with open(path, newline="", encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
    else:
        text = f"# STATUS.md — {project}\n\n{BEGIN}\n{END}\n"
    # Innermost BEGIN..END pair; a stray marker elsewhere is left alone and a fresh block is appended.
    pair = re.search(re.escape(BEGIN) + "(?:(?!" + re.escape(BEGIN) + ").)*?" + re.escape(END), text, re.S)
    if pair:
        text = text[: pair.start()] + block + text[pair.end():]
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
    try:
        root = Path(sys.argv[1]).resolve()
        main(root, sys.argv[2] if len(sys.argv) > 2 else "main", sys.argv[3] if len(sys.argv) > 3 else effective_mode(root))
    except Exception:  # hooks fail open; atomic writes leave no partial file
        pass
