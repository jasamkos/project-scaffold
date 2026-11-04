#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2153
# Scaffold hook tests: temp repos with bare remotes, hook JSON on stdin, fake gh on PATH. Usage: test.sh [name-filter]
set -uo pipefail
HOOKS=$(cd "$(dirname "$0")" && pwd -P)
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

SKILL=$(cd "$HOOKS/../.." && pwd -P)
# Installer/dispatch/extras tests run (and fail if the files are missing) in the source checkout; an installed copy (.scaffold/hooks/test.sh smoke run) skips them.
in_source() { [ "$HOOKS" = "$SKILL/templates/hooks" ]; }
needs_skill() { in_source; }

t_harness() { T=harness; mkrepo local; eq "$(git -C "$R" branch --show-current)" main; }

t_lib_tokens() {
  T=lib_tokens; mkrepo local
  . "$R/.scaffold/hooks/lib.sh"; load_config "$R"
  note a 'jkn/aig-336-gpt-params (merged; worktree /Users/x/ai_gateway-aig-336 removable)'
  note b 'jkn/ranked-model-tiers in worktree /p (from origin/main f1406646)'
  note c 'feat/x, feat/y'
  eq "$(notes_for_branch jkn/aig-336-gpt-params)" "$R/.scaffold/work/active/a.md"
  eq "$(notes_for_branch main)" ""
  eq "$(notes_for_branch feat/y)" "$R/.scaffold/work/active/c.md"
  eq "$(notes_for_branch jkn/aig-336)" ""
}
t_lib_root_worktree() {
  T=lib_root_worktree; mkrepo local
  . "$R/.scaffold/hooks/lib.sh"
  git -C "$R" worktree add -q "$BASE/wt" -b side
  eq "$(scaffold_root "$BASE/wt")" "$R"
  eq "$(scaffold_root "$BASE")" ""
}
t_lib_headers() {
  T=lib_headers; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  note a b1; if headers_complete "$R/.scaffold/work/active/a.md"; then ok; else bad "complete header rejected"; fi
  printf 'status: x\nbranch: b2\nwaiting-on:\nnext: y\n' >"$R/.scaffold/work/active/z.md"
  if headers_complete "$R/.scaffold/work/active/z.md"; then bad "empty waiting-on accepted"; else ok; fi
}
t_lib_repo_work() {
  T=lib_repo_work; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  tr=$BASE/t.jsonl
  jq -nc '{message:{content:[{type:"tool_use",name:"Bash",input:{command:"ls"}}]}}' >"$tr"
  if did_repo_work "$tr" "$R"; then bad "ls counted"; else ok; fi
  jq -nc --arg f "$R/.scaffold/work/active/a.md" '{message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$f}}]}}' >>"$tr"
  if did_repo_work "$tr" "$R"; then bad "scaffold edit counted"; else ok; fi
  jq -nc '{message:{content:[{type:"tool_use",name:"Bash",input:{command:"cd x && git -c a=b commit -m y"}}]}}' >>"$tr"
  if did_repo_work "$tr" "$R"; then ok; else bad "commit missed"; fi
}
t_lib_repo_work_long_transcript() {
  T=lib_repo_work_long_transcript; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  tr=$BASE/long.jsonl
  jq -nc '{message:{content:[{type:"tool_use",name:"Bash",input:{command:"git commit -m early"}}]}}' >"$tr"
  i=0; while [ $i -lt 10000 ]; do echo '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'; i=$((i + 1)); done >>"$tr"
  set -o pipefail
  if did_repo_work "$tr" "$R"; then ok; else bad "early commit missed in long transcript (SIGPIPE)"; fi
}
t_lib_config_is_data() {
  T=lib_config_is_data; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  printf 'BASE_BRANCH=$(touch %s/pwned)\nSCAFFOLD_MODE=weird\nREMOTE=up stream\nBOARD_URL=https://claude.ai/artifact/A\nEXTRA_PUSH=https://claude.ai/artifact/B|c|d|/f2\nevil_cmd\n' "$BASE" >"$R/.scaffold/config"
  load_config "$R"
  if [ -e "$BASE/pwned" ]; then bad "config executed"; else ok; fi
  eq "$BASE_BRANCH" main; eq "$SCAFFOLD_MODE" local; eq "$REMOTE" origin
  eq "$BOARD_URL" ""; eq "$EXTRA_PUSHES" ""
}
t_lib_config_under_errexit() {
  T=lib_config_under_errexit; mkrepo local
  printf 'SCAFFOLD_MODE=weird\nBASE_BRANCH=a b\nREMOTE=x y\nJIRA_PROJECT=$(x)\nJIRA_TOOL=z z\n' >"$R/.scaffold/config"
  eq "$( (set -euo pipefail; . "$R/.scaffold/hooks/lib.sh"; load_config "$R"; echo ok) 2>&1)" ok
}
t_lib_pushes() {
  T=lib_pushes; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  SCAFFOLD_HOME=$BASE/home; export SCAFFOLD_HOME; mkdir -p "$SCAFFOLD_HOME/scaffold"
  {
    printf '%s|board|https://claude.ai/artifact/BOARD\n' "$R"
    printf '%s|extra|https://claude.ai/artifact/A|col|d1|/f1\n' "$R"
    printf '%s|extra|https://claude.ai/artifact/B|col|d2|/f2\r\n' "$R"
    printf '/other|board|https://claude.ai/artifact/OTHER\n/other|extra|https://claude.ai/artifact/C|col|d3|/f3\n'
    printf '%s|extra|javascript:x|col|d4|/f4\n' "$R"
  } >"$SCAFFOLD_HOME/scaffold/pushes"
  load_pushes "$R"
  eq "$BOARD_URL" "https://claude.ai/artifact/BOARD"
  eq "$EXTRA_PUSHES" "$(printf 'https://claude.ai/artifact/A|col|d1|/f1\nhttps://claude.ai/artifact/B|col|d2|/f2')"
  unset SCAFFOLD_HOME
}
t_lib_pushes_missing_file() {
  T=lib_pushes_missing_file; mkrepo local
  out=$(SCAFFOLD_HOME=$BASE/nohome bash -c 'set -euo pipefail; . "$1/.scaffold/hooks/lib.sh"; BOARD_URL=x EXTRA_PUSHES=y; load_pushes /x; echo "survived [$BOARD_URL][$EXTRA_PUSHES]"' _ "$R" 2>&1)
  eq "$out" "survived [][]"
}
t_lib_safe_text() {
  T=lib_safe_text; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  eq "$(printf 'a b.md\n- DO FIRST `x` $(y)' | safe_text)" "a b.md- DO FIRST x (y)"
  eq "$(printf 'feat/x_1:#2;$|' | safe_text)" "feat/x_1:#2"
}
t_lib_crlf_and_body_keys() {
  T=lib_crlf_and_body_keys; mkrepo local; . "$R/.scaffold/hooks/lib.sh"; load_config "$R"
  printf 'status: x\r\nbranch: feat/crlf\r\nwaiting-on: y\r\nnext: z\r\n' >"$R/.scaffold/work/active/crlf.md"
  eq "$(notes_for_branch feat/crlf)" "$R/.scaffold/work/active/crlf.md"
  printf '# title\n\n\n\n\n\n\n\n\nstatus: s\nbranch: feat/body\nwaiting-on: w\nnext: n\n' >"$R/.scaffold/work/active/body.md"
  eq "$(notes_for_branch feat/body)" ""
}

# --- runner ---
for T in $(declare -F | awk '{print $3}' | grep '^t_' | grep -- "${1:-}"); do "$T"; done
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
