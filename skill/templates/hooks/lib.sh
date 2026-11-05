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
  # The key above is contributor-controlled; it must not pick the reader. Unknown tracking state returns 2: callers act on nothing.
  SCAFFOLD_MODE=$(effective_mode "$1") || return 2
  SC=$1/.scaffold STATE=$1/.scaffold/.hookstate
  export SCAFFOLD_MODE BASE_BRANCH REMOTE BOARD_URL JIRA_PROJECT JIRA_TOOL EXTRA_PUSHES SC STATE
}

# Everyone mode iff the config is tracked: only then do notes reach teammates, so only then read HEAD. Git failure returns 2.
effective_mode() {
  local t
  t=$(git -C "$1" ls-files -- .scaffold/config 2>/dev/null) || return 2
  if [ -n "$t" ]; then echo shared; else echo local; fi
}

# Force-added symlinks survive .gitignore: hooks must not read or write through one under .scaffold/ (same list as render.py).
state_safe() {
  local d
  for d in "" /.hookstate /work /work/active /work/queued /work/completed /inbox; do
    [ ! -L "$1/.scaffold$d" ] && { [ ! -e "$1/.scaffold$d" ] || [ -d "$1/.scaffold$d" ]; } || return 1
  done
  [ ! -L "$1/.scaffold/STATUS.md" ] && [ -z "$(find "$1/.scaffold/.hookstate" -maxdepth 1 -type l -print -quit 2>/dev/null)" ]
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

# Git global options accepted before the subcommand, -C excluded (matched where its dir matters). Matched on the exec view.
_GOPT="( -c [^ ;&|()]+| -P| --no-pager| --paginate| --bare| --exec-path[^ ;&|()]*| --git-dir=[^ ;&|()]+| --work-tree=[^ ;&|()]+)"

# Repo of the invocation detection matched (exec view, so quoted examples never count), from the hook cwd ($2): a `cd <dir> &&`
# before it, then its -C dirs (cumulative), then --work-tree or the repo of --git-dir.
target_dir() {
  local m o="" d=$2 w prev="" wt="" gd="" ws=() trail push_re pr_re pos_re cd_re
  _exec_text "$1"; _kind_res
  { [[ $_EXEC =~ $push_re ]] || [[ $_EXEC =~ $pr_re ]]; } || { echo "$2"; return 0; }
  m=${BASH_REMATCH[0]}
  cd_re="(^|[;&|(\`]) ?cd ([^ ;&|()\`]+) ?&&"
  # ${m:0:1} restores the separator the match starts with (the second & of `cd x && git push`).
  [[ ${_EXEC%%"$m"*}${m:0:1} =~ $cd_re ]] && d=$(_join "$d" "$(_unq "${BASH_REMATCH[2]}")")
  [[ $m =~ ^$pos_re ]] && o=${m:${#BASH_REMATCH[0]}}
  case $o in git\ *) o=${o#git}; o=${o% push*} ;; *) o="" ;; esac
  read -r -a ws <<<"$o"
  for w in ${ws[@]+"${ws[@]}"}; do
    [ "$prev" = -C ] && d=$(_join "$d" "$(_unq "$w")")
    case $w in --work-tree=*) wt=$(_unq "${w#*=}") ;; --git-dir=*) gd=$(_unq "${w#*=}") ;; esac
    prev=$w
  done
  if [ -n "$wt" ]; then d=$(_join "$d" "$wt"); elif [ -n "$gd" ]; then gd=${gd%/}; d=$(_join "$d" "${gd%/.git}"); fi
  # Unresolvable targets (~, $VAR, typos) fall back to the hook cwd rather than failing open.
  if [ -d "$d" ]; then echo "$d"; else echo "$2"; fi
}
_join() { case $2 in /*) printf '%s' "$2" ;; *) printf '%s' "$1/$2" ;; esac; }
_unq() { if [[ $1 =~ ^Q([0-9]+)Q$ ]]; then printf '%s' "${_QS[${BASH_REMATCH[1]}]-}"; else printf '%s' "$1"; fi; }

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
# Exec view in _EXEC: each quoted string becomes Q<n>Q (its text in _QS[n]) unless it is the script of `bash|sh|zsh -…c` or
# `eval`, which is opened up; a double-quoted string's $(…) and `…` substitutions execute, so they follow it as commands.
_exec_text() {
  # shellcheck disable=SC2016  # literal $( and backtick patterns
  local c out="" pre q rest body s n=0 qre="^([^\"']*)([\"'])(.*)$" sre='^[^`$]*(\$\([^)]*\)?|`[^`]*`?|\$)(.*)$'
  _QS=()
  c=$(_norm_cmd "$1")
  while [[ $c =~ $qre ]]; do
    pre=${BASH_REMATCH[1]} q=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
    if [[ $rest == *"$q"* ]]; then body=${rest%%"$q"*} rest=${rest#*"$q"}; else body=$rest rest=""; fi
    if [[ $pre =~ (^|[^A-Za-z0-9_.-])((ba|z)?sh -[a-z]*c|eval)\ ?$ ]]; then out+="$pre;" c="$body;$rest"; continue; fi
    _QS[n]=$body; out+="${pre}Q${n}Q"; n=$((n + 1)); s=""
    if [ "$q" = '"' ]; then
      while [[ $body =~ $sre ]]; do
        [ "${BASH_REMATCH[1]}" = '$' ] || s+=";${BASH_REMATCH[1]};"
        body=${BASH_REMATCH[2]}
      done
    fi
    c=$s$rest
  done
  _EXEC=$out$c
}
# Command position: start or after ; & | ( $( backtick, then assignments or wrapper words (FOO=1, env, sudo, then …).
_kind_res() {
  local a="[^ ;&|()\`]+"
  pos_re="(^|[;&|(\`]) ?(([A-Za-z_][A-Za-z0-9_]*=[^ ;&|()\`]* )|((env|command|exec|time|nohup|sudo|then|do|else|if|while|until|!|[{]) ))*"
  trail="([ ;&|)\`]|\$)"
  push_re="${pos_re}git(${_GOPT}| -C $a)* push$trail"
  pr_re="${pos_re}gh(( -R| --repo) $a| --repo=$a)* pr create$trail"
}
is_push_cmd() { [ -n "$(cmd_kinds "$1")" ]; }
cmd_kinds() {
  local c trail push_re pr_re pos_re k=""
  _exec_text "$1"; c=$_EXEC; _kind_res
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
