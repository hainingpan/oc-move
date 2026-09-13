# Move an opencode session + its subagents to another folder (no built-in exists).
# import re-scopes to the CWD and needs a git repo WITH a commit, else it lands in
# "global"; the SQL drags subagents along since export omits them (anomalyco/opencode#40352).
# Usage:  oc-move <session-id> <destination-folder>
#         oc-move <session-id> <[user@]host:destination-folder>     (another machine, via ssh)
oc-move() {
  # ${1-} not $1, so the usage message still works under `set -u` / setopt nounset.
  # resolve the DB the same way opencode itself does, so tests can isolate via XDG_DATA_HOME
  local sid=${1-} dst=${2-} db=${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db
  [[ -n $sid && -n $dst ]] || { print -u2 "usage: oc-move <session-id> <folder | [user@]host:folder>"; return 1 }
  # the session plus every subagent it spawned - these all move together
  local fam="WITH RECURSIVE d(id) AS (SELECT '$sid'
      UNION ALL SELECT s.id FROM session s JOIN d ON s.parent_id=d.id)"
  # scp's rule: a colon before any slash makes it host:path. Write ./a:b for a local dir named a:b.
  if [[ $dst == *:* && ${dst%%:*} != */* ]]; then
    local host=${dst%%:*} rpath=${dst#*:}
    [[ -n $host ]] || { print -u2 "empty host in $dst"; return 1 }
    # `host:` and `host:~` mean the remote home directory, `~/x` is relative to it - as in scp.
    # The remote `cd` starts in $HOME, so plain relative paths already land there.
    [[ $rpath == '~' || -z $rpath ]] && rpath=.
    rpath=${rpath/#\~\//}
    _oc-move-remote "$sid" "$db" "$fam" "$host" "$rpath"; return
  fi
  # Must go via a file: `opencode export` truncates its own stdout when piped.
  local tmp=${TMPDIR:-/tmp}/oc-move.$$.json
  opencode export "$sid" > "$tmp" || { rm -f "$tmp"; return 1 }
  mkdir -p -- "$dst" || { rm -f "$tmp"; return 1 }
  # Declare THEN assign. `local dstr=$(...)` reports *local's* exit status, not the
  # command substitution's, so this `||` used to be dead code: a failed cd left dstr
  # empty and execution carried on. Unquoted, an empty $dstr then disappears from the
  # argument list entirely - and a bare `cd` goes to $HOME, so the git init below
  # turned $HOME into a repo. Quote every path and refuse an empty result.
  local dstr; dstr=$(cd -- "$dst" && pwd -P) || { rm -f "$tmp"; return 1 }
  [[ -n $dstr ]] || { print -u2 "cannot resolve $dst"; rm -f "$tmp"; return 1 }
  # ' delimits SQL strings below; double it so a path like ~/John's dir can't break out
  local dsq=${dstr//\'/\'\'}
  # `git init` promotes this dir to a project, and opencode then absorbs every
  # "global" session already living here - bumping their timestamps and reordering
  # your session list. Snapshot the family AND those bystanders, restore at the end;
  # then being absorbed is harmless (they belong to this directory anyway).
  local ts=$(sqlite3 $db "$fam SELECT 'UPDATE session SET time_updated='||time_updated||
      ' WHERE id='''||id||''';' FROM session WHERE id IN (SELECT id FROM d) OR directory='$dsq';")
  local n=$(sqlite3 $db "$fam SELECT COUNT(*) FROM session
      WHERE directory='$dsq' AND id NOT IN (SELECT id FROM d);")
  if [[ ! -d "$dstr/.git" ]]; then
    # Making $HOME (or /) a repo makes every subdirectory look like it is inside one,
    # which breaks git, shell prompts and opencode's own project detection.
    if [[ $dstr == $HOME || $dstr == / ]]; then
      print -u2 "refusing to git init $dstr - choose a real project folder"; rm -f "$tmp"; return 1
    fi
    ( cd -- "$dstr" && git init -q && git commit -q --allow-empty -m init ) || { rm -f "$tmp"; return 1 }
  fi
  ( cd -- "$dstr" && opencode import "$tmp" ) || { rm -f "$tmp"; return 1 }
  rm -f "$tmp"
  (( n )) && print "note: $n session(s) already in $dstr joined this project (timestamps preserved)"
  sqlite3 $db "$fam
    UPDATE session SET project_id=(SELECT project_id FROM session WHERE id='$sid'),
                       directory =(SELECT directory  FROM session WHERE id='$sid')
     WHERE id IN (SELECT id FROM d) AND id<>'$sid';
    SELECT 'moved $sid +'||changes()||' subagents -> '||directory FROM session WHERE id='$sid';
    $ts"
}

# Single-quote a string for a POSIX sh: ' becomes '\''. Not zsh's ${(qq)..}: under
# setopt rcquotes that emits 'it''s', which sh reads as "its".
_oc-sq() { local q="'\\''"; print -r -- "'${1//\'/$q}'" }

# Same move, destination on another machine. Two ssh round trips: a read-only preflight,
# then one that ships the family as a tar stream and runs a generated script inside it.
# Nothing is created remotely (no folder, no .git, no temp file) until every check passed.
_oc-move-remote() {
  local sid=$1 db=$2 fam=$3 host=$4 rpath=$5
  # OC_MOVE_SSH="ssh -J jump -p 2222" for odd setups - the GIT_SSH_COMMAND / RSYNC_RSH convention
  local -a sshc; sshc=(${=OC_MOVE_SSH:-ssh})
  # ---- 1. preflight, side-effect free. Exit codes are the contract with the case below.
  # Deliberately no single quotes in here: the whole script travels as sh -c '...' through
  # the remote LOGIN shell (whatever it is), and only a '-free script survives that verbatim.
  # A non-interactive ssh has sshd's bare PATH, so "not on PATH" is not "not installed":
  # ask the login shell too, then look where the installer, brew, bun, npm and nvm put it.
  # --version proves the binary actually runs here, not just that a file exists.
  local pre='
case $1 in /*) ;; *) set -- "$HOME/$1" ;; esac
cd -- "$1" || exit 3
[ -w . ] || exit 3
dr=$(pwd -P) || exit 3
probe() {
  pn=$1; shift
  pp=$(command -v "$pn" 2>/dev/null) && [ -x "$pp" ] && { printf "%s\n" "$pp"; return 0; }
  pp=$("${SHELL:-/bin/sh}" -lc "command -v $pn" </dev/null 2>/dev/null | tail -n 1) && [ -x "$pp" ] && { printf "%s\n" "$pp"; return 0; }
  for pp in "$@"; do [ -x "$pp" ] && { printf "%s\n" "$pp"; return 0; }; done
  return 1
}
oc=$(probe opencode "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode \
  "$HOME/.bun/bin/opencode" "$HOME/.local/bin/opencode" "$HOME/.npm-global/bin/opencode" "$HOME/.volta/bin/opencode" \
  "$HOME/.local/share/pnpm/opencode" "$HOME"/.nvm/versions/node/*/bin/opencode \
  /home/linuxbrew/.linuxbrew/bin/opencode /usr/bin/opencode) || exit 4
ver=$("$oc" --version </dev/null 2>/dev/null) || exit 8
sq=$(probe sqlite3 /usr/bin/sqlite3 /opt/homebrew/bin/sqlite3 /usr/local/bin/sqlite3 \
  /opt/homebrew/opt/sqlite/bin/sqlite3 /home/linuxbrew/.linuxbrew/bin/sqlite3) || exit 6
g=-
if [ ! -d .git ]; then
  g=$(probe git /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git /home/linuxbrew/.linuxbrew/bin/git) || exit 5
  hr=$(cd -- "$HOME" && pwd -P)
  if [ "$dr" = "$HOME" ] || [ "$dr" = "$hr" ] || [ "$dr" = / ]; then exit 7; fi
fi
printf "%s\n" "$dr" "$oc" "$ver" "$sq" "$g" "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"'
  # -n: stdin from /dev/null, so the remote sh cannot swallow this terminal. -- : host is never an option.
  local out rc
  out=$($sshc -n -- "$host" "sh -c '$pre' sh $(_oc-sq "$rpath")"); rc=$?
  case $rc in
    0) ;;
    # ssh itself exits 255 when it never reached the host; its own message is already on stderr
    3|255) print -u2 "Destination path is not accessible."; return 1 ;;
    4) print -u2 "opencode not found on $host (not on PATH, not in any usual install location) - nothing done"; return 1 ;;
    8) print -u2 "opencode exists on $host but does not run (--version failed) - nothing done"; return 1 ;;
    5) print -u2 "git not found on $host - needed to make $rpath a project - nothing done"; return 1 ;;
    6) print -u2 "sqlite3 not found on $host - nothing done"; return 1 ;;
    7) print -u2 "refusing to git init the home directory (or /) on $host - choose a real project folder"; return 1 ;;
    *) print -u2 "remote preflight failed ($rc)"; return 1 ;;
  esac
  local -a info; info=("${(@f)out}")
  (( $#info == 6 )) || { print -u2 "unexpected preflight output from $host: $out"; return 1 }
  local dstr=$info[1] oc=$info[2] ver=$info[3] sq=$info[4] git=$info[5] rdb=$info[6]
  print "remote $host: opencode $ver at $oc"
  # ---- 2. export the whole family. Over there the subagent rows do not exist, so unlike
  # the local move every member has to travel; the CTE yields parents before children.
  local -a ids; ids=("${(@f)$(sqlite3 "$db" "$fam SELECT id FROM d;")}")
  local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/oc-move.XXXXXX") || return 1
  local id idl=
  for id in $ids; do
    idl+="${idl:+,}'$id'"
    opencode export "$id" > "$tmpd/$id.json" || { rm -rf -- "$tmpd"; return 1 }
  done
  # ---- 3. what to fix over there once import is done, straight from OUR rows: the
  # re-point (as in the local branch) and time_updated, which a re-import of an already
  # migrated session bumps to "now" exactly like a local move does.
  local dsq=${dstr//\'/\'\'} hsq=${host//\'/\'\'}
  {
    print -r -- "UPDATE session SET project_id=(SELECT project_id FROM session WHERE id='$sid'),
                       directory =(SELECT directory  FROM session WHERE id='$sid')
     WHERE id IN ($idl) AND id<>'$sid';
    SELECT 'moved $sid +'||changes()||' subagents -> $hsq:'||directory FROM session WHERE id='$sid';"
    sqlite3 "$db" "SELECT 'UPDATE session SET time_updated='||time_updated||' WHERE id='''||id||''';'
      FROM session WHERE id IN ($idl);"
  } > "$tmpd/fix.sql" || { rm -rf -- "$tmpd"; return 1 }
  # ---- 4. the remote-side script. Every value is single-quoted via _oc-sq, so a path with
  # spaces, quotes or $ passes through sh untouched. The bystander snapshot must run over
  # there, before opencode does: becoming a project absorbs the 'global' sessions of that
  # folder and bumps their timestamps (same hazard as the local branch).
  local bysel="SELECT 'UPDATE session SET time_updated='||time_updated||' WHERE id='''||id||''';'
      FROM session WHERE directory='$dsq' AND id NOT IN ($idl);"
  local bycnt="SELECT COUNT(*) FROM session WHERE directory='$dsq' AND id NOT IN ($idl);"
  cat > "$tmpd/run.sh" <<EOF || { rm -rf -- "$tmpd"; return 1 }
# generated by oc-move; runs on $host, \$1 = the unpacked payload
t=\$1
cd -- $(_oc-sq "$dstr") || exit 1
db=$(_oc-sq "$rdb") oc=$(_oc-sq "$oc") sq=$(_oc-sq "$sq") git=$(_oc-sq "$git")
ts=; n=0
if [ -f "\$db" ]; then
  ts=\$("\$sq" "\$db" $(_oc-sq "$bysel")) || exit 1
  n=\$("\$sq" "\$db" $(_oc-sq "$bycnt")) || exit 1
fi
if [ ! -d .git ]; then
  "\$git" init -q || exit 1
  # an account that never committed has no identity; the empty init commit does not need a real one
  "\$git" commit -q --allow-empty -m init 2>/dev/null ||
    "\$git" -c user.name=oc-move -c user.email=oc-move@localhost commit -q --allow-empty -m init || exit 1
fi
for id in $ids; do "\$oc" import "\$t/\$id.json" </dev/null || exit 1; done
[ "\$n" -gt 0 ] && echo "note: \$n session(s) already in "$(_oc-sq "$dstr")" joined this project (timestamps preserved)"
{ cat "\$t/fix.sql"; printf "%s\\n" "\$ts"; } | "\$sq" "\$db"
EOF
  # ---- 5. ship and run. The command string is constant and '-free (see preflight). stdin
  # carries the tar; the imports read /dev/null so nothing downstream can eat the stream.
  # ustar: the one format both bsdtar and GNU tar read without a murmur.
  local cmd='t=$(mktemp -d) && tar -C "$t" -xf - && sh "$t/run.sh" "$t"; rc=$?; [ -n "$t" ] && rm -rf "$t"; exit $rc'
  tar --format=ustar -cf - -C "$tmpd" . | $sshc -- "$host" "sh -c '$cmd'"; rc=$?
  rm -rf -- "$tmpd"
  (( rc == 0 )) || { print -u2 "remote import failed ($rc) - the local copy is untouched"; return 1 }
  # A copy of the family now lives over there. Deleting here is irreversible, so it is not
  # automatic; `session delete` on the root takes its whole subagent tree along (verified).
  print "note: the local copy stays until you run: opencode session delete $sid"
}
