# Codex review of spec + plan, round 1 (2026-11-04, `97fe0da`)

23 findings; all fixed in the plan except #23 (answered by narrowing the spec). Full review: `.git/codex-reviews/97fe0da6c95098e0e32b6561f344d1ffab4815e7.md` (local).

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | P1 | Global dispatch runs any checkout's `.scaffold/hooks` | User-owned registry `~/.claude/scaffold/repos`; test for unregistered repo (Task 8) |
| 2 | P1 | Committed config is sourced (code execution) | `load_config` parses fixed keys as data, validates values; `EXTRA_PUSH` lines; test with `$(…)` payload (Task 2); refresh uses it too (Task 10) |
| 3 | P1 | Note text injected into SessionStart context | `note_data` prints last, fenced, after a data boundary, backticks stripped; injection-order test (Task 7) |
| 4 | P1 | Shared board uploads uncommitted drafts | Shared mode reads notes from `HEAD` (`committed_notes`); draft-exclusion test (Task 5) |
| 5 | P1 | `git -C dir push` / `cd dir && git push` use hook cwd | `target_dir` in lib; cross-worktree tests (Task 3) |
| 6 | P2 | Installer deletes mixed registrations | Per-command `strip`, empty registrations dropped; mixed-registration test (Task 8) |
| 7 | P2 | Shared gate validates working-tree copy | Validates `HEAD:<note>`; uncommitted-repair test (Task 3) |
| 8 | P2 | Catchup cursor skips truncated pages | Full page resumes from oldest merge day; test (Task 6) |
| 9 | P2 | Merges beyond latest 200 fall back to Now | Union history cache + per-branch lookups for unresolved notes (Task 5) |
| 10 | P2 | CRLF STATUS rewritten | `newline=""` I/O; exact-bytes test (Task 5) |
| 11 | P2 | Migration relative paths after `cd` | Absolute paths; replacement verified before `bootout` (Task 12) |
| 12 | P2 | `git diff` error read as unchanged note | Diff status checked separately, fails open; missing-ref test (Task 3) |
| 13 | P2 | SIGPIPE under pipefail in transcript scan | Collect then match; 10k-line test (Task 2) |
| 14 | P2 | `gh pr create` denied after allowed push | Separate push/pr stamps; lifecycle test (Task 3) |
| 15 | P2 | Any-note exemption on feature branches | Limited to base branch; negative test (Task 4) |
| 16 | P2 | Bash reads header keys beyond 8 lines | `head -n 8` in `header`; body-keys test (Task 2) |
| 17 | P2 | CRLF branch tokens | `\r` stripped/separator; CRLF test (Task 2) |
| 18 | P2 | Deny tests only check reason text | `deny_has` asserts event + `permissionDecision`; mutation (c) (Task 3) |
| 19 | P2 | Timeout test doesn't pin cache fallback | Expired populated cache through `[]`, slow and missing gh (Task 5) |
| 20 | P2 | Exclude path relative in test | `--path-format=absolute` (Task 8); `pwd -P` for macOS `/var` symlink |
| 21 | P2 | plist template can't lint | Lint a substituted copy (Task 10); migration lints before swap |
| 22 | P2 | No viewport in local phone check | Local preview wraps page in the publish skeleton; asserts `innerWidth == 390` (Task 9) |
| 23 | P2 | No pull-time render | Spec success line narrowed to "next session start or manual render" |

# Round 2 (2026-11-04, `184d8bf`)

18 findings (3 P1, 15 P2), all accepted; each became a binding "Round-2 amendments" block in its task (Tasks 1, 2, 3, 5, 6, 7, 8, 10, 11, 12) plus a spec section. P1: committed `EXTRA_PUSH` could upload secrets → push destinations user-owned (`~/.claude/scaffold/pushes`); inbox/note filenames could inject instructions → `safe_text` + inbox inside the data block; `dispatch` checked the session cwd, not the command target → resolve target before registry lookup. P2: atomic STATUS write, one gh deadline, fair branch lookups, base-keyed cache freshness, quote-aware target parsing, HEAD-only shared discovery, compound push+PR stamps, migration jq keeps siblings, refresh never prepends PATH (real `claude` risk), committed-unchanged-note test, per-scenario cache assertions, independent source-checkout marker, unique sentinel, shellcheck source resolution, real catchup pagination.

# Whole-branch review rounds 1–3 (2026-11-05): open follow-ups

- Round 1: 14 findings (5 P1, 8 P2, 1 P3), all fixed in `4f32489`.
- Round 2: 11 findings (4 P1, 7 P2), all fixed in `1239e75`.
- Round 3: 7 findings (2 P1, 5 P2); 4 fixed in the commit that adds this section (scheduled jobs run user-owned copies via `install.sh --job`, symlinked refresh output refused, standalone `render.py` derives mode, refresh publishes only on Claude exit 0), 3 P2 deferred below.

## Nested and escaped quotes lose commands (`lib.sh` `_exec_text`)

Repro: `printf '%s\n' "$(git -C "/path/to/repo" push)"` executes the push, but the parser ends the outer string at the inner `"`, so `cmd_kinds` returns nothing and gate and dispatch allow a note-less feature-branch push; without the inner quotes it is denied. Escaped quoted examples (`echo \"git push\"`) are misclassified as executable pushes. Approach: replace the next-matching-quote split with a small state machine over the command (single quotes literal, double quotes honouring `\` escapes and recursing into `$(…)`/backticks with paren depth), still spawning nothing.

## Only the first gated invocation is validated (`lib.sh` `target_dir`)

Repro: `git -C /allowed push && git -C /other push`: only the first invocation's repo is resolved; if `/allowed` is on the base branch gate exits and the second push from a feature branch with no note is allowed, while that push alone is denied. Approach: have the exec view yield every push/PR invocation with its own `cd`/`-C`/`--git-dir`/`--work-tree` target, and make gate and dispatch decide per invocation (deny if any is denied).

## Completed note disappears when its branch name is reused (`render.py` `split`)

Repro: a `work/completed/` note names a merged branch, then a new PR reuses that branch name: the open-branch exclusion drops its merge association and the completed-directory exclusion drops it from Now, so the task vanishes from both sections although its merge stays cached. Approach: skip the open-branch rule for completed notes (they always pair with their cached merge), and add a test combining a completed note with an open PR on the same branch.
