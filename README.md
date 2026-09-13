# oc-move

Move an opencode session, together with every subagent session it spawned, into another project folder.

opencode has no `session move` command, and its `export`/`import` leaves subagent sessions behind ([opencode#40352](https://github.com/anomalyco/opencode/issues/40352)). `oc-move` fills that gap.

## Requirements

zsh, plus `opencode`, `git`, and `sqlite3` on your PATH. Tested on macOS only.

## Install

```bash
git clone https://github.com/hainingpan/oc-move.git
```

Then add this line to your `~/.zshrc`, pointing at wherever you cloned it, and open a new shell:

```zsh
source /path/to/oc-move/oc-move.zsh
```

## Usage

```bash
oc-move <session-id> <destination-folder>
```

Find the session id with `opencode session list`. Example:

```bash
oc-move ses_4f1c9a2e7b3d8Kp2QmXvNhTzLd ~/projects/my-app
```

What to expect:

- The session and all of its subagents move together and keep their ids. This is a move, not a copy; if you need a copy, fork the session in opencode first (`/fork`) and move the fork.
- oc-move creates the destination folder if needed. If the folder is not a git repository yet, it runs `git init` and adds one empty commit; opencode needs that before it treats the folder as a project.
- Sessions already in the destination folder are grouped into the same project. oc-move prints a note when this happens.
- No timestamps change, so your session list keeps its order.
- `$HOME` and `/` are refused as destinations.

## Files

    oc-move.zsh   the function
    test.zsh      regression suite; see TESTING.md
    .backups/     local copies of ~/.zshrc, gitignored because they usually contain API keys. Keep the ignore rule.
