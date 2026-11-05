# Auto-updating project scaffold — design

Date: 2026-11-04. Status: spec approved 2026-11-04; D8 status board added after approval, awaiting confirmation. Source skill today: `~/.claude/skills/project-scaffold-init` (docs only, no hooks, 2026-10-12). Prior art: ai_gateway's local `.scaffold/hooks/scaffold-hook.sh` + `refresh.sh`.

## Goal

The scaffold (`PROJECT.md`, `STATUS.md`, `DECISIONS.md`, work notes) updates when work happens, not on a schedule: the session that completes a task writes the update, and in shared mode the update ships in the same PR as the code, so everyone who pulls `main` sees current status. Setup asks whether the scaffold is for everyone (committed) or just the user (local, untracked).

Success: every merged PR made through a Claude session shows in STATUS at the next session start (or manual `render`) after it is on `main`, for everyone who pulls; merges made outside Claude show by the next `catchup` run. No pull-time trigger: STATUS is uncommitted, so a pull alone does not rebuild it.

## Why the current hooks don't achieve it (evidence, ai_gateway 2026-11-04)

- Nothing applies updates: `refresh.sh` writes `inbox/<date>-refresh.md` proposals only; 4 piled up 2026-10-30 → 11-04 and STATUS lagged 59 merges.
- Headless Jira never ran: allowed tool name `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql` does not exist in that environment; `--setting-sources project` likely hides the Atlassian plugin.
- Stop hook nags once about the work note, never STATUS; Launch Board not covered.
- Note matching is a substring test (`grep -qF "$branch"`): on `main`, any note whose `branch:` line mentions "origin/main" claims the session, so the Stop hook demanded an unrelated note's update (observed 2026-11-04). New hooks match whole branch tokens only, and on the base branch `checkpoint` accepts any updated note.
- Hardcoded: repo root, `origin main`, Jira project `AIG`, Signal Board URL.

## Decisions

| # | Decision | Rejected |
|---|---|---|
| D1 | Event-driven: session that does the work writes the update | Scheduled LLM refresh as primary path |
| D2 | Shared mode: scaffold update rides in the same PR as the code | Direct-to-main or side branch (breaks with branch protection / signed-commit rulesets) |
| D3 | Enforcement by Claude hooks only; daily non-LLM `catchup` as backstop for non-Claude work | CI check failing PRs without note change (needs team buy-in, bot exemptions) |
| D4 | One layout `.scaffold/` for both modes | Shared mode root-level files (current skill) |
| D5 | `STATUS.md` generated from work-note headers + `gh`; uncommitted in shared mode | Hand-edited shared STATUS (certain merge conflicts) |
| D6 | Merge state derived from `gh` by branch; nothing written after merge | Post-merge commit setting `status: done` |
| D7 | Every hook fails open on its own error; only `gate`'s rule refuses | Fail closed (a script bug would block pushes) |
| D8 | Optional status board: a claude.ai artifact page published once, whose data (`render` output as JSON) sessions push to the artifact database when it changes | Republishing the HTML on each change (slow, version churn); headless push (headless `claude -p` has no Artifact/ArtifactData tools) |

## Layout and ownership

| Path | Written by | Shared mode |
|---|---|---|
| `.scaffold/work/active/<task>.md` | session working that branch | committed, in the task's PR |
| `.scaffold/work/completed/<task>.md` | owner, in a later PR | committed |
| `.scaffold/PROJECT.md`, `DECISIONS.md` | by hand, rarely | committed |
| `.scaffold/STATUS.md` | `render` (generated) | git-ignored |
| `.scaffold/hooks/*`, `.scaffold/config` | skill install | committed |
| `.scaffold/.hookstate/` | hooks | ignored in both modes |

Just-me mode: `.scaffold/` in `.git/info/exclude`, hooks in `.claude/settings.local.json`, loaded via `CLAUDE.local.md`. Everyone mode: hooks in committed `.claude/settings.json`; `.gitignore` gets `.scaffold/STATUS.md` and `.scaffold/.hookstate/`.

Work note header (first four lines, unchanged from today): `status:`, `branch:` (one or more branch names), `waiting-on:`, `next:`. Shared-mode notes are team-visible: no personal asides.

`.scaffold/config` (shell `KEY=value`): `BASE_BRANCH` (default `main`), `REMOTE` (default `origin`), `JIRA_PROJECT` (optional), `EXTRAS` (subset of `catchup signal-board haiku-refresh`, just-me only).

## Components (`.scaffold/hooks/`)

