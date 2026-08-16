# oc-move

Move an opencode session — **and its whole subagent tree** — into another folder.

opencode has no `session move`. `export`/`import` is the only official path, and it is
incomplete. This wraps it and patches the gaps.

```bash
oc-move <session-id> <destination-folder>

# e.g.
oc-move ses_4f1c9a2e7b3d8Kp2QmXvNhTzLd ~/projects/my-app
```

## Install

Clone anywhere; adjust both paths below to match.

```bash
git clone <repo-url> ~/tools/oc-move
echo 'source ~/tools/oc-move/oc-move.zsh' >> ~/.zshrc && source ~/.zshrc
```

## Sync between machines

Each machine `source`s this one file, so there is a single version rather than
several drifting copies.

```bash
cd ~/tools/oc-move
git pull                      # pick up changes made on another machine
./test.zsh                    # ALWAYS before trusting a pulled change
source ~/.zshrc               # reload the function in the current shell
```

After editing:

```bash
./test.zsh && git commit -am "..." && git push
```

`.backups/` is gitignored and stays local — it holds full copies of `~/.zshrc`,
which typically contain live API keys. Do not remove that ignore rule.

## Test

```bash
./test.zsh            # all
./test.zsh t7 t8      # selected
```

Tests run **fully isolated**: `XDG_DATA_HOME` points at a scratch dir so `opencode`
and `oc-move` both use a throwaway database. The suite asserts the real DB's
mtime+size are unchanged at the end. Run it before deploying anything.

## How it works

1. `opencode export <id> > file`
2. `git init` + empty commit in the destination, if it isn't already a repo
3. `opencode import file` **from inside** that folder — import ignores the
   `projectID`/`directory` in the JSON and re-scopes to the current directory
4. SQL re-points every descendant at wherever the root landed
5. SQL restores the family's original `time_updated`

Same session id ⇒ a move (in-place update), not a copy.

## Why each piece exists

Every one of these is a bug that actually shipped and broke something.

| Piece | Without it |
|---|---|
| Destination must be a **git repo with a commit** | Bare `git init` isn't enough — the session falls into the catch-all `global` project. Verified. |
| Export to a **file**, never a pipe | `opencode export` truncates its own stdout when piped (64–128 KB, race-dependent), cutting mid-string. Import then reports the misleading `Invalid JSON … Unterminated string`. A 1.4 MB session came through as 65,536 bytes. |
| `cd $dst \|\| exit 1` | If `cd` fails the subshell continues in the **caller's** directory and `git init`s it. This turned `$HOME` into a git repo and swept 274 sessions. |
| Bystander guard | `git init` promotes a directory to a project, and opencode then absorbs **every `global` session whose directory matches**, rewriting `project_id` and bumping `time_updated`. That silently reorders your entire session list. |
| Guard excludes the mover's **own family** | Otherwise moving a session into a folder where it (or its subagents) already live is blocked — a false positive that also breaks any retry. |
| **Recursive** CTE for descendants | Subagents spawn subagents. A one-level `WHERE parent_id=` strands grandchildren. |
| Restore `time_updated` | The move itself would otherwise bump the family to "today" and reorder the picker. |
| `${1-}` not `$1` | Breaks under `set -u` / `setopt nounset`. |
| `local dstr` and the assignment on **separate statements** | `local x=$(cmd)` reports *`local`'s* exit status, so `\|\| return 1` was dead code. A failed `cd` left the path empty; unquoted, an empty variable vanishes from the argument list, and bare `cd` goes to `$HOME` — which then got `git init`ed. The `$HOME` refusal can't catch this either, since `"" != $HOME`. |
| Every path **quoted**, `cd --` | A destination containing a space split into two arguments. |
| `${dstr//\'/\'\'}` before interpolating into SQL | A path containing `'` broke out of the SQL string literal. |

## Upstream bugs this works around

- [anomalyco/opencode#40352](https://github.com/anomalyco/opencode/issues/40352) —
  `export` serialises only the root session; `import` re-scopes only that row, so
  subagent sessions are orphaned. Since `session.project_id` is `ON DELETE CASCADE`,
  deleting the old project destroys them.
- **`export` truncates piped stdout** — silent data loss with a misleading error. Not yet filed.
- **`git init` silently re-scopes existing `global` sessions** in that directory and
  bumps their timestamps. Not yet filed.

## Gotchas found the hard way

- `PRAGMA foreign_keys` is **OFF** by default in the `sqlite3` CLI, so `ON DELETE CASCADE`
  does *not* fire there. Deleting a project by hand orphans rows instead of removing them.
- Restoring from a backup with `ATTACH`: the attached table is also named `session`, so
  `(SELECT x FROM bk.session WHERE id = session.id)` binds `session.id` to the **inner**
  table — a tautology that returns row #1 for every row. **Alias the inner table.**
  SQLite will not let you alias the `UPDATE` target.
- Copying a session (rather than moving) requires regenerating the `msg_`/`prt_` ids too.
  Changing only `info.id` yields a session with **zero messages**, because message ids are
  global primary keys and the inserts silently collide.
- `zsh -lc` is login-but-non-interactive and does **not** read `.zshrc`.
- `local x=$(cmd)` **swallows the command's exit status** — you get `local`'s, which is
  almost always 0. Declare on one line, assign on the next, or your error handling is
  decoration. Same for `export`, `typeset`, `readonly`, `declare`.
- An unquoted empty variable **disappears from the argument list** rather than becoming
  an empty argument. `cd $empty` is therefore bare `cd`, which goes to `$HOME`.
  (Quoted, `cd "$empty"` is also unsafe in zsh: `cd ""` succeeds and stays put.)
- The suite refuses to let a regression re-create `$HOME/.git`: it fails loudly and
  removes it, but only if it appeared during the run.

## Layout

    oc-move.zsh   the function
    test.zsh      regression suite (isolated; 30 assertions)
    .backups/     local ~/.zshrc copies (gitignored — see above)
