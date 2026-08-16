#!/usr/bin/env zsh
# Regression suite for oc-move.
#
# Runs FULLY ISOLATED: XDG_DATA_HOME points at a scratch dir, so `opencode`
# and oc-move both use a throwaway database. Your real ~/.local/share/opencode
# is never opened. Verified by check_real_db_untouched at the end.
#
# Every test here corresponds to a bug that actually shipped. Do not delete one
# without understanding which failure it was protecting against.
#
# Usage:  ./test.zsh          (all tests)
#         ./test.zsh t7 t8    (only named tests)

set -u
ROOT=${0:A:h}
RUN=$ROOT/.testrun
REAL_DB=$HOME/.local/share/opencode/opencode.db
PASS=0 FAIL=0 FAILED=()

# ---------------------------------------------------------------- infrastructure

# mtime+size. GNU coreutils (-c) and BSD (-f) disagree; this box has GNU first on PATH.
real_db_fingerprint() {
  [[ -f $REAL_DB ]] || { print "absent"; return 0 }
  stat -c '%Y %s' "$REAL_DB" 2>/dev/null || stat -f '%m %z' "$REAL_DB"
}
REAL_BEFORE=$(real_db_fingerprint)

setup() {
  rm -rf $RUN; mkdir -p $RUN
  export XDG_DATA_HOME=$RUN/data
  export TMPDIR=$RUN/tmp; mkdir -p $TMPDIR
  DB=$XDG_DATA_HOME/opencode/opencode.db
  # let opencode create the schema in the scratch location
  ( cd $RUN && opencode session list ) >/dev/null 2>&1
  [[ -f $DB ]] || { print -u2 "FATAL: scratch DB not created at $DB"; exit 2 }
  source $ROOT/oc-move.zsh
}

MODEL='{"id":"claude-opus-5","providerID":"anthropic","variant":"max"}'

# seed_session <id> <parent|-> <directory> <title> <ts_ms> [body_chars]
seed_session() {
  local id=$1 parent=$2 dir=$3 title=$4 ts=$5 chars=${6:-8}
  local psql; [[ $parent == "-" ]] && psql=NULL || psql="'$parent'"
  local body; body=$(head -c $chars < /dev/zero | tr '\0' 'x')
  sqlite3 "$DB" "
    INSERT OR IGNORE INTO project (id,worktree,vcs,name,time_created,time_updated,sandboxes)
      VALUES ('seedproj','$RUN/seedsrc','git','seed',$ts,$ts,'[]');
    INSERT INTO session (id,project_id,parent_id,slug,directory,title,version,
                         time_created,time_updated,agent,model)
      VALUES ('$id','seedproj',$psql,'s-$id','$dir','$title','1.18.18',$ts,$ts,'build',json('$MODEL'));
    INSERT INTO message (id,session_id,time_created,time_updated,data)
      VALUES ('msg_$id','$id',$ts,$ts, json('{\"role\":\"user\",\"time\":{\"created\":$ts},\"agent\":\"build\",\"model\":{\"providerID\":\"anthropic\",\"modelID\":\"claude-opus-5\",\"variant\":\"max\"},\"summary\":{\"diffs\":[]}}'));
    INSERT INTO part (id,message_id,session_id,time_created,time_updated,data)
      VALUES ('prt_$id','msg_$id','$id',$ts,$ts, json_object('type','text','text','$body'));"
}

q() { sqlite3 "$DB" "$1"; }

