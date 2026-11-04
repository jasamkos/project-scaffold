#!/usr/bin/env bash
# shellcheck disable=SC1091
# Scaffold hook tests: temp repos with bare remotes, hook JSON on stdin, fake gh on PATH. Usage: test.sh [name-filter]
set -uo pipefail
HOOKS=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0 T=""
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $T: $*"; }
eq() { if [ "$1" = "$2" ]; then ok; else bad "expected [$2] got [$1]"; fi; }
has() { if grep -qF -- "$2" <<<"$1"; then ok; else bad "missing [$2] in [$1]"; fi; }
lacks() { if grep -qF -- "$2" <<<"$1"; then bad "unexpected [$2] in [$1]"; else ok; fi; }

mkrepo() {  # $1 mode -> R repo, BASE temp dir, FAKEBIN dir first on PATH for hooks, GHOUT fake gh output
  # pwd -P: macOS mktemp paths sit under the /var symlink, while git reports the resolved /private/var path.
  BASE=$(cd "$(mktemp -d)" && pwd -P); R=$BASE/repo; FAKEBIN=$BASE/bin; GHOUT=$BASE/gh.out
  git init -q --bare "$BASE/remote.git"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
  git -C "$R" remote add origin "$BASE/remote.git"
  echo x >"$R/README"; git -C "$R" add README; git -C "$R" commit -qm init; git -C "$R" push -q origin main
  mkdir -p "$R/.scaffold/hooks" "$R/.scaffold/work/active" "$R/.scaffold/work/queued" "$R/.scaffold/work/completed" "$R/.scaffold/.hookstate" "$R/.scaffold/inbox"
  for f in lib.sh brief checkpoint gate render.py catchup.py; do [ -f "$HOOKS/$f" ] && cp "$HOOKS/$f" "$R/.scaffold/hooks/"; done
  printf 'SCAFFOLD_MODE=%s\nBASE_BRANCH=main\nREMOTE=origin\nBOARD_URL=\n' "${1:-local}" >"$R/.scaffold/config"
  mkdir -p "$FAKEBIN"
  # Sequenced fake gh: logs argv to gh.calls, prints $GHOUT.<n> if present else $GHOUT. GH_SLEEP sleeps every call, GH_SLEEP_FROM=<k> only calls >= k.
  # exec so a timeout kill reaches the sleeping process; a child sleep would hold the stdout pipe open.
  cat >"$FAKEBIN/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$BASE/gh.calls"
n=\$(cat "$BASE/gh.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$BASE/gh.n"
if [ -n "\${GH_SLEEP:-}" ] && { [ -z "\${GH_SLEEP_FROM:-}" ] || [ "\$n" -ge "\$GH_SLEEP_FROM" ]; }; then exec sleep "\$GH_SLEEP"; fi
if [ -n "\${GH_SLEEP_FROM:-}" ] && [ -z "\${GH_SLEEP:-}" ] && [ "\$n" -ge "\$GH_SLEEP_FROM" ]; then exec sleep 30; fi
if [ -f "$GHOUT.\$n" ]; then cat "$GHOUT.\$n"; else cat "$GHOUT" 2>/dev/null || exit 1; fi
EOF
  chmod +x "$FAKEBIN/gh"
}
note() {  # $1 task, $2 branch header value, $3 status
  printf 'status: %s\nbranch: %s\nwaiting-on: none\nnext: ship\n\n# %s\n' "${3:-in progress}" "$2" "$1" >"$R/.scaffold/work/active/$1.md"
}
deny_has() {  # $1 hook output, $2 reason fragment: valid PreToolUse deny JSON carrying the reason
  if [ "$(jq -r '.hookSpecificOutput.hookEventName + "/" + .hookSpecificOutput.permissionDecision' <<<"$1" 2>/dev/null)" = "PreToolUse/deny" ]; then
    has "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$1")" "$2"
  else bad "not a PreToolUse deny: [$1]"; fi
}
commit_note() { git -C "$R" add -f ".scaffold/work/active/$1.md" && git -C "$R" commit -qm "note $1"; }
hookjson() {  # $1 command, $2 session id, $3 transcript path
  jq -nc --arg c "$1" --arg d "$R" --arg s "${2:-s1}" --arg t "${3:-}" \
    '{session_id: $s, cwd: $d, transcript_path: $t, stop_hook_active: false, tool_name: "Bash", tool_input: {command: $c}}'
}

SKILL=$(cd "$HOOKS/../.." && pwd)
# Installer/dispatch/extras tests run (and fail if the files are missing) in the source checkout; an installed copy (.scaffold/hooks/test.sh smoke run) skips them.
in_source() { [ "$HOOKS" = "$SKILL/templates/hooks" ]; }
needs_skill() { in_source; }

t_harness() { T=harness; mkrepo local; eq "$(git -C "$R" branch --show-current)" main; }

# --- runner ---
for T in $(declare -F | awk '{print $3}' | grep '^t_' | grep -- "${1:-}"); do "$T"; done
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
