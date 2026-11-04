#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012,SC2016,SC2153
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

gate() { PATH="$FAKEBIN:$PATH" "$R/.scaffold/hooks/gate" <<<"$(hookjson "$1")"; }
t_gate_fast_path() {
  T=gate_fast_path; mkrepo local
  printf '#!/bin/sh\necho called >>"%s/git.calls"\nexec /usr/bin/git "$@"\n' "$BASE" >"$FAKEBIN/git"; chmod +x "$FAKEBIN/git"
  eq "$(gate 'ls -la')" ""
  if [ -e "$BASE/git.calls" ]; then bad "git ran for non-push command"; else ok; fi
}
t_gate_no_note() {
  T=gate_no_note; mkrepo local; git -C "$R" switch -qc feat/a
  deny_has "$(gate 'git push -u origin feat/a')" "no work note lists branch feat/a"
}
t_lib_target_dir() {
  T=lib_target_dir; mkrepo local; . "$R/.scaffold/hooks/lib.sh"
  mkdir -p "$BASE/x/y" "$BASE/x/y z" "$BASE/c/rel"; X=$BASE/x
  eq "$(target_dir "git -C $X/y push" /c)" "$X/y"
  eq "$(target_dir "git -C \"$X/y z\" push" /c)" "$X/y z"
  eq "$(target_dir "git -C '$X/y z' push" /c)" "$X/y z"
  eq "$(target_dir "cd $X/y && git push" /c)" "$X/y"
  eq "$(target_dir "cd \"$X/y z\" && git push" /c)" "$X/y z"
  eq "$(target_dir "cd '$X/y z' && git push" /c)" "$X/y z"
  eq "$(target_dir 'git -C rel push' "$BASE/c")" "$BASE/c/rel"
  eq "$(target_dir 'git push' /c)" "/c"
  eq "$(target_dir "git -c k=v -C $X/y push" /c)" "$X/y"
  eq "$(target_dir 'git -c k=v push' /c)" "/c"
  eq "$(target_dir 'cd ~/nonexistent-xyz && git push' /c)" "/c"
}
t_gate_targets_command_repo() {
  T=gate_targets_command_repo; mkrepo local
  git -C "$R" worktree add -q "$BASE/wt" -b feat/w
  deny_has "$(gate "git -C $BASE/wt push -u origin feat/w")" "no work note lists branch feat/w"
  deny_has "$(gate "cd $BASE/wt && git push")" "no work note lists branch feat/w"
  deny_has "$(gate "git -C \"$BASE/wt\" push")" "no work note lists branch feat/w"
  deny_has "$(gate "git -C '$BASE/wt' push")" "no work note lists branch feat/w"
  deny_has "$(gate "cd \"$BASE/wt\" && git push")" "no work note lists branch feat/w"
  deny_has "$(gate "cd '$BASE/wt' && git push")" "no work note lists branch feat/w"
}
t_gate_base_and_skip() {
  T=gate_base_and_skip; mkrepo local
  eq "$(gate 'git push origin main')" ""
  git -C "$R" switch -qc feat/a
  eq "$(gate 'SCAFFOLD_SKIP=1 git push')" ""
}
t_gate_incomplete() {
  T=gate_incomplete; mkrepo local; git -C "$R" switch -qc feat/a
  printf 'status: x\nbranch: feat/a\nwaiting-on:\nnext: y\n' >"$R/.scaffold/work/active/a.md"
  deny_has "$(gate 'gh pr create --fill')" "header"
}
t_gate_local_stamp() {
  T=gate_local_stamp; mkrepo local; git -C "$R" switch -qc feat/a; note a feat/a
  eq "$(gate 'git push')" ""
  eq "$(gate 'gh pr create --fill')" ""
  touch -t 202001010000 "$R/.scaffold/work/active/a.md"
  deny_has "$(gate 'git push')" "not updated since the last"
  touch -t 202001010000 "$R/.scaffold/.hookstate/push-feat_a"; touch "$R/.scaffold/work/active/a.md"
  eq "$(gate 'git push')" ""
}
t_gate_local_compound() {
  T=gate_local_compound; mkrepo local; git -C "$R" switch -qc feat/a; note a feat/a
  eq "$(gate 'git push && gh pr create --fill')" ""
  deny_has "$(gate 'git push')" "not updated since the last push"
  deny_has "$(gate 'gh pr create --fill')" "not updated since the last pr"
}
t_gate_shared_diff() {
  T=gate_shared_diff; mkrepo shared; git -C "$R" switch -qc feat/a; note a feat/a
  deny_has "$(gate 'git push -u origin feat/a')" "not committed"
  commit_note a
  eq "$(gate 'git push -u origin feat/a')" ""
}
t_gate_shared_checks_committed_copy() {
  T=gate_shared_checks_committed_copy; mkrepo shared; git -C "$R" switch -qc feat/a
  printf 'status: x\nbranch: feat/a\nwaiting-on:\nnext: y\n' >"$R/.scaffold/work/active/a.md"; commit_note a
  note a feat/a
  deny_has "$(gate 'git push')" "committed copy"
}
t_gate_shared_ignores_worktree_copy() {
  T=gate_shared_ignores_worktree_copy; mkrepo shared; git -C "$R" switch -qc feat/a; note a feat/a; commit_note a
  printf 'status: x\nbranch: other\n' >"$R/.scaffold/work/active/a.md"
  eq "$(gate 'git push')" ""
}
t_gate_shared_note_from_main() {
  T=gate_shared_note_from_main; mkrepo shared; note a feat/a; commit_note a; git -C "$R" push -q origin main
  git -C "$R" switch -qc feat/a; echo code >"$R/code"; git -C "$R" add code; git -C "$R" commit -qm code
  deny_has "$(gate 'git push')" "not changed on this branch"
}
t_gate_shared_from_subdir() {
  T=gate_shared_from_subdir; mkrepo shared; git -C "$R" switch -qc feat/a; note a feat/a; commit_note a; mkdir "$R/sub"
  eq "$(PATH="$FAKEBIN:$PATH" "$R/.scaffold/hooks/gate" <<<"$(hookjson 'git push' | jq -c --arg d "$R/sub" '.cwd = $d')")" ""
}
t_gate_lowercase_c_option() {
  T=gate_lowercase_c_option; mkrepo local; git -C "$R" switch -qc feat/a
  deny_has "$(gate 'git -c core.sshCommand=ssh push')" "no work note lists branch feat/a"
  deny_has "$(gate 'cd ~/nonexistent-xyz && git push')" "no work note lists branch feat/a"
}
t_gate_multiline_and_tab() {
  T=gate_multiline_and_tab; mkrepo local; git -C "$R" switch -qc feat/a
  deny_has "$(gate $'set -e\ngit push')" "no work note lists branch feat/a"
  deny_has "$(gate $'git\tpush')" "no work note lists branch feat/a"
}
t_gate_terminators() {
  T=gate_terminators; mkrepo local; git -C "$R" switch -qc feat/a
  deny_has "$(gate $'git add .\ngit push\necho done')" "no work note lists branch feat/a"
  deny_has "$(gate 'git push;echo x')" "no work note lists branch feat/a"
  deny_has "$(gate 'git push&&echo x')" "no work note lists branch feat/a"
  deny_has "$(gate 'git push|cat')" "no work note lists branch feat/a"
  deny_has "$(gate '(git push)')" "no work note lists branch feat/a"
  deny_has "$(gate 'echo a && gh pr create --fill;echo b')" "no work note lists branch feat/a"
  deny_has "$(gate 'gh pr create;echo x')" "no work note lists branch feat/a"
  deny_has "$(gate 'gh pr create&&echo x')" "no work note lists branch feat/a"
  deny_has "$(gate 'gh pr create|cat')" "no work note lists branch feat/a"
  deny_has "$(gate 'bash -c "git push"')" "no work note lists branch feat/a"
  deny_has "$(gate "sh -c 'gh pr create --fill'")" "no work note lists branch feat/a"
  deny_has "$(gate 'echo `git push`')" "no work note lists branch feat/a"
  eq "$(gate 'git pushx')" ""
  eq "$(gate 'git push-mirror-tool')" ""
  eq "$(gate 'echo gh pr created')" ""
}
t_gate_shared_missing_base_ref() {
  T=gate_shared_missing_base_ref; mkrepo shared; git -C "$R" switch -qc feat/a; note a feat/a; commit_note a
  git -C "$R" update-ref -d refs/remotes/origin/main
  eq "$(gate 'git push')" ""
}
t_gate_deny_text_sanitized() {
  T=gate_deny_text_sanitized; mkrepo local; git -C "$R" switch -qc 'feat/a$(x)"q'
  deny_has "$(gate 'git push')" 'no work note lists branch feat/a(x)q'
}
t_gate_fail_open() {
  T=gate_fail_open; mkrepo local; git -C "$R" switch -qc feat/a; rm "$R/.scaffold/hooks/lib.sh"
  eq "$(gate 'git push')" ""
}

