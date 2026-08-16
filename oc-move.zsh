# Move an opencode session + its subagents to another folder (no built-in exists).
# import re-scopes to the CWD and needs a git repo WITH a commit, else it lands in
# "global"; the SQL drags subagents along since export omits them (anomalyco/opencode#40352).
# Usage:  oc-move ses_4f1c9a2e7b3d8Kp2QmXvNhTzLd ~/projects/my-app
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
  # remember the family's timestamps; the import/re-scope would otherwise bump them
  local ts=$(sqlite3 $db "$fam SELECT 'UPDATE session SET time_updated='||time_updated||
      ' WHERE id='''||id||''';' FROM session WHERE id IN (SELECT id FROM d);")
  mkdir -p $dst || { rm -f $tmp; return 1 }
  ( cd $dst || exit 1
    if [[ ! -d .git ]]; then
      # git init promotes this dir to a project, dragging every UNRELATED "global"
      # session that already lives here along with it and bumping their timestamps.
      local n=$(sqlite3 $db "$fam SELECT COUNT(*) FROM session
        WHERE directory='${PWD:A}' AND id NOT IN (SELECT id FROM d);")
      (( n )) && { print -u2 "abort: $n unrelated sessions live in $PWD; git init would re-scope them"; exit 1 }
      git init -q && git commit -q --allow-empty -m init
    fi
    opencode import $tmp ) || { rm -f $tmp; return 1 }
  rm -f $tmp
  sqlite3 $db "$fam
    UPDATE session SET project_id=(SELECT project_id FROM session WHERE id='$sid'),
                       directory =(SELECT directory  FROM session WHERE id='$sid')
     WHERE id IN (SELECT id FROM d) AND id<>'$sid';
    SELECT 'moved $sid +'||changes()||' subagents -> '||directory FROM session WHERE id='$sid';
    $ts"
}