# NOTE: these must `return 0` explicitly. `(( PASS++ ))` evaluates to the OLD value,
# so it returns non-zero status when PASS is 0 - which in an `a && b || c` chain made
# a passing check also run the failure branch. Do not "simplify" check() back to &&/||.
ok()   { print "  \033[32mPASS\033[0m $1"; (( PASS++ )); return 0 }
bad()  { print "  \033[31mFAIL\033[0m $1"; (( FAIL++ )); FAILED+=("$CURRENT: $1"); return 0 }
check(){ if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1 - expected [$3] got [$2]"; fi }
yes_no(){ if [[ -n "$2" ]]; then ok "$1"; else bad "$1"; fi }

# ---------------------------------------------------------------- tests

t1_usage() {  # guard must not fire on a legitimate call, and must fire on empty args
  local out rc
  out=$(oc-move 2>&1); rc=$?
  check "no args exits 1" "$rc" "1"
  if [[ $out == *usage* ]]; then ok "no args prints usage"; else bad "no args prints usage - got [$out]"; fi
}

t2_bad_session_id() {  # must abort BEFORE creating the destination folder
  local dest=$RUN/t2dest rc
  oc-move ses_DOESNOTEXIST0000000000000 $dest >/dev/null 2>&1; rc=$?
  check "bad id exits 1" "$rc" "1"
  if [[ -d $dest ]]; then bad "bad id must not create the folder"; else ok "bad id leaves no folder"; fi
}

t3_tree_moves() {  # root + child + GRANDCHILD (recursive CTE)
  seed_session ses_t3root - $RUN/src "t3 root" 1700000000000
  seed_session ses_t3kid  ses_t3root $RUN/src "t3 child" 1700000001000
  seed_session ses_t3gkid ses_t3kid  $RUN/src "t3 grandchild" 1700000002000
  local dest=$RUN/t3dest
  oc-move ses_t3root $dest >/dev/null 2>&1
  check "root moved"       "$(q "SELECT directory FROM session WHERE id='ses_t3root'")" "$dest:A"
  check "child moved"      "$(q "SELECT directory FROM session WHERE id='ses_t3kid'")"  "$dest:A"
  check "grandchild moved" "$(q "SELECT directory FROM session WHERE id='ses_t3gkid'")" "$dest:A"
  check "same project"     "$(q "SELECT COUNT(DISTINCT project_id) FROM session WHERE id LIKE 'ses_t3%'")" "1"
}

t4_large_payload() {  # `opencode export` truncates piped stdout at ~64-128KB
  seed_session ses_t4root - $RUN/src "t4 big" 1700000000000 400000
  oc-move ses_t4root $RUN/t4dest >/dev/null 2>&1
  check "400KB body survived" "$(q "SELECT LENGTH(json_extract(data,'\$.text')) FROM part WHERE session_id='ses_t4root'")" "400000"
}

t5_pwd_no_leak() {  # a failed cd used to leave the caller in the wrong dir -> git init in \$HOME
  seed_session ses_t5root - $RUN/src "t5" 1700000000000
  local before=$PWD
  oc-move ses_t5root $RUN/t5dest >/dev/null 2>&1
  check "PWD unchanged" "$PWD" "$before"
}

t6_family_already_in_dest() {  # guard counted the mover's own family as bystanders
  local dest=$RUN/t6dest; mkdir -p $dest
  local d=${dest:A}
  seed_session ses_t6root - $d "t6 root" 1700000000000
  seed_session ses_t6kid ses_t6root $d "t6 child" 1700000001000
  local out rc
  out=$(oc-move ses_t6root $dest 2>&1); rc=$?
  check "proceeds (not blocked by own family)" "$rc" "0"
  if [[ $out == *abort* ]]; then bad "must not abort on own family - got [$out]"; else ok "no false abort"; fi
}

t7_unrelated_bystanders_block() {  # the ~/.git disaster: 274 sessions swept
  local dest=$RUN/t7dest; mkdir -p $dest
  seed_session ses_t7root  - $RUN/src   "t7 root"      1700000000000
  seed_session ses_t7other - ${dest:A}  "t7 bystander" 1700000005000
  local out rc
  out=$(oc-move ses_t7root $dest 2>&1); rc=$?
  check "aborts" "$rc" "1"
  if [[ $out == *abort* ]]; then ok "prints abort reason"; else bad "no abort message - got [$out]"; fi
  if [[ -d $dest/.git ]]; then bad "must not git init on abort"; else ok "no .git created"; fi
  check "bystander project untouched" "$(q "SELECT project_id FROM session WHERE id='ses_t7other'")" "seedproj"
  check "bystander timestamp untouched" "$(q "SELECT time_updated FROM session WHERE id='ses_t7other'")" "1700000005000"
}

t8_timestamps_preserved() {  # user's core complaint: moves must not reorder the session list
  seed_session ses_t8root - $RUN/src "t8 root"  1700000011000
  seed_session ses_t8kid ses_t8root $RUN/src "t8 child" 1700000012000
  oc-move ses_t8root $RUN/t8dest >/dev/null 2>&1
  check "root ts preserved"  "$(q "SELECT time_updated FROM session WHERE id='ses_t8root'")" "1700000011000"
  check "child ts preserved" "$(q "SELECT time_updated FROM session WHERE id='ses_t8kid'")"  "1700000012000"
}

t9_tempfile_cleaned() {
  seed_session ses_t9root - $RUN/src "t9" 1700000000000
  oc-move ses_t9root $RUN/t9dest >/dev/null 2>&1
  local -a leftover=( $TMPDIR/oc-move.*.json(N) )   # (N) = null_glob, no error when empty
  check "no temp files left" "${#leftover}" "0"
}

t10_messages_survive() {
  seed_session ses_t10root - $RUN/src "t10" 1700000000000
  local before=$(q "SELECT COUNT(*) FROM message WHERE session_id='ses_t10root'")
  oc-move ses_t10root $RUN/t10dest >/dev/null 2>&1
  check "messages preserved" "$(q "SELECT COUNT(*) FROM message WHERE session_id='ses_t10root'")" "$before"
}

# ---------------------------------------------------------------- runner

ALL=(t1_usage t2_bad_session_id t3_tree_moves t4_large_payload t5_pwd_no_leak
     t6_family_already_in_dest t7_unrelated_bystanders_block t8_timestamps_preserved
     t9_tempfile_cleaned t10_messages_survive)

WANT=($@)
setup
for t in $ALL; do
  if (( $#WANT )); then [[ " ${WANT[*]} " == *" ${t%%_*} "* ]] || continue; fi
  CURRENT=$t
  print "\033[1m$t\033[0m"
  $t
done

# the whole point: prove we never touched the real database
CURRENT=isolation
print "\033[1misolation\033[0m"
check "real DB untouched" "$(real_db_fingerprint)" "$REAL_BEFORE"

print ""
print "passed: $PASS   failed: $FAIL"
(( FAIL )) && { print "failures:"; printf '  %s\n' $FAILED; exit 1 }
print "\033[32mall green\033[0m"; exit 0