ckpt() { "$R/.scaffold/hooks/checkpoint" <<<"$(hookjson '' s1 "$BASE/t.jsonl")"; }
commit_line() { jq -nc '{message:{content:[{type:"tool_use",name:"Bash",input:{command:"git commit -m x"}}]}}' >>"$BASE/t.jsonl"; }
is_block() { eq "$(jq -r .decision <<<"$1" 2>/dev/null)" block; }
t_ckpt_blocks_once() {
  T=ckpt_blocks_once; mkrepo local; git -C "$R" switch -qc feat/a; note a feat/a
  touch -t 202001010000 "$R/.scaffold/work/active/a.md"; touch "$R/.scaffold/.hookstate/s1.start"; commit_line
  out=$(ckpt); is_block "$out"; eq "$(jq -r 'keys | join(",")' <<<"$out")" decision,reason
  eq "$(ckpt)" ""
}
t_ckpt_note_updated() {
  T=ckpt_note_updated; mkrepo local; git -C "$R" switch -qc feat/a
  touch -t 202001010000 "$R/.scaffold/.hookstate/s1.start"; note a feat/a; commit_line
  eq "$(ckpt)" ""
}
t_ckpt_no_work() {
  T=ckpt_no_work; mkrepo local; touch "$R/.scaffold/.hookstate/s1.start"
  jq -nc '{message:{content:[{type:"tool_use",name:"Bash",input:{command:"ls"}}]}}' >"$BASE/t.jsonl"
  eq "$(ckpt)" ""
}
t_ckpt_base_any_note() {
  T=ckpt_base_any_note; mkrepo local
  note other 'jkn/x (from origin/main)'; touch -t 202001010000 "$R/.scaffold/work/active/other.md"
  touch -t 202101010000 "$R/.scaffold/.hookstate/s1.start"; note fresh feat/z; commit_line
  eq "$(ckpt)" ""
}
t_ckpt_feature_needs_own_note() {
  T=ckpt_feature_needs_own_note; mkrepo local; git -C "$R" switch -qc feat/orphan
  touch -t 202101010000 "$R/.scaffold/.hookstate/s1.start"; note unrelated feat/other; commit_line
  is_block "$(ckpt)"
}
t_ckpt_shared_reason() {
  T=ckpt_shared_reason; mkrepo shared; git -C "$R" switch -qc feat/a; note a feat/a
  touch -t 202001010000 "$R/.scaffold/work/active/a.md"; touch "$R/.scaffold/.hookstate/s1.start"; commit_line
  out=$(ckpt); is_block "$out"; has "$(jq -r .reason <<<"$out")" "team-visible"
}
t_ckpt_first_stop_creates_marker() {
  T=ckpt_first_stop_creates_marker; mkrepo local; commit_line
  eq "$(ckpt)" ""; if [ -e "$R/.scaffold/.hookstate/s1.start" ]; then ok; else bad "marker not created"; fi
}
t_ckpt_sanitizes_reason() {
  T=ckpt_sanitizes_reason; mkrepo local; git -C "$R" switch -qc feat/a
  note 'a"b' feat/a; touch -t 202001010000 "$R/.scaffold/work/active/a\"b.md"; touch "$R/.scaffold/.hookstate/s1.start"; commit_line
  out=$(ckpt); is_block "$out"; lacks "$(jq -r .reason <<<"$out")" '"'; has "$(jq -r .reason <<<"$out")" "work/active/ab.md"
}
t_ckpt_fails_open() {
  T=ckpt_fails_open; mkrepo local; touch "$R/.scaffold/.hookstate/s1.start"
  eq "$("$R/.scaffold/hooks/checkpoint" <<<"$(hookjson '' s1 "$BASE/missing.jsonl")")" ""
  "$R/.scaffold/hooks/checkpoint" <<<"not json" >/dev/null 2>&1; eq "$?" 0
  eq "$("$R/.scaffold/hooks/checkpoint" <<<"not json" 2>&1)" ""
}

