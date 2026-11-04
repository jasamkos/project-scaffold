# shellcheck shell=bash
# Shared by scaffold hooks; sourced, never run. Hooks fail open, so helpers return non-zero instead of exiting.

# Root whose .scaffold/ serves DIR: the checkout itself (everyone mode, committed) or, for a just-me scaffold
# seen from a worktree, the main checkout found through git's common dir.
scaffold_root() {
  local top common
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$top/.scaffold/config" ] && { echo "$top"; return 0; }
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -f "${common%/.git}/.scaffold/config" ] && { echo "${common%/.git}"; return 0; }
  return 1
}

# Config is contributor-controlled in everyone mode: parse known keys as literal data, never source it.
# Callers may run under `set -e`: `[[ ]] &&` stays inside case arms and the function ends with a succeeding command.
load_config() {
  SCAFFOLD_MODE=local BASE_BRANCH=main REMOTE=origin BOARD_URL="" JIRA_PROJECT="" EXTRA_PUSHES=""
  JIRA_TOOL=mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql
  local key value
  while IFS='=' read -r key value; do
    value=${value%$'\r'}; value=${value#\"}; value=${value%\"}
    case $key in
      SCAFFOLD_MODE) case $value in local | shared) SCAFFOLD_MODE=$value ;; esac ;;
      BASE_BRANCH | REMOTE | JIRA_PROJECT | JIRA_TOOL) [[ $value =~ ^[A-Za-z0-9._/-]+$ ]] && printf -v "$key" '%s' "$value" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$1/.scaffold/config" 2>/dev/null)
  SC=$1/.scaffold STATE=$1/.scaffold/.hookstate
  export SCAFFOLD_MODE BASE_BRANCH REMOTE BOARD_URL JIRA_PROJECT JIRA_TOOL EXTRA_PUSHES SC STATE
}

# Push destinations live in a user-owned file, never in the repo: <root>|board|<url> or <root>|extra|<url>|<collection>|<doc>|<file>.
load_pushes() {
  BOARD_URL="" EXTRA_PUSHES=""
  local root kind a b c d entry f=${SCAFFOLD_HOME:-$HOME/.claude}/scaffold/pushes
  [ -r "$f" ] || return 0
  while IFS='|' read -r root kind a b c d; do
    [ "$root" = "$1" ] || continue
    d=${d%$'\r'}; a=${a%$'\r'}
    case $kind in
      board) [ -z "$BOARD_URL" ] && [[ $a =~ ^https://claude\.ai/[A-Za-z0-9/_-]+$ ]] && BOARD_URL=$a ;;
      extra)
        entry="$a|$b|$c|$d"
        [[ $entry =~ ^https://claude\.ai/[^|]+\|[A-Za-z0-9_-]+\|[A-Za-z0-9_-]+\|/[^|]+$ ]] && EXTRA_PUSHES+="${EXTRA_PUSHES:+$'\n'}$entry" ;;
    esac
  done <"$f"
  export BOARD_URL EXTRA_PUSHES
  return 0
}

# Contributor-controlled names (notes, inbox files, branches) must not start a new line in hook output.
safe_text() { tr -cd '[:alnum:] ._/:#()-'; }

# Header keys count only in the first 8 lines (same contract as render.py read_note).
header() { head -n 8 "$1" 2>/dev/null | tr -d '\r' | grep -m1 "^$2:" | sed "s/^$2:[[:space:]]*//"; }

# Same separators as render.py tokens(): whitespace (incl. CR) , ; ( ) and backtick.
branch_tokens() { tr -s ' \t\r,;()`' '\n' | sed '/^$/d'; }

notes_for_branch() {
  local f
  [ "$1" = "${BASE_BRANCH:-main}" ] && return 0
  for f in "$SC"/work/active/*.md "$SC"/work/queued/*.md; do
    [ -e "$f" ] || continue
    header "$f" branch | branch_tokens | grep -qxF -- "$1" && echo "$f"
  done
  return 0
}

# Everyone mode: repo-relative path of the first committed (HEAD) active/queued note listing branch $2 in repo $1.
committed_note_for_branch() {
  local p
  while IFS= read -r p; do
    case $p in *.md) ;; *) continue ;; esac
    git -C "$1" show "HEAD:$p" 2>/dev/null | header /dev/stdin branch | branch_tokens | grep -qxF -- "$2" && { echo "$p"; return 0; }
  done < <(git -C "$1" ls-tree -r --name-only HEAD -- .scaffold/work/active .scaffold/work/queued 2>/dev/null)
  return 0
}

# Repo a gated command acts on: `git -C <dir> … push` or a leading `cd <dir> &&` (dir bare, "…" or '…'), else the hook cwd ($2).
target_dir() {
  local d="" q="'"
  local dir_re="(\"[^\"]+\"|${q}[^$q]+$q|[^ ;&]+)"
  if [[ $1 =~ git\ -[cC]\ $dir_re\ .*push ]]; then d=${BASH_REMATCH[1]}
  elif [[ $1 =~ ^[[:space:]]*cd\ ${dir_re}[[:space:]]*\&\& ]]; then d=${BASH_REMATCH[1]}; fi
  case $d in \"*\" | "$q"*"$q") d=${d#?}; d=${d%?} ;; esac
  case $d in "") echo "$2" ;; /*) echo "$d" ;; *) echo "$2/$d" ;; esac
}

headers_complete() {
  local k
  for k in status branch waiting-on next; do [ -n "$(header "$1" "$k")" ] || return 1; done
}

# Edits under TOPLEVEL outside .scaffold/, or a commit, push or PR command, anywhere in the transcript.
# Output is collected before matching: an early `grep -q` exit would SIGPIPE the producers under pipefail.
did_repo_work() {
  local actions
  actions=$(grep -E '"name":"(Bash|Edit|Write|NotebookEdit)"' "$1" 2>/dev/null \
    | jq -r --arg root "$2/" '.message.content[]? | select(.type == "tool_use")
        | if .name == "Bash" then .input.command
          elif ((.input.file_path // "") | startswith($root)) and ((.input.file_path // "") | contains("/.scaffold/") | not) then "EDIT"
          else empty end' 2>/dev/null)
  grep -qE '^EDIT$|(^|[;&| ])(git( -[cC] [^ ]+)* (commit|push)|gh pr (create|merge|edit))' <<<"$actions"
}
