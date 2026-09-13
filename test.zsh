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

# Safety net. A bug in oc-move (bare `cd` with an empty argument goes to $HOME) once
# git-init'd the developer's home directory from inside this very suite. No test may
# create $HOME/.git; if one does, fail loudly and undo it. Only removes a .git that
# appeared during the run - a pre-existing one is left strictly alone.
HOME_GIT_BEFORE=0; [[ -d $HOME/.git ]] && HOME_GIT_BEFORE=1
home_git_guard() {
  (( HOME_GIT_BEFORE )) && return 0
  [[ -d $HOME/.git ]] || return 0
  rm -rf $HOME/.git
  bad "created \$HOME/.git (removed) - the bare-cd regression is back"
}

setup() {
  # non-interactive ssh often lacks /opt/homebrew/bin; fail with a useful message
  for bin in opencode sqlite3 git; do
    whence -p $bin >/dev/null || {
      print -u2 "FATAL: '$bin' not on PATH. Try: export PATH=/opt/homebrew/bin:\$PATH"; exit 2 }
  done
  rm -rf $RUN; mkdir -p $RUN
  export XDG_DATA_HOME=$RUN/data
  export TMPDIR=$RUN/tmp; mkdir -p $TMPDIR
  DB=$XDG_DATA_HOME/opencode/opencode.db
  # let opencode create the schema in the scratch location
  ( cd $RUN && opencode session list ) >/dev/null 2>&1
  [[ -f $DB ]] || { print -u2 "FATAL: scratch DB not created at $DB"; exit 2 }
  remote_setup
  source $ROOT/oc-move.zsh
}

# ---------------------------------------------------------------- the "other machine"
# The cross-machine path is exercised without sshd or a second box: a stand-in `ssh` sits
# first on PATH. It drops the options and the host and runs the command string the way the
# remote login shell would (zsh -c), inside an environment shaped like a non-interactive
# ssh session - sshd's bare PATH, no XDG_DATA_HOME, and a HOME of its own. So the "remote"
# opencode is the same binary but keeps a separate database under $RHOME, and it is NOT on
# PATH over there: oc-move has to find it the way it would on a real machine.
# OC_TEST_SSH_RC short-circuits the whole connection with that exit code, to play a dead
# host (255) or a preflight verdict we cannot stage for real - the real binary cannot be
# hidden from a fake remote that lives on the same disk.
RHOME=$RUN/rhome
RDB=$RHOME/.local/share/opencode/opencode.db
remote_setup() {
  mkdir -p $RHOME/.opencode/bin $RUN/bin
  ln -sf "$(whence -p opencode)" $RHOME/.opencode/bin/opencode   # where the official installer puts it
  export OC_TEST_RHOME=$RHOME
  cat > $RUN/bin/ssh <<'EOF'
#!/usr/bin/env zsh
# fake ssh for test.zsh - see remote_setup there
[[ -n ${OC_TEST_SSH_RC-} ]] && exit $OC_TEST_SSH_RC
nostdin=
while (( $# )); do
  case $1 in
    -n) nostdin=1; shift ;;
    --) shift; break ;;
    -o|-p|-l|-i|-F) shift 2 ;;
    -*) shift ;;
    *)  break ;;
  esac
done
shift   # the host
export HOME=$OC_TEST_RHOME SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset XDG_DATA_HOME
cd "$HOME" || exit 255   # sshd starts every session in the home directory
[[ -n $nostdin ]] && exec zsh -c "$*" </dev/null
exec zsh -c "$*"
EOF
  chmod +x $RUN/bin/ssh
  path=($RUN/bin $path); rehash
  [[ $(whence -p ssh) == $RUN/bin/ssh ]] || { print -u2 "FATAL: fake ssh not first on PATH"; exit 2 }
}
# the remote database only exists once opencode has run over there
remote_db_init() { ( unset XDG_DATA_HOME; HOME=$RHOME opencode session list ) >/dev/null 2>&1; }
rq() { sqlite3 "$RDB" "$1"; }
rdb_fingerprint() { [[ -f $RDB ]] || { print "absent"; return 0 }; stat -c '%Y %s' "$RDB" 2>/dev/null || stat -f '%m %z' "$RDB"; }

