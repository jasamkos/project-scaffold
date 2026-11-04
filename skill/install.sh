#!/usr/bin/env bash
# Install scaffold hooks.
# Usage: install.sh --mode local|shared --repo DIR [--board-url URL] [--extra-push 'url|coll|doc|/abs/file']...
#        install.sh --register-board URL --repo DIR   (pushes line only: no hooks)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mode="" repo="" board="" register="" extras=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
  case $1 in
    --mode) mode=$2 ;;
    --repo) repo=$2 ;;
    --board-url) board=$2 ;;
    --register-board) register=$2 ;;
    --extra-push) extras+="${extras:+$'\n'}$2" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift 2
done
home=${SCAFFOLD_HOME:-$HOME/.claude}
pushes=$home/scaffold/pushes
board_re='^https://claude\.ai/[A-Za-z0-9/_-]+$'
extra_re='^https://claude\.ai/[^|]+\|[A-Za-z0-9_-]+\|[A-Za-z0-9_-]+\|/[^|]+$'  # same shapes as lib.sh load_pushes

main() {
  local e settings
  [ -n "$repo" ] || die "--repo is required"
  repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $repo"
  case $repo in *'|'* | *$'\n'*) die "repo path must not contain | or newline" ;; esac
  if [ -n "$register" ]; then
    [ -z "$mode$board$extras" ] || die "--register-board takes only --repo"
    valid_board "$register"
    put_push "$repo" board "$register"
    echo "registered board for $repo"
    return 0
  fi
  case $mode in local | shared) ;; *) die "--mode local|shared is required" ;; esac
  [ -z "$board" ] || valid_board "$board"
  while IFS= read -r e; do
    [ -z "$e" ] || { [[ $e =~ $extra_re ]] || die "invalid --extra-push: $e"; }
  done <<<"$extras"
  if [ "$mode" = local ]; then settings=${SCAFFOLD_SETTINGS:-$home/settings.json}; else settings=$repo/.claude/settings.json; fi
  [ ! -s "$settings" ] || jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings is not a JSON object; fix it first"
  install_hooks
  [ -z "$board" ] || put_push "$repo" board "$board"
  while IFS= read -r e; do [ -z "$e" ] || put_push "$repo" extra "$e"; done <<<"$extras"
  if [ "$mode" = local ]; then
    mkdir -p "$home/scaffold"
    cp "$here/dispatch" "$here/templates/hooks/lib.sh" "$home/scaffold/"; chmod +x "$home/scaffold/dispatch"
    [ -e "$home/scaffold/repos" ] || (umask 077; : >"$home/scaffold/repos")
    append_once "$home/scaffold/repos" "$repo"
    merge_settings "$settings" "$home/scaffold/dispatch " "scaffold/dispatch"
  else
    append_once "$repo/.gitignore" ".scaffold/STATUS.md"
    append_once "$repo/.gitignore" ".scaffold/.hookstate/"
    mkdir -p "$repo/.claude"
    # shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR, expanded by Claude Code
    merge_settings "$settings" '"$CLAUDE_PROJECT_DIR"/.scaffold/hooks/' '.scaffold/hooks/'
  fi
  echo "installed $mode scaffold hooks in $repo"
}

die() { echo "install.sh: $1" >&2; exit 2; }
valid_board() { [[ $1 =~ $board_re ]] || die "invalid board URL: $1"; }

install_hooks() {
  local sc=$repo/.scaffold f exclude
  mkdir -p "$sc/hooks" "$sc/work/active" "$sc/work/queued" "$sc/work/completed" "$sc/inbox" "$sc/.hookstate"
  for f in lib.sh brief checkpoint gate render.py catchup.py test.sh; do cp "$here/templates/hooks/$f" "$sc/hooks/"; done
  chmod +x "$sc/hooks/brief" "$sc/hooks/checkpoint" "$sc/hooks/gate" "$sc/hooks/render.py" "$sc/hooks/catchup.py" "$sc/hooks/test.sh"
  [ -f "$sc/config" ] || cp "$here/templates/hooks/config.default" "$sc/config"
  set_key "$sc/config" SCAFFOLD_MODE "$mode"
  if [ "$mode" = local ]; then
    exclude=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude
    append_once "$exclude" "/.scaffold/"
    append_once "$exclude" "/CLAUDE.local.md"
  fi
}

# Replace the line with the same root+kind (+url for extra), then add ours; temp + mv, mode 600.
put_push() {  # root kind payload
  local tmp
  mkdir -p "$home/scaffold"
  tmp=$(mktemp "$pushes.XXXXXX")  # mktemp creates 0600
  { [ ! -f "$pushes" ] || awk -F'|' -v r="$1" -v k="$2" -v u="${3%%|*}" \
      '!($1 == r && $2 == k && (k == "board" || $3 == u))' "$pushes"; echo "$1|$2|$3"; } >"$tmp"
  mv "$tmp" "$pushes"
}

set_key() {  # file key value: replace or append KEY=value
  local tmp
  tmp=$(mktemp)
  grep -v "^$2=" "$1" >"$tmp" || true
  echo "$2=$3" >>"$tmp"
  mv "$tmp" "$1"
}

append_once() { touch "$1"; grep -qxF -- "$2" "$1" || echo "$2" >>"$1"; }

# Drop this installer's commands (containing $3) from every registration, keep the rest of each registration
# (matcher, sibling commands), drop registrations left empty, then add ours once per event.
merge_settings() {
  local file=$1 prefix=$2 mine=$3 tmp
  [ -s "$file" ] || echo '{}' >"$file"
  tmp=$(mktemp "$file.XXXXXX")
  jq --arg p "$prefix" --arg mine "$mine" '
    def strip: map(.hooks = [(.hooks // [])[] | select((.command // "") | contains($mine) | not)]) | map(select(.hooks | length > 0));
    def put(ev; m; cmd): .hooks[ev] = (((.hooks[ev] // []) | strip)
      + [({hooks: [{type: "command", command: cmd}]} + (if m == null then {} else {matcher: m} end))]);
    .hooks = (.hooks // {})
    | put("SessionStart"; null; $p + "brief")
    | put("Stop"; null; $p + "checkpoint")
    | put("PreToolUse"; "Bash"; $p + "gate")' "$file" >"$tmp"
  mv "$tmp" "$file"
}

main
