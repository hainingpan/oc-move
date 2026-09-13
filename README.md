# oc-move

Move an opencode session, together with every subagent session it spawned, into another project folder.

opencode has no `session move` command, and its `export`/`import` leaves subagent sessions behind ([opencode#40352](https://github.com/anomalyco/opencode/issues/40352)). `oc-move` fills that gap.

## Requirements

zsh, plus `opencode`, `git`, and `sqlite3` on your PATH. Tested on macOS only.

To move to another machine you also need ssh access to it, and that machine needs `opencode`, `git`, `sqlite3`, and `tar`. They do not have to be on the PATH that ssh gives you; see below.

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

## Moving to another machine

```bash
oc-move <session-id> <[user@]host:destination-folder>

# e.g.
oc-move ses_4f1c9a2e7b3d8Kp2QmXvNhTzLd me@workstation:~/projects/my-app
```

The destination is written like an `scp` target: `host:` and `host:~` mean the remote home directory, `~/x` and plain relative paths are relative to it. (A local folder whose name contains a colon needs a `./` prefix.)

Before anything is sent, oc-move connects once and checks the other side. It stops, and changes nothing anywhere, if:

- the destination folder does not exist, is not writable, or the host cannot be reached.
- `opencode` or `sqlite3` is missing, or `git` is missing and the folder is not a repository yet.
- the folder is the remote home directory or `/` and would have to be `git init`ed.

oc-move prints which opencode it will use, e.g. `remote me@workstation: opencode 1.18.23 at /opt/homebrew/bin/opencode`. After that the move behaves like a local one: the session and its subagents travel together, keep their ids, and keep their place in the session list.

What differs from a local move:

- The remote folder is not created for you. A typo in a remote path should be an error, not a new folder on another machine.
- The local copy stays. Deleting it is irreversible, so oc-move only prints the command: `opencode session delete <session-id>` removes the root together with its subagents. Run it once you have checked the session over there.
- oc-move connects twice, so without a key you are asked for the password twice. ssh's `ControlMaster` avoids that.

For a jump host, a non-standard port, or a specific key, set `OC_MOVE_SSH` (the same idea as `GIT_SSH_COMMAND`), e.g. `OC_MOVE_SSH="ssh -J bastion -p 2222"`.

### Details

A non-interactive ssh session has a bare PATH, so "not on PATH" is not taken as "not installed": oc-move also asks the remote login shell, then looks where the official installer, Homebrew, bun, npm, nvm, volta and pnpm put it. Whatever it finds has to answer `--version`, and that path is what it runs afterwards. When the folder itself is the problem, the message is `Destination path is not accessible.`, after ssh's or the remote shell's own diagnostic.

The transfer exports the session and every subagent (over there those rows do not exist, so unlike a local move each one has to travel), ships them in one tar stream, and imports them from inside the destination folder. The fix-ups afterwards are the same as a local move: subagents re-pointed at the root's project, timestamps restored, sessions already living in that folder left in their place in the list.

## Files

    oc-move.zsh   the function
    test.zsh      regression suite; see TESTING.md
    .backups/     local copies of ~/.zshrc, gitignored because they usually contain API keys. Keep the ignore rule.
