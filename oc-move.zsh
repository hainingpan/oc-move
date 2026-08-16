# Move an opencode session + its subagents to another folder (no built-in exists).
# import re-scopes to the CWD and needs a git repo WITH a commit, else it lands in
# "global"; the SQL drags subagents along since export omits them (anomalyco/opencode#40352).
# Usage:  oc-move <session-id> <destination-folder>
oc-move() {
  # ${1-} not $1, so the usage message still works under `set -u` / setopt nounset.
  # resolve the DB the same way opencode itself does, so tests can isolate via XDG_DATA_HOME
  local sid=${1-} dst=${2-} db=${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db
  [[ -n $sid && -n $dst ]] || { print -u2 "usage: oc-move <session-id> <folder>"; return 1 }
  # the session plus every subagent it spawned - these all move together
  local fam="WITH RECURSIVE d(id) AS (SELECT '$sid'
      UNION ALL SELECT s.id FROM session s JOIN d ON s.parent_id=d.id)"
  # Must go via a file: `opencode export` truncates its own stdout when piped.
  local tmp=${TMPDIR:-/tmp}/oc-move.$$.json
  opencode export $sid > $tmp || { rm -f $tmp; return 1 }
  mkdir -p $dst || { rm -f $tmp; return 1 }
  local dstr=$(cd $dst && pwd -P) || { rm -f $tmp; return 1 }
  # `git init` promotes this dir to a project, and opencode then absorbs every
  # "global" session already living here - bumping their timestamps and reordering
  # your session list. Snapshot the family AND those bystanders, restore at the end;
  # then being absorbed is harmless (they belong to this directory anyway).
  local ts=$(sqlite3 $db "$fam SELECT 'UPDATE session SET time_updated='||time_updated||
      ' WHERE id='''||id||''';' FROM session WHERE id IN (SELECT id FROM d) OR directory='$dstr';")
  local n=$(sqlite3 $db "$fam SELECT COUNT(*) FROM session
      WHERE directory='$dstr' AND id NOT IN (SELECT id FROM d);")
  if [[ ! -d $dstr/.git ]]; then
    # Making $HOME (or /) a repo makes every subdirectory look like it is inside one,
    # which breaks git, shell prompts and opencode's own project detection.
    if [[ $dstr == $HOME || $dstr == / ]]; then
      print -u2 "refusing to git init $dstr - choose a real project folder"; rm -f $tmp; return 1
    fi
    ( cd $dstr && git init -q && git commit -q --allow-empty -m init ) || { rm -f $tmp; return 1 }
  fi
  ( cd $dstr && opencode import $tmp ) || { rm -f $tmp; return 1 }
  rm -f $tmp
  (( n )) && print "note: $n session(s) already in $dstr joined this project (timestamps preserved)"
  sqlite3 $db "$fam
    UPDATE session SET project_id=(SELECT project_id FROM session WHERE id='$sid'),
                       directory =(SELECT directory  FROM session WHERE id='$sid')
     WHERE id IN (SELECT id FROM d) AND id<>'$sid';
    SELECT 'moved $sid +'||changes()||' subagents -> '||directory FROM session WHERE id='$sid';
    $ts"
}
