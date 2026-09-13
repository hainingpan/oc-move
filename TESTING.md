# Testing oc-move

```bash
./test.zsh            # run everything
./test.zsh t7 t8      # run only the tests whose names start with t7_ and t8_
```

The suite needs `opencode`, `sqlite3`, and `git` on your PATH. It points `XDG_DATA_HOME` at `.testrun/` so that opencode and oc-move both use a scratch database. Your real database is never opened, and the final check confirms its size and mtime did not change.

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
| isolation | The real opencode database was not touched. |

If any test creates `$HOME/.git` during the run, the suite fails and removes it.
