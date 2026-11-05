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
  SCAFFOLD_MODE=$(effective_mode "$1")  # the key above is contributor-controlled; it must not pick the reader
  SC=$1/.scaffold STATE=$1/.scaffold/.hookstate
  export SCAFFOLD_MODE BASE_BRANCH REMOTE BOARD_URL JIRA_PROJECT JIRA_TOOL EXTRA_PUSHES SC STATE
}

# Everyone mode iff the config is tracked: only then do notes reach teammates, so only then read HEAD.
effective_mode() { if git -C "$1" ls-files --error-unmatch .scaffold/config >/dev/null 2>&1; then echo shared; else echo local; fi; }

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
# NUL-delimited, as core.quotePath quotes non-ASCII names. Any git failure returns 2: callers must not decide on it.
committed_note_for_branch() {
  ( set -o pipefail
    git -C "$1" ls-tree -r -z --name-only HEAD -- .scaffold/work/active .scaffold/work/queued 2>/dev/null | {
      found=""
      while IFS= read -r -d '' p; do
        case $p in *.md) ;; *) continue ;; esac
        [ -z "$found" ] || continue  # keep draining: an early exit would SIGPIPE ls-tree into a false failure
        c=$(git -C "$1" show "HEAD:$p" 2>/dev/null) || exit 2
        header /dev/stdin branch <<<"$c" | branch_tokens | grep -qxF -- "$2" && { echo "$p"; found=1; }
      done
      exit 0
    } ) || return 2
}

# Git global options accepted before the subcommand, -C excluded (matched where its dir matters). Unquoted args only.
_GOPT="( -c [^ ;&|()]+| -P| --no-pager| --paginate| --bare| --exec-path[^ ;&|()]*| --git-dir=[^ ;&|()]+| --work-tree=[^ ;&|()]+)"

# Repo a gated command acts on: `git … -C <dir> … push` or a leading `cd <dir> &&` (dir bare, "…" or '…'), else the hook cwd ($2).
target_dir() {
  local d="" q="'" cmd
  cmd=$(_norm_cmd "$1")
  local dir_re="(\"[^\"]+\"|${q}[^$q]+$q|[^ ;&|()]+)"
  if [[ $cmd =~ git${_GOPT}*\ -C\ ${dir_re}${_GOPT}*\ push ]]; then d=${BASH_REMATCH[2]}
  elif [[ $cmd =~ (^|;)[[:space:]]*cd\ ${dir_re}[[:space:]]*\&\& ]]; then d=${BASH_REMATCH[2]}; fi
  case $d in \"*\" | "$q"*"$q") d=${d#?}; d=${d%?} ;; esac
  case $d in "") echo "$2"; return 0 ;; /*) ;; *) d=$2/$d ;; esac
  # Unresolvable targets (~, $VAR, typos) fall back to the hook cwd rather than failing open.
  if [ -d "$d" ]; then echo "$d"; else echo "$2"; fi
}

headers_complete() {
  local k
  for k in status branch waiting-on next; do [ -n "$(header "$1" "$k")" ] || return 1; done
}

# Push / PR-create detection shared by gate and dispatch. Spawns nothing: it runs before every Bash call.
# Newlines separate commands; tab/CR/space runs are one space.
_norm_cmd() {
  local c=${1//$'\n'/;}
  c=${c//$'\t'/ }; c=${c//$'\r'/ }
  while [[ $c == *'  '* ]]; do c=${c//  / }; done
  printf '%s\n' "$c"
}
# Quoted text is an argument (blanked to Q) unless it is the script of `bash|sh|zsh -…c` or `eval`, which is opened up.
_exec_text() {
  local c out="" pre q rest body qre="^([^\"']*)([\"'])(.*)$"
  c=$(_norm_cmd "$1")
  while [[ $c =~ $qre ]]; do
    pre=${BASH_REMATCH[1]} q=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
    if [[ $rest == *"$q"* ]]; then body=${rest%%"$q"*} rest=${rest#*"$q"}; else body=$rest rest=""; fi
    if [[ $pre =~ (^|[^A-Za-z0-9_.-])((ba|z)?sh -[a-z]*c|eval)\ ?$ ]]; then out+="$pre;" c="$body;$rest"
    else out+="${pre}Q" c=$rest; fi
  done
  printf '%s\n' "$out$c"
}
# Command position: start or after ; & | ( $( backtick, then assignments or wrapper words (FOO=1, env, sudo, then …).
_kind_res() {
  local a="[^ ;&|()\`]+"
  local pos="(^|[;&|(\`]) ?(([A-Za-z_][A-Za-z0-9_]*=[^ ;&|()\`]* )|((env|command|exec|time|nohup|sudo|then|do|else|if|while|until|!|[{]) ))*"
  trail="([ ;&|)\`]|\$)"
  push_re="${pos}git(${_GOPT}| -C $a)* push$trail"
  pr_re="${pos}gh(( -R| --repo) $a| --repo=$a)* pr create$trail"
}
is_push_cmd() { [ -n "$(cmd_kinds "$1")" ]; }
cmd_kinds() {
  local c trail push_re pr_re k=""
  c=$(_exec_text "$1"); _kind_res
  [[ $c =~ $push_re ]] && k=push
  [[ $c =~ $pr_re ]] && k="${k:+$k }pr"
  echo "$k"
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