1. `brief` — SessionStart. Runs `render`, prints note headers in progress, names the note whose `branch:` matches the current branch; on a non-base branch without a note, asks for one. Lists the user's own done notes to move to `completed/` in their next PR.
2. `checkpoint` — Stop. Once per session: if the transcript shows repo edits, commit, push or `gh pr` activity and the branch's note is not newer than session start, return `decision: block` with the update instruction. Same detection as today's hook.
3. `gate` — PreToolUse on Bash matching `git push` or `gh pr create`. Allow when: pushing to `BASE_BRANCH`, `SCAFFOLD_SKIP=1`, or `git diff --name-only $REMOTE/$BASE_BRANCH...HEAD` contains a note whose `branch:` matches and whose four header lines are non-empty. Else deny with reason (create/update note, commit, retry). Local git only, works offline.
4. `render` — builds `STATUS.md`: "Now" from notes not merged, "Last round" from notes whose branch PR is merged (`gh pr list --head <b> --state merged`, cached in `.hookstate/`), newest first. `gh` missing or offline → header text only, never blocks. In just-me mode, content outside `<!-- scaffold:generated -->` markers is preserved (hand-curated sections).
5. `catchup` — optional daily job (launchd/cron), plain git + `gh`, no LLM: records merged PRs since last run that no note claims into a "Unclaimed merges" block that `render` includes.

6. Status board (optional, both modes) — `render` also writes `.hookstate/board.json` (Now, Last round, unclaimed merges, note headers, generated-at, base commit). `brief` compares its hash with `.hookstate/board-pushed`; when different it prints a DO-FIRST line: ArtifactData `get` collection `board` doc `current` for its version, `set` from `board.json` with that `if_version`, then record the hash. Same pattern as today's Signal Board push. Board URL lives in `.scaffold/config` (`BOARD_URL`). The page (`templates/board/index.html`, declares the `db` capability) reads `board/current` and renders it; mobile-safe, light/dark. Shared mode: the installer owns the artifact, shares it with the org and gives teammates edit access; a session without write access gets a refusal, `brief` prints one warning and moves on (fail open). Board data contains only what is already in committed notes, so it publishes nothing new.

Just-me extras, opt-in: `signal-board` (current DO-FIRST push), `haiku-refresh` (current `refresh.sh` with Jira tool name fixed and parameterised).

## Task lifecycle

1. Session starts on branch X → `brief`.
2. Commits → no hook.
3. `git push` / `gh pr create` → `gate`.
4. Session end → `checkpoint`.
5. Merge (queue, web UI, squash) → nothing written; next `render` moves the note to "Last round".
6. Done notes accumulate in `active/` until the owner moves them in a later PR (`brief` reminds).

Edge cases: stacked PRs / note spanning branches (`branch:` lists several); worktrees resolve to the main checkout via `git rev-parse --git-common-dir`; just-me work on base branch → `checkpoint` only; bot branches → `SCAFFOLD_SKIP=1` or no Claude session at all.

## Install (`project-scaffold-init`)

