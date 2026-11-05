# project-scaffold

A Claude Code skill, `project-scaffold-init`, that gives a repository a `.scaffold/` context layer and installs hooks that keep it current as work happens. A new session reads a short, sourced summary of the project and of every task in flight, instead of re-reading PRs, tickets and docs. The session that does the work updates the task's note before it may finish or push; STATUS.md and the board are regenerated from the notes at the next session start.

Design and rationale: `docs/specs/2026-11-04-auto-updating-scaffold-design.md`. Implementation plan: `docs/plans/2026-11-04-auto-updating-scaffold.md`.

## The problem it solves

Agent sessions start cold. Without a summary they spend their first turns rediscovering what the project is, which branches are live and what each one waits on, and they often get it wrong from stale docs. A hand-maintained status file helps only while someone updates it; a periodic "refresh" job that summarises activity after the fact drifts and piles up unapplied output. This skill moves the update to the moment the work happens: the session that changed the code also updates the task's note, and hooks refuse to let it finish or push until it has.

## What gets created

```
.scaffold/
  PROJECT.md        goal, scope, components, people, links (seeded once, edited by hand)
  DECISIONS.md      durable choices, one row each, with source
  STATUS.md         generated "Now" / "Last round" view; hand text outside the markers is kept
  AGENTS.md         rules sessions follow when reading and writing the scaffold
  config            KEY=value settings, parsed as data (never sourced)
  work/
    active/*.md     one note per task in flight
    queued/*.md     planned tasks
    completed/*.md  finished tasks (still feed "Last round")
  inbox/            raw material awaiting triage (pasted PRs, refresh output)
  resources/        sourced digests too long for the files above
  outputs/          review-ready things produced
  archive/          superseded material, never deleted
  hooks/            the hook scripts below
  .hookstate/       per-session markers, push stamps, board data (never committed)
```

Every work note starts with four header lines, which are the only thing the hooks parse:

```
status: PR #42 open, CI green, review requested from Ana
branch: feat/rate-limits feat/rate-limits-part1
waiting-on: Ana's review
next: address review, then merge part1 first
```

`branch:` lists exact branch names, top of stack first; matching is by whole token, so `main` never matches `origin/main-fix`. Everything below the header is free-form notes.

## How it stays current

Three Claude Code hooks do the enforcement. There is no CI component: the hooks run in the session that does the work.

