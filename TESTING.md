# Testing oc-move

```bash
./test.zsh            # run everything
./test.zsh t7 t8      # run only the tests whose names start with t7_ and t8_
```

The suite needs `opencode`, `sqlite3`, and `git` on your PATH. It points `XDG_DATA_HOME` at `.testrun/` so that opencode and oc-move both use a scratch database. Your real database is never opened, and the final check confirms its size and mtime did not change. (If opencode itself is running while you test, that check can trip simply because opencode wrote to its own database; re-run, or query it for the test ids, which all start with `ses_t`.)

Each test guards against a bug that shipped at some point. Do not delete one without knowing which failure it was protecting against.

| Test | Checks that |
|---|---|
| t1 | No arguments exits 1 and prints usage. |
| t2 | An unknown session id exits 1 without creating the destination folder. |
| t3 | Root, child, and grandchild sessions all move and share one project. |
| t4 | A 400 KB session body arrives intact. |
| t5 | The caller's working directory is unchanged afterwards. |
| t6 | Moving into a folder where the session's own subagents already live is not blocked. |
| t7 | Unrelated sessions already in the destination join the project, keep their timestamps, and a note is printed. |
| t8 | `time_updated` is preserved for the root and its child. |
| t9 | No temp files are left behind. |
| t10 | The message count is unchanged. |
| t11 | `$HOME` is refused with a message and no `~/.git` is created. |
| t12 | A destination that cannot be entered exits 1, does not `git init` the caller's directory, and leaves no temp file. |
| t13 | A path containing a space and an apostrophe works and lands at the exact path. |
| t14 | Remote form: a missing folder, or a host ssh cannot reach (exit 255), exits 1 with exactly `Destination path is not accessible.` and leaves both ends untouched. A bad session id passes the checks but still creates nothing over there. |
| t15 | Remote without opencode: exits 1 naming the host, ships nothing, does not `git init` the folder. |
| t16 | Remote move: root, child and grandchild all arrive with parent links, one project, original timestamps and a 300 KB body; opencode was found although it is not on the remote PATH; the summary and the cleanup hint are printed; the local copy is still there; no temp files on either end. |
| t17 | Migrating the same session a second time (an in-place update over there, which bumps `time_updated`) restores the timestamps; a `global` session already in that remote folder is absorbed but keeps its timestamp. |
| t18 | A remote path containing a space, `$` and an apostrophe lands at the exact path. |
| t19 | `host:` and `host:~` (the remote home) are refused; `host:~/proj` resolves under the *remote* home. |
| isolation | The real opencode database was not touched. |

If any test creates `$HOME/.git` during the run, the suite fails and removes it.

## How the remote tests work

No second machine and no sshd: `setup` puts a stand-in `ssh` first on PATH. It ignores the options and the host and runs the command string the way a remote login shell would (`zsh -c`), inside an environment shaped like a non-interactive ssh session: sshd's bare PATH, no `XDG_DATA_HOME`, a working directory of `$HOME`, and a HOME of its own under `.testrun/rhome`. So the "remote" opencode is the same binary but keeps a separate database, and it is *not* on the PATH over there; oc-move has to find it as it would on a real machine.

The one thing that cannot be staged this way is a remote without opencode, since the real binary cannot be hidden from a fake remote on the same disk. For that case (and for a dead host) the stand-in exits with the given code when `OC_TEST_SSH_RC` is set, which exercises everything on our side of the connection.

The remote path was also run once through real OpenSSH: a user-mode `sshd` on a high port with `SetEnv XDG_DATA_HOME=<scratch>`, and `OC_MOVE_SSH="ssh -F <scratch config>"` on the client side. It behaved identically to the stand-in. That setup is not part of the suite because it depends on being allowed to start an sshd.