render() { PATH="$FAKEBIN:$PATH" python3 -I "$R/.scaffold/hooks/render.py" "$R" main "${MODE:-local}"; }
expire_cache() { touch -t 202001010000 "$R/.scaffold/.hookstate/merged.json"; }
board() { jq -r "$1" "$R/.scaffold/.hookstate/board.json"; }
t_render_shared_uses_committed_notes() {
  T=render_shared_uses_committed_notes; mkrepo shared; echo '[]' >"$GHOUT"
  note published feat/p; commit_note published; note draft feat/d
  MODE=shared render
  eq "$(board '[.now[].task] | join(",")')" "published"
}
t_render_cache_fallback_keeps_history() {
  T=render_cache_fallback_keeps_history; mkrepo local; note done-task feat/done
  echo '[{"number":7,"title":"t","headRefName":"feat/done","mergedAt":"2026-11-03T10:00:00Z"}]' >"$GHOUT"
  render; eq "$(board '.last_round[0].task')" "done-task"; expire_cache
  echo '[]' >"$GHOUT"; render; eq "$(board '.last_round[0].task')" "done-task"; expire_cache
  GH_SLEEP=5 SCAFFOLD_GH_TIMEOUT=1 render; eq "$(board '.last_round[0].task')" "done-task"; expire_cache
  rm "$GHOUT"; render; eq "$(board '.last_round[0].task')" "done-task"
  eq "$(jq -r '.history["feat/done"].number' "$R/.scaffold/.hookstate/merged.json")" "7"
}
t_render_legacy_cache_is_empty_history() {
  T=render_legacy_cache_is_empty_history; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  echo '{"feat/a":{"number":3,"mergedAt":"2026-11-01T00:00:00Z"}}' >"$R/.scaffold/.hookstate/merged.json"
  render; eq "$(board '[.now[].task] | join(",")')" "a"
  echo 'garbage' >"$R/.scaffold/.hookstate/merged.json"; render || bad "garbled cache crashed render"
}
t_render_crlf_bytes() {
  T=render_crlf_bytes; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  printf 'HAND\r\nTOP\r\n<!-- scaffold:generated -->\nx\n<!-- /scaffold:generated -->\r\nBOTTOM\r\n' >"$R/.scaffold/STATUS.md"
  render
  eq "$(head -c 11 "$R/.scaffold/STATUS.md" | od -An -c | tr -s ' ')" "$(printf 'HAND\r\nTOP\r\n' | od -An -c | tr -s ' ')"
  eq "$(tail -c 10 "$R/.scaffold/STATUS.md" | od -An -c | tr -s ' ')" "$(printf '\r\nBOTTOM\r\n' | od -An -c | tr -s ' ')"
}
t_render_split() {
  T=render_split; mkrepo local
  note done-task 'feat/done (merged; worktree /x)'; note open-task feat/open
  echo '[{"number":7,"title":"t","headRefName":"feat/done","mergedAt":"2026-11-03T10:00:00Z"},{"number":8,"title":"m","headRefName":"main","mergedAt":"2026-11-02T10:00:00Z"}]' >"$GHOUT"
  note on-main 'main'
  render
  s=$(cat "$R/.scaffold/STATUS.md")
  has "$s" "<!-- scaffold:generated -->"
  has "$(board '.last_round[0].task')" "done-task"
  eq "$(board '[.now[].task] | sort | join(",")')" "on-main,open-task"
}
t_render_first_token_decides() {
  T=render_first_token_decides; mkrepo local; note stack 'feat/top feat/base'
  echo '[{"number":9,"title":"b","headRefName":"feat/base","mergedAt":"2026-11-03T10:00:00Z"}]' >"$GHOUT"
  render
  eq "$(board '.now[0].task')" "stack"
}
t_render_preserves_hand_text() {
  T=render_preserves_hand_text; mkrepo local; note a feat/a
  printf '# STATUS\n\nHAND TOP\n\n<!-- scaffold:generated -->\nOLD-GENERATED-SENTINEL\n<!-- /scaffold:generated -->\n\nHAND BOTTOM\n' >"$R/.scaffold/STATUS.md"
  render; s=$(cat "$R/.scaffold/STATUS.md")
  has "$s" "HAND TOP"; has "$s" "HAND BOTTOM"; lacks "$s" "OLD-GENERATED-SENTINEL"; has "$s" "**a**"
}
t_render_status_atomic() {
  T=render_status_atomic; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  printf 'HAND\n<!-- scaffold:generated -->\nOLD-GENERATED-SENTINEL\n<!-- /scaffold:generated -->\nEND\n' >"$R/.scaffold/STATUS.md"
  i1=$(ls -i "$R/.scaffold/STATUS.md" | awk '{print $1}'); render
  i2=$(ls -i "$R/.scaffold/STATUS.md" | awk '{print $1}')
  if [ "$i1" != "$i2" ]; then ok; else bad "STATUS inode unchanged"; fi
  s=$(cat "$R/.scaffold/STATUS.md"); has "$s" "HAND"; has "$s" "END"; lacks "$s" "OLD-GENERATED-SENTINEL"
  eq "$(find "$R/.scaffold" -name 'tmp*' | wc -l | tr -d ' ')" "0"
}
t_render_gh_missing_and_slow() {
  T=render_gh_missing_and_slow; mkrepo local; note a feat/a
  render || bad "render failed without gh"
  echo '[]' >"$GHOUT"
  rm -f "$R/.scaffold/.hookstate/merged.json"
  start=$(date +%s)
  GH_SLEEP=5 SCAFFOLD_GH_TIMEOUT=1 render || bad "render failed on slow gh"
  if [ $(( $(date +%s) - start )) -lt 4 ]; then ok; else bad "render waited for slow gh"; fi
}
t_render_one_deadline_for_all_gh_calls() {
  T=render_one_deadline_for_all_gh_calls; mkrepo local; echo '[]' >"$GHOUT"
  note a feat/a; note b feat/b; note c feat/c
  start=$(date +%s)
  GH_SLEEP_FROM=2 SCAFFOLD_GH_TIMEOUT=2 render || bad "render failed"
  if [ $(( $(date +%s) - start )) -lt 4 ]; then ok; else bad "per-branch lookups outlived the shared deadline"; fi
}
t_render_fair_branch_lookups() {
  T=render_fair_branch_lookups; mkrepo local; echo '[]' >"$GHOUT"
  for i in 1 2 3 4 5 6 7 8 9 10 11; do note "n$i" "feat/b$i"; done
  render; expire_cache; render
  for i in 1 2 3 4 5 6 7 8 9 10 11; do has "$(grep -e '--head' "$BASE/gh.calls")" "--head feat/b$i "; done
}
t_render_cache_follows_base_commit() {
  T=render_cache_follows_base_commit; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  render; eq "$(board '[.now[].task] | join(",")')" "a"
  echo y >"$R/y"; git -C "$R" add y; git -C "$R" commit -qm y
  echo '[{"number":5,"title":"t","headRefName":"feat/a","mergedAt":"2026-11-04T10:00:00Z"}]' >"$GHOUT"
  render; eq "$(board '.last_round[0].task')" "a"
}
t_render_cache_fresh_skips_gh() {
  T=render_cache_fresh_skips_gh; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  render; n1=$(wc -l <"$BASE/gh.calls"); render
  eq "$(wc -l <"$BASE/gh.calls")" "$n1"
}
t_render_hash_stable() {
  T=render_hash_stable; mkrepo local; note a feat/a; echo '[]' >"$GHOUT"
  render; h1=$(cat "$R/.scaffold/.hookstate/board.hash"); sleep 1; render
  eq "$(cat "$R/.scaffold/.hookstate/board.hash")" "$h1"
}