MODEL='{"id":"claude-opus-5","providerID":"anthropic","variant":"max"}'

# seed_session <id> <parent|-> <directory> <title> <ts_ms> [body_chars] [project]
# project defaults to 'seedproj'. Use 'global' to model a session in opencode's
# catch-all - only those get absorbed when a directory becomes a git project.
# Seeds the local scratch DB; SEED_DB=$RDB seed_session ... plants a row on the "remote".
seed_session() {
  local id=$1 parent=$2 dir=$3 title=$4 ts=$5 chars=${6:-8} proj=${7:-seedproj}
  local psql; [[ $parent == "-" ]] && psql=NULL || psql="'$parent'"
  local body; body=$(head -c $chars < /dev/zero | tr '\0' 'x')
  sqlite3 "${SEED_DB:-$DB}" "
    INSERT OR IGNORE INTO project (id,worktree,vcs,name,time_created,time_updated,sandboxes)
      VALUES ('seedproj','$RUN/seedsrc','git','seed',$ts,$ts,'[]');
    INSERT OR IGNORE INTO project (id,worktree,vcs,name,time_created,time_updated,sandboxes)
      VALUES ('global','/','git','global',$ts,$ts,'[]');
    INSERT INTO session (id,project_id,parent_id,slug,directory,title,version,
                         time_created,time_updated,agent,model)
      VALUES ('$id','$proj',$psql,'s-$id','$dir','$title','1.18.18',$ts,$ts,'build',json('$MODEL'));
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

t7_bystanders_absorbed_but_not_reordered() {
  # The ~/.git disaster was 274 sessions being re-scoped AND jumping to "today".
  # Blocking the move was the wrong cure - it stopped legitimate moves into any folder
  # that happened to already hold an unrelated session tree.
  # Correct contract: the move proceeds, bystanders get grouped into the project that
  # matches the directory they already live in, and NO timestamp changes.
  local dest=$RUN/t7dest; mkdir -p $dest
  local d=$(cd $dest && pwd -P)
  seed_session ses_t7root  - $RUN/src "t7 root"      1700000000000
  # bystander sits in the 'global' catch-all - only those get absorbed, as in the real case
  seed_session ses_t7other - $d       "t7 bystander" 1700000005000 8 global
  local out rc
  out=$(oc-move ses_t7root $dest 2>&1); rc=$?
  check "move proceeds" "$rc" "0"
  check "bystander timestamp NOT bumped" "$(q "SELECT time_updated FROM session WHERE id='ses_t7other'")" "1700000005000"
  check "moved session landed" "$(q "SELECT directory FROM session WHERE id='ses_t7root'")" "$d"
  # bystander should now share the destination's project rather than sitting in the catch-all
  check "bystander grouped with dir" \
    "$(q "SELECT (SELECT project_id FROM session WHERE id='ses_t7other')=(SELECT project_id FROM session WHERE id='ses_t7root')")" "1"
  if [[ $out == *"joined this project"* ]]; then ok "reports what it absorbed"; else bad "no note about bystanders - got [$out]"; fi
}

t11_refuses_home() {  # the actual hazard: $HOME as a git repo breaks every subdirectory
  seed_session ses_t11root - $RUN/src "t11" 1700000000000
  local out rc
  out=$(oc-move ses_t11root "$HOME" 2>&1); rc=$?
  check "refuses \$HOME" "$rc" "1"
  if [[ $out == *refusing* ]]; then ok "explains refusal"; else bad "no refusal message - got [$out]"; fi
  if [[ -d $HOME/.git ]]; then bad "MUST NOT create ~/.git"; else ok "no ~/.git created"; fi
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

t12_unreachable_dest_must_not_init_caller() {
  # `local dstr=$(cd $dst && pwd -P) || ...` : the exit status is `local`'s, NOT the
  # command substitution's, so that `||` guard was dead code. dstr ended up empty, and
  # in zsh `cd ""` SUCCEEDS and stays put - so the git init landed in the CALLER's
  # directory. That is precisely the ~/.git disaster, still reachable.
  # mkdir -p succeeds on an existing dir regardless of its mode; cd then fails on 000.
  seed_session ses_t12root - $RUN/src "t12" 1700000000000
  local dest=$RUN/t12dest; mkdir -p $dest; chmod 000 $dest
  local caller=$RUN/t12caller; mkdir -p $caller
  local out rc
  out=$( cd $caller && oc-move ses_t12root $dest 2>&1 ); rc=$?
  chmod 755 $dest   # restore so cleanup can remove it
  check "unreachable dest exits 1" "$rc" "1"
  if [[ -d $caller/.git ]]; then bad "MUST NOT git init the caller's directory"
  else ok "caller's directory left alone"; fi
  local -a leftover=( $TMPDIR/oc-move.*.json(N) )
  check "no temp file left on the failure path" "${#leftover}" "0"
}

t13_path_with_space_and_apostrophe() {
  # Every path was unquoted: a directory containing a space split into two arguments,
  # and one containing ' broke out of the surrounding SQL string literal.
  seed_session ses_t13root - $RUN/src "t13" 1700000000000
  local dest="$RUN/t13 John's dest"
  local out rc
  out=$(oc-move ses_t13root "$dest" 2>&1); rc=$?
  check "move succeeds with space + apostrophe" "$rc" "0"
  check "landed at the exact path" "$(q "SELECT directory FROM session WHERE id='ses_t13root'")" "${dest:A}"
}

t10_messages_survive() {
  seed_session ses_t10root - $RUN/src "t10" 1700000000000
  local before=$(q "SELECT COUNT(*) FROM message WHERE session_id='ses_t10root'")
  oc-move ses_t10root $RUN/t10dest >/dev/null 2>&1
  check "messages preserved" "$(q "SELECT COUNT(*) FROM message WHERE session_id='ses_t10root'")" "$before"
}

# ---------------------------------------------------------------- remote: <[user@]host:path>

last_line() { print -r -- "${1##*$'\n'}" }
no_leftovers() {  # both ends use $TMPDIR here: ours is oc-move.*, the remote's is mktemp's tmp.*
  local -a l=( $TMPDIR/oc-move.*(N) $TMPDIR/tmp.*(N) )
  check "$1: no temp files on either end" "${#l}" "0"
}

t14_remote_path_not_accessible() {
  # The first thing the remote form does is test the path; a missing folder, or a host
  # ssh cannot reach at all (exit 255), must stop everything before the export even
  # runs. The sentence is the contract.
  seed_session ses_t14root - $RUN/src "t14" 1700000000000
  local before=$(rdb_fingerprint) out rc
  out=$(oc-move ses_t14root me@fake:$RUN/does-not-exist 2>&1); rc=$?
  check "missing remote folder exits 1" "$rc" "1"
  check "and says exactly why" "$(last_line "$out")" "Destination path is not accessible."
  check "remote DB untouched" "$(rdb_fingerprint)" "$before"
  out=$(OC_TEST_SSH_RC=255 oc-move ses_t14root me@fake:$RUN 2>&1); rc=$?
  check "unreachable host exits 1" "$rc" "1"
  check "reads the same way" "$(last_line "$out")" "Destination path is not accessible."
  # a bad session id passes preflight, then export fails - still nothing may happen over there
  local dest=$RUN/t14rdest; mkdir -p $dest
  oc-move ses_DOESNOTEXIST0000000000000 me@fake:$dest >/dev/null 2>&1; rc=$?
  check "bad id exits 1" "$rc" "1"
  if [[ -d $dest/.git ]]; then bad "bad id must not git init the remote folder"; else ok "remote folder left alone"; fi
  no_leftovers t14
}

t15_remote_without_opencode() {
  # "do nothing if the remote does not even have opencode": the preflight reports it
  # (exit 4) and no payload is built or shipped, no folder is made a project.
  seed_session ses_t15root - $RUN/src "t15" 1700000000000
  local dest=$RUN/t15rdest; mkdir -p $dest
  local before=$(rdb_fingerprint) out rc
  out=$(OC_TEST_SSH_RC=4 oc-move ses_t15root me@fake:$dest 2>&1); rc=$?
  check "exits 1" "$rc" "1"
  if [[ $out == *"opencode not found on me@fake"* ]]; then ok "names the problem and the host"; else bad "message - got [$out]"; fi
  if [[ -d $dest/.git ]]; then bad "must not git init the remote folder"; else ok "remote folder left alone"; fi
  check "remote DB untouched" "$(rdb_fingerprint)" "$before"
  no_leftovers t15
}

t16_remote_tree_moves() {
  # Over there the subagent rows do not exist, so every family member has to travel -
  # the local move only re-points rows. opencode is NOT on the remote's PATH (sshd's bare
  # PATH); it has to be detected and then run by its found path.
  seed_session ses_t16root - $RUN/src "t16 root"       1700000000000
  seed_session ses_t16kid  ses_t16root $RUN/src "t16 child"  1700000001000
  seed_session ses_t16gkid ses_t16kid  $RUN/src "t16 grandchild" 1700000002000 300000
  local dest=$RUN/t16rdest; mkdir -p $dest
  local d=$(cd $dest && pwd -P) out rc
  out=$(oc-move ses_t16root me@fake:$dest 2>&1); rc=$?
  check "move succeeds" "$rc" "0"
  if [[ $out == *"opencode $(opencode --version) at "* ]]; then ok "reports the detected opencode"; else bad "no detection report - got [$out]"; fi
  check "root landed"       "$(rq "SELECT directory FROM session WHERE id='ses_t16root'")" "$d"
  check "child landed"      "$(rq "SELECT directory FROM session WHERE id='ses_t16kid'")"  "$d"
  check "grandchild landed" "$(rq "SELECT directory FROM session WHERE id='ses_t16gkid'")" "$d"
  check "parent links intact" "$(rq "SELECT parent_id||'<'||id FROM session WHERE id LIKE 'ses_t16%' AND parent_id IS NOT NULL ORDER BY id")" $'ses_t16kid<ses_t16gkid\nses_t16root<ses_t16kid'
  check "one project"         "$(rq "SELECT COUNT(DISTINCT project_id) FROM session WHERE id LIKE 'ses_t16%'")" "1"
  check "timestamps preserved" "$(rq "SELECT group_concat(time_updated) FROM (SELECT time_updated FROM session WHERE id LIKE 'ses_t16%' ORDER BY id)")" "1700000002000,1700000001000,1700000000000"
  check "300KB body survived the trip" "$(rq "SELECT LENGTH(json_extract(data,'\$.text')) FROM part WHERE session_id='ses_t16gkid'")" "300000"
  if [[ $out == *"moved ses_t16root +2 subagents -> me@fake:$d"* ]]; then ok "reports the move"; else bad "summary line - got [$out]"; fi
  if [[ -d $dest/.git ]]; then ok "remote folder became a project"; else bad "remote folder not git-init'd"; fi
  check "local copy kept (deleting is the user's call)" "$(q "SELECT COUNT(*) FROM session WHERE id LIKE 'ses_t16%' AND directory='$RUN/src'")" "3"
  if [[ $out == *"opencode session delete ses_t16root"* ]]; then ok "tells how to drop the local copy"; else bad "no cleanup hint - got [$out]"; fi
  no_leftovers t16
}

t17_remote_rerun_and_bystanders() {
  # Migrating the same session again is an in-place update over there, and that bumps
  # time_updated to "now" (verified) - the shipped fix.sql must put it back. A 'global'
  # session already living in that remote folder gets absorbed when it becomes a project;
  # its timestamp must survive too. t7's contract, enforced on the other machine.
  seed_session ses_t17root - $RUN/src "t17 root"  1700000000000
  seed_session ses_t17kid ses_t17root $RUN/src "t17 child" 1700000001000
  local dest=$RUN/t17rdest; mkdir -p $dest
  local d=$(cd $dest && pwd -P) out1 out2 rc
  remote_db_init
  SEED_DB=$RDB seed_session ses_t17other - $d "t17 bystander" 1700000005000 8 global
  out1=$(oc-move ses_t17root me@fake:$dest 2>&1)
  out2=$(oc-move ses_t17root me@fake:$dest 2>&1); rc=$?
  check "second trip succeeds" "$rc" "0"
  check "root ts restored after re-import"  "$(rq "SELECT time_updated FROM session WHERE id='ses_t17root'")" "1700000000000"
  check "child ts restored after re-import" "$(rq "SELECT time_updated FROM session WHERE id='ses_t17kid'")"  "1700000001000"
  check "bystander ts NOT bumped" "$(rq "SELECT time_updated FROM session WHERE id='ses_t17other'")" "1700000005000"
  check "bystander grouped with dir" \
    "$(rq "SELECT (SELECT project_id FROM session WHERE id='ses_t17other')=(SELECT project_id FROM session WHERE id='ses_t17root')")" "1"
  if [[ $out1 == *"1 session(s) already in $d joined this project"* ]]; then ok "reports what it absorbed"; else bad "no bystander note - got [$out1]"; fi
  check "still one copy of each over there" "$(rq "SELECT COUNT(*) FROM session WHERE id LIKE 'ses_t17%'")" "3"
}

t18_remote_path_with_space_dollar_apostrophe() {
  # The path crosses three shells (our zsh, the remote login shell, sh) and a SQL literal.
  # One of them mis-quoting it lands the session somewhere else, or nowhere.
  seed_session ses_t18root - $RUN/src "t18" 1700000000000
  local dest="$RUN/t18 \$x John's remote"; mkdir -p "$dest"
  local out rc
  out=$(oc-move ses_t18root "me@fake:$dest" 2>&1); rc=$?
  check "succeeds with space, \$ and apostrophe" "$rc" "0"
  check "landed at the exact path" "$(rq "SELECT directory FROM session WHERE id='ses_t18root'")" "${dest:A}"
}

t19_remote_home_and_tilde() {
  # `host:` and `host:~` are the remote home directory, as in scp - the one folder we
  # must never git init (t11, over there). `~/x` must resolve under the REMOTE home.
  seed_session ses_t19root - $RUN/src "t19" 1700000000000
  local out rc
  out=$(oc-move ses_t19root 'me@fake:~' 2>&1); rc=$?
  check "host:~ refused" "$rc" "1"
  if [[ $out == *refusing* ]]; then ok "explains refusal"; else bad "no refusal message - got [$out]"; fi
  out=$(oc-move ses_t19root 'me@fake:' 2>&1); rc=$?
  check "host: refused" "$rc" "1"
  if [[ -d $RHOME/.git ]]; then bad "MUST NOT git init the remote home"; else ok "no remote ~/.git created"; fi
  mkdir -p $RHOME/proj
  out=$(oc-move ses_t19root 'me@fake:~/proj' 2>&1); rc=$?
  check "host:~/proj works" "$rc" "0"
  check "resolved under the remote home" "$(rq "SELECT directory FROM session WHERE id='ses_t19root'")" "${RHOME:A}/proj"
}

# ---------------------------------------------------------------- runner

ALL=(t1_usage t2_bad_session_id t3_tree_moves t4_large_payload t5_pwd_no_leak
     t6_family_already_in_dest t7_bystanders_absorbed_but_not_reordered t8_timestamps_preserved
     t9_tempfile_cleaned t10_messages_survive t11_refuses_home
     t12_unreachable_dest_must_not_init_caller t13_path_with_space_and_apostrophe
     t14_remote_path_not_accessible t15_remote_without_opencode t16_remote_tree_moves
     t17_remote_rerun_and_bystanders t18_remote_path_with_space_dollar_apostrophe
     t19_remote_home_and_tilde)

WANT=($@)
setup
for t in $ALL; do
  if (( $#WANT )); then [[ " ${WANT[*]} " == *" ${t%%_*} "* ]] || continue; fi
  CURRENT=$t
  print "\033[1m$t\033[0m"
  $t
  home_git_guard
done

# the whole point: prove we never touched the real database
CURRENT=isolation
print "\033[1misolation\033[0m"
check "real DB untouched" "$(real_db_fingerprint)" "$REAL_BEFORE"

print ""
print "passed: $PASS   failed: $FAIL"
(( FAIL )) && { print "failures:"; printf '  %s\n' $FAILED; exit 1 }
print "\033[32mall green\033[0m"; exit 0