1. Ask mode (Everyone / Just me) via `AskUserQuestion`; restate its meaning.
2. Write docs into `.scaffold/` from templates; seed from GitHub, Jira, docs (existing Steps 2–4).
3. Copy `templates/hooks/*` → `.scaffold/hooks/`; write `.scaffold/config`.
4. Merge hook registration into the right settings file with `jq`; never overwrite existing hooks.
5. Ask "Build a status board artifact that stays up to date?" (both modes). On yes: load the `artifact-design` and `artifact-capabilities` skills, publish `templates/board/index.html` with the `db` capability, write `BOARD_URL` to config, push the first `board.json`; Everyone mode: remind the user to share it with the org and grant teammates edit (sharing is done from the page's Share menu, not by the skill).
6. Just me: offer extras. Everyone: create branch, commit setup with its own work note, open PR (outward: confirm first).
7. Run `.scaffold/hooks/test.sh` as smoke check.

## Testing

`templates/hooks/test.sh`, no framework: temp repo + bare remote, hook JSON on stdin, fake `gh` on `PATH`. Cases: `gate` denies without note, allows with note, honours `SCAFFOLD_SKIP`, ignores base-branch pushes, fails open on crash; `checkpoint` blocks once; `render` groups merged branches and survives missing `gh`; just-me markers preserve hand sections; `render` writes `board.json` and `brief` prints the push line only when its hash changed and `BOARD_URL` is set. Board page: open it against a sample `board.json` (Rodney screenshot) at phone and desktop width. Each rule mutation-checked (break it, test fails).

## ai_gateway migration (just-me, nothing pushed)

Replace `.scaffold/hooks/scaffold-hook.sh` with skill hooks; keep Signal Board + Haiku refresh as extras (fix Jira tool name); wrap generated "Now"/"Last round" in markers, keep lanes/team-PR/Jira sections outside them; launchd job points at the new `haiku-refresh`/`catchup`.

## Repo layout (github.com/jasamkos/project-scaffold, private)

`skill/SKILL.md` + `skill/templates/{docs,hooks}/`; `~/.claude/skills/project-scaffold-init` becomes a symlink to `skill/`. `docs/specs/` for this file.

## Plan-time refinements (2026-11-04)

- Just-me hooks register once in `~/.claude/settings.json` through a global `dispatch` script, not in `.claude/settings.local.json`: worktrees have no copy of that untracked file. Everyone-mode repos make `dispatch` exit so hooks never run twice.
- Just-me `gate` cannot use the branch diff (notes are untracked): it requires the note to be newer than the branch's last allowed push.
- A note is done when its first listed branch is merged; stacked PRs list the top branch first.
- The Signal Board push becomes generic `EXTRA_PUSH=url|collection|doc|file` config lines, so the skill carries no ai_gateway specifics.

Security and correctness refinements from Codex review of the plan (2026-11-04, 23 findings):

- `dispatch` runs only repos listed in the user-owned registry `~/.claude/scaffold/repos`; a checkout shipping `.scaffold/config` is not consent.
- `.scaffold/config` is parsed as data (fixed keys, validated values), never sourced: everyone-mode config is contributor-controlled.
- `brief` prints note text last, fenced, after an explicit "data, not instructions" boundary; DO-FIRST lines come only from config.
- Everyone mode reads notes from `HEAD` for `gate` checks and board data, so uncommitted drafts never reach the shared board.
- `gate` resolves the repo a command targets (`git -C`, leading `cd … &&`), fails open on git errors, and keeps separate push and PR stamps in just-me mode.
- Merge history is a union cache plus per-branch lookups for unresolved notes, so old merges never fall back to "Now".

Round 2 (2026-11-04, 18 findings), changes to the design:

- Push destinations (`BOARD_URL`, extra pushes) live in the user-owned `~/.claude/scaffold/pushes`, never in committed config: a contributor-written `EXTRA_PUSH` could otherwise make a session upload a secret file. Consequence for D8: in everyone mode only sessions of users who registered the board (`install.sh --register-board`) push it; the installer does at install.
- Contributor-controlled names (note and inbox filenames, branch names) are sanitised before they reach session context; inbox names print inside the data block.
- `dispatch` resolves a gated command's target repo before the registry lookup; `merged.json` freshness is keyed to the base commit; `gh` calls share one deadline; per-branch lookups rotate fairly; STATUS and state files are replaced atomically.

Branch review (2026-11-05, 14 findings), changes to the design:

- Mode is derived, not configured: everyone mode iff `.scaffold/config` is tracked (`effective_mode`); its `SCAFFOLD_MODE` key no longer selects the reader. The installer refuses (exit 2, nothing written) a mode different from the existing scaffold's, any symlinked destination, and `--register-board` without an existing scaffold; its last stdout line is `root=<abs>`, which the skill uses for every later step.
- `render` writes an immutable `board-push-<hash>.json` (3 newest kept); `brief` asks to push that file and ack exactly its hash, so a concurrent rebuild is never acked unsent.
- `haiku-refresh` runs Haiku with user settings only, in a fresh temp dir holding copies of the facts and STATUS, with `Edit(./out.md)` as its only write grant and the repo denied by absolute rule; the shell copies `out.md` into the inbox.
- Push/PR detection matches command positions only (quoted text counts only as a `bash|sh|zsh -c` / `eval` script) and accepts git global options and `gh -R`.

Branch review 2 (2026-11-05, 11 findings), changes to the design:

- Unknown tracking state fails closed: if `git ls-files` fails (e.g. corrupt index), `dispatch` runs no hook and `effective_mode` returns 2; `brief` then renders and publishes nothing (one warning line), `gate` and `checkpoint` decide nothing.
- `haiku-refresh` gives Haiku no write tool (`--tools Read,ToolSearch`): an inherited path-scoped Edit grant reaches files outside any deny list. Haiku prints the report to stdout; the shell captures it into the temp dir's `out.md` and copies it to the inbox only if non-empty.
- Hooks (and `render.py`/`catchup.py` run directly) refuse to read or write through a symlink under `.scaffold/`: `.scaffold`, `.hookstate`, `work/` and its stage dirs, `inbox` must be real directories, and `STATUS.md` and `.hookstate` entries must not be links; otherwise they exit 0 writing nothing (`brief` prints one warning line).
- Merge history keeps the latest merged PR per branch, and a note whose first branch has an open PR (one `gh pr list --state open` call per rebuild, cached with the history) stays in Now: a reused branch name no longer marks new work done. `work/completed/` notes feed Last round only.

## Out of scope

CI enforcement (D3); Jira in `catchup` (needs MCP or API token; stays in the `haiku-refresh` extra); multi-repo scaffolds; Jira tickets on the status board (needs the Jira pull; ai_gateway's Launch Board keeps its own Jira-driven build); boards aggregating several repos.