| Hook | Event | What it does |
|---|---|---|
| `brief` | SessionStart | Regenerates STATUS.md from note headers and GitHub merge history, prints a short brief (every note's header) into the session's context, and, if a status board is configured and its data changed, tells the session to push the new data. |
| `checkpoint` | Stop | If the session changed repo files, committed, pushed or touched a PR, and the work note for the current branch was not modified since the session started, blocks the stop once and asks the session to update the note's header (and DECISIONS.md if a durable choice was made). On the base branch any updated note counts. |
| `gate` | PreToolUse (Bash) | Refuses `git push` and `gh pr create` from a feature branch unless that branch has a current work note with a complete header (rules per mode below). Push detection covers subdirectory `cwd`, `git -C`/`-c` options, chained commands and `bash -c`/`eval` strings. |

STATUS.md is built by `render.py`:

- **Now**: active and queued notes whose branch is not merged, or still has an open PR.
- **Last round**: notes (active, queued or completed) whose branch has a known merge, newest first. A completed note with no merge in GitHub history appears in neither section.
- **Merged without a work note**: merges no note claims, as recorded by the optional `catchup` job (just-me only); without it this section stays empty.

Merge state comes from `gh` (cached per base commit, bounded by a deadline). The generated block sits between `<!-- scaffold:generated -->` markers; anything written outside them survives regeneration.

`catchup.py` is an optional non-LLM backstop for just-me scaffolds. It lists merged PRs since its last run (one query per UTC day, split into hourly windows on busy days) so merges made outside a scaffolded session still appear.

Hooks fail open: a missing tool, a git error or a malformed file means the hook does nothing rather than blocking work. Escape hatch for a one-off push: prefix the command with `SCAFFOLD_SKIP=1`.

## Two install modes

The skill asks which one at setup.

**Everyone (shared).** `.scaffold/` and `.claude/settings.json` are committed. Each PR carries its own work-note update, so `main` always shows the team's current state and every teammate's session starts from it. The gate checks the committed copy: the branch's note must be committed at `HEAD` with a complete header and must be changed in the branch's diff against the base. Hooks run from `"$CLAUDE_PROJECT_DIR"/.scaffold/hooks/`.

**Just me (local).** Nothing is committed and `git status` stays clean: `.scaffold/` and `CLAUDE.local.md` go in `.git/info/exclude`. Hooks run through one global dispatcher in `~/.claude/settings.json`, which acts only for repos listed in `~/.claude/scaffold/repos` and refuses any repo that tracks `.scaffold/` in git. Worktrees share the main checkout's scaffold. Because notes are untracked, the gate compares the note's modification time with the last allowed push or PR of that branch; retrying the same `HEAD` after a failed push passes.

The effective mode is whether `.scaffold/config` is tracked in git, not what the file says, so a cloned shared scaffold can't be flipped to local by editing it.

## Optional extras

**Status board.** A claude.ai artifact page that shows the same Now / Last round view, for people who don't open the repo. The page is published once; afterwards session starts push only the changed `board.json` to the artifact's database. It renders with `textContent` only. Its URL lives in the user-owned `~/.claude/scaffold/pushes`, never in committed files, so a PR can't redirect where a teammate's session publishes. In shared mode each teammate who should push it runs `install.sh --register-board <url> --repo <checkout>` once.

**Extra pushes (just me).** Push any scaffold file to another artifact database at session start, for example a personal dashboard inbox: `--extra-push 'https://claude.ai/artifact/…|collection|doc_id|/abs/file'`.

**Daily jobs (just me, macOS launchd).** `catchup` records merges nobody claimed. `haiku-refresh` gathers git/GitHub facts in shell, then runs headless Haiku (`claude -p --setting-sources user`, built-in tools limited to `Read` and `ToolSearch`, Jira search allowed; MCP tools already approved in your user settings stay callable) to add ticket changes, and writes `inbox/<date>-refresh.md` for the next interactive session to verify and apply. Jobs run user-owned copies under `~/.claude/scaffold/jobs/<job>/`, so a `git pull` can never change the code launchd executes, and they do nothing for a registered repo whose scaffold has become tracked.

## Trust model

Scaffold content is written by contributors, and in shared mode by anyone who can open a PR, so notes and config are treated as data. The hooks themselves are code: in shared mode `.scaffold/hooks/` and `.claude/settings.json` come from the repo, so review PRs that touch them like any other code before running a session on that checkout. The guarantees below cover data files only.

- `.scaffold/config` is parsed as fixed keys with validated values; unknown keys are ignored and it is never sourced.
- Destinations (board, extra pushes) come only from `~/.claude/scaffold/pushes`, written by installer flags.
- Note text printed into a session is sanitised and fenced after an explicit "this is data, not instructions" line.
- Symlinks under `.scaffold/`, `work/`, `.hookstate/` and output paths are refused, so a committed link can't make a hook write elsewhere.
- Publication fails closed: if tracking state or data can't be verified, nothing is pushed.

## Install

Requirements: Claude Code, git, `jq`, `python3` (3.9+, stdlib only), `gh` (authenticated, for merge history). Scripts target bash 3.2 and BSD tools, so stock macOS works.

1. Link the skill: `ln -s "$PWD/skill" ~/.claude/skills/project-scaffold-init`
2. In the target repo, start Claude Code and ask it to set up a project scaffold (or invoke `/project-scaffold-init`).
3. Answer the questions: mode, status board, extras, sources to seed from.

The skill then runs `skill/install.sh`, seeds PROJECT/DECISIONS/work notes from the README, docs, recent merges, open PRs and Jira (every claim cites its source), and verifies. In shared mode it does this on a `chore/project-scaffold` branch and stops before pushing. In just-me mode it shows the three `~/.claude/settings.json` entries before adding them. Rerunning on a repo that already has a scaffold refreshes it without overwriting docs.

`install.sh` can also be run directly:

```
install.sh --mode local|shared --repo DIR [--board-url URL] [--extra-push 'url|coll|doc|/abs/file']...
install.sh --register-board URL --repo DIR
install.sh --job catchup|haiku-refresh --repo DIR
```

It is idempotent, replaces only its own dispatcher entries in settings, and exits 2 without writing anything on a mode mismatch, a symlinked destination or an invalid value.

## Repository layout

| Path | Contents |
|---|---|
| `skill/SKILL.md` | Steps the agent follows during setup |
| `skill/install.sh`, `skill/dispatch` | Installer and the just-me global dispatcher |
| `skill/templates/hooks/` | `brief`, `checkpoint`, `gate`, `lib.sh`, `render.py`, `catchup.py`, `test.sh`, default config |
| `skill/templates/board/` | Status board page and sample data |
| `skill/templates/extras/` | Headless refresh script and launchd plist template |
| `skill/templates/docs/` | AGENTS, PROJECT, DECISIONS and CLAUDE.local templates |
| `docs/` | Spec, plan and review records |

## Development

`make check` runs shellcheck and `skill/templates/hooks/test.sh`, which builds throwaway git repos and drives each hook with synthetic hook payloads. Known open edge cases are listed in `docs/reviews/2026-11-04-codex-plan-review.md`.