t_render_marker_injection() {
  T=render_marker_injection; mkrepo local; echo '[]' >"$GHOUT"
  note a feat/a 'x <!-- /scaffold:generated --> y <!-- scaffold:generated --> z'
  printf 'HAND TOP\n<!-- scaffold:generated -->\nOLD-GENERATED-SENTINEL\n<!-- /scaffold:generated -->\nHAND BOTTOM\n' >"$R/.scaffold/STATUS.md"
  render; render; s=$(cat "$R/.scaffold/STATUS.md")
  eq "$(grep -cF -- '<!-- scaffold:generated -->' <<<"$s")" 1; eq "$(grep -cF -- '<!-- /scaffold:generated -->' <<<"$s")" 1
  has "$s" "HAND TOP"; has "$s" "HAND BOTTOM"; lacks "$s" "OLD-GENERATED-SENTINEL"
}
t_render_unknown_mode_writes_nothing() {
  T=render_unknown_mode_writes_nothing; mkrepo shared; echo '[]' >"$GHOUT"; note draft feat/d
  MODE=everyone render; eq "$?" 0
  eq "$(ls "$R/.scaffold/.hookstate" | wc -l | tr -d ' ')" 0; if [ -e "$R/.scaffold/STATUS.md" ]; then bad "STATUS written"; else ok; fi
}
t_render_shared_ignores_uncommitted_edit() {
  T=render_shared_ignores_uncommitted_edit; mkrepo shared; echo '[]' >"$GHOUT"
  note pub feat/p COMMITTED-STATUS; commit_note pub; note pub feat/p DRAFT-EDIT
  MODE=shared render
  eq "$(board '.now[0].status')" "COMMITTED-STATUS"
}
t_render_malformed_markers_keep_hand_text() {
  T=render_malformed_markers_keep_hand_text; mkrepo local; echo '[]' >"$GHOUT"; note a feat/a
  printf 'HAND1\n<!-- /scaffold:generated -->\nHAND2\n<!-- scaffold:generated -->\n' >"$R/.scaffold/STATUS.md"
  render || bad "END-before-BEGIN failed"; render; s=$(cat "$R/.scaffold/STATUS.md"); has "$s" HAND1; has "$s" HAND2
  printf 'HAND3\n<!-- scaffold:generated -->\nHAND4\n' >"$R/.scaffold/STATUS.md"
  render || bad "orphan BEGIN failed"; render; s=$(cat "$R/.scaffold/STATUS.md"); has "$s" HAND3; has "$s" HAND4
}
t_render_shared_non_ascii_note_name() {
  T=render_shared_non_ascii_note_name; mkrepo shared; echo '[]' >"$GHOUT"
  printf 'status: s\nbranch: feat/u\nwaiting-on: n\nnext: x\n' >"$R/.scaffold/work/active/ä.md"
  git -C "$R" add -f ".scaffold/work/active/ä.md"; git -C "$R" commit -qm u
  MODE=shared render; eq "$(board '[.now[].task] | join(",")')" "ä"
}
t_render_invalid_utf8_note() {
  T=render_invalid_utf8_note; mkrepo local; echo '[]' >"$GHOUT"
  printf 'status: bad\xff\xfe\nbranch: feat/a\n' >"$R/.scaffold/work/active/bad.md"
  render || bad "render failed on invalid UTF-8"; eq "$(board '.now[0].task')" bad
  git -C "$R" add -f .scaffold/work/active/bad.md; git -C "$R" commit -qm bad
  MODE=shared render || bad "shared render failed on invalid UTF-8"; eq "$(board '.now[0].task')" bad
}
t_render_parses_like_bash() {
  T=render_parses_like_bash; mkrepo local; echo '[]' >"$GHOUT"
  printf 'status: a\fb\nbranch: feat/a\xc2\xa0x, feat/b;feat/c\vd\n' >"$R/.scaffold/work/active/p.md"
  render; . "$R/.scaffold/hooks/lib.sh"; f="$R/.scaffold/work/active/p.md"
  eq "$(board '.now[0].branches | join("|")')" "$(header "$f" branch | branch_tokens | paste -sd'|' -)"
  eq "$(board '.now[0].status')" "$(header "$f" status)"
}

