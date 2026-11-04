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