catchup() { SCAFFOLD_TODAY="${SCAFFOLD_TODAY-2026-11-04}" PATH="$FAKEBIN:$PATH" python3 -I "$R/.scaffold/hooks/catchup.py" "$R"; }
t_catchup_unclaimed() {
  T=catchup_unclaimed; mkrepo local; note mine feat/mine
  echo '[{"number":1,"title":"mine","headRefName":"feat/mine","mergedAt":"2026-11-03T10:00:00Z","author":{"login":"me"}},{"number":2,"title":"theirs","headRefName":"feat/theirs","mergedAt":"2026-11-03T11:00:00Z","author":{"login":"ann"}}]' >"$GHOUT"
  catchup; catchup
  eq "$(jq -r '[.[].number] | join(",")' "$R/.scaffold/.hookstate/unclaimed.json")" "2"
  eq "$(cat "$R/.scaffold/.hookstate/catchup-since")" "2026-11-04"
  note theirs-now feat/theirs
  catchup
  eq "$(jq -r 'length' "$R/.scaffold/.hookstate/unclaimed.json")" "0"
  PATH="$FAKEBIN:$PATH" python3 -I "$R/.scaffold/hooks/render.py" "$R" main local
  lacks "$(cat "$R/.scaffold/STATUS.md")" "Merged without a work note"
}
t_catchup_full_day_is_retried() {
  T=catchup_full_day_is_retried; mkrepo local
  echo 2026-11-01 >"$R/.scaffold/.hookstate/catchup-since"
  echo '[{"number":3,"title":"a","headRefName":"x/a","mergedAt":"2026-11-01T10:00:00Z","author":{"login":"a"}}]' >"$GHOUT.1"
  echo '[{"number":9,"title":"z","headRefName":"x/z","mergedAt":"2026-11-02T10:00:00Z","author":{"login":"z"}},{"number":4,"title":"b","headRefName":"x/b","mergedAt":"2026-11-02T20:00:00Z","author":{"login":"b"}}]' >"$GHOUT.2"
  echo '[]' >"$GHOUT"
  SCAFFOLD_CATCHUP_LIMIT=2 catchup
  eq "$(cat "$R/.scaffold/.hookstate/catchup-since")" "2026-11-02"
  eq "$(jq -r '[.[].number] | join(",")' "$R/.scaffold/.hookstate/unclaimed.json")" "9,4,3"
  eq "$(wc -l <"$BASE/gh.calls" | tr -d ' ')" "4"
  has "$(sed -n 2p "$BASE/gh.calls")" "merged:2026-11-02 "
}
t_catchup_window_is_per_utc_day() {
  T=catchup_window_is_per_utc_day; mkrepo local; echo '[]' >"$GHOUT"
  catchup
  eq "$(wc -l <"$BASE/gh.calls" | tr -d ' ')" "15"
  has "$(sed -n 1p "$BASE/gh.calls")" "merged:2026-10-21 "
  has "$(sed -n 15p "$BASE/gh.calls")" "merged:2026-11-04 "
  eq "$(cat "$R/.scaffold/.hookstate/catchup-since")" "2026-11-04"
}
t_catchup_caps_gap() {
  T=catchup_caps_gap; mkrepo local; echo '[]' >"$GHOUT"; echo 2026-01-01 >"$R/.scaffold/.hookstate/catchup-since"
  catchup
  eq "$(wc -l <"$BASE/gh.calls" | tr -d ' ')" "32"
  has "$(sed -n 1p "$BASE/gh.calls")" "merged:2026-10-04 "
}
t_catchup_uses_utc_date() {
  T=catchup_uses_utc_date; mkrepo local; echo '[]' >"$GHOUT"
  for tz in Pacific/Kiritimati Pacific/Pago_Pago; do
    rm -f "$R/.scaffold/.hookstate/catchup-since"
    TZ=$tz SCAFFOLD_TODAY='' catchup
    eq "$(cat "$R/.scaffold/.hookstate/catchup-since")" "$(date -u +%F)"
  done
}
t_catchup_gh_failure_writes_nothing() {
  T=catchup_gh_failure_writes_nothing; mkrepo local; rm -f "$GHOUT"
  catchup; eq "$?" "0"
  if [ -e "$R/.scaffold/.hookstate/catchup-since" ]; then bad "cursor written on gh failure"; else ok; fi
}

# --- runner ---
for T in $(declare -F | awk '{print $3}' | grep '^t_' | grep -- "${1:-}"); do "$T"; done
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
