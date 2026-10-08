# tool-grep / tool-glob — ROB-1342

Seven `scripted-ask` drives from one launch, each kept in its own labelled
subdirectory because `bin/drive` reuses the run's evidence path. Every drive
is the public ask path: real session, real `Elara.CLI.render/1`, real tools,
`Elara.Provider.Scripted` only as the LLM stand-in. No credentials, no network.

`tool_results.txt` holds the text the tool returned. The render only counts
result lines, and a read-only search leaves no file bytes to inspect
afterwards, so the returned text is the observed state.

## Seeded `$WORKSPACE`

```
.gitignore                  (*.log)
README.md                   (created by bin/launch)
lib/alpha.ex                ("  @marker :found" on line 2)
lib/nested dir/beta file.ex ("# @marker in a spaced path")
debug.log                   (gitignored, contains @marker)
_build/lib/stale.ex         (contains @marker)
node_modules/pkg/index.js   (contains @marker)
```

The launch checkout holds hundreds of `.ex` files and many `@marker`-free
modules, so a result naming only seeded paths shows the search rooted at the
session workspace rather than the launch directory.

## Drives

| Label | Call | Result |
| --- | --- | --- |
| `glob-ex` | `glob **/*.ex` | `lib/alpha.ex`, `lib/nested dir/beta file.ex`; `_build` and `node_modules` absent |
| `grep-marker` | `grep @marker` | both matches as `path:line:text`, spaced path intact; ignored and build copies absent |
| `grep-scoped` | `grep @marker` path `lib/nested dir` | only the nested match |
| `grep-nomatch` | `grep absent-token` | `no matches` |
| `glob-ignored` | `glob **/*.log` | `debug.log`: an explicit glob outranks ignore files in ripgrep |
| `grep-escape` | `grep @marker` path `..` | error naming the working directory; no widened scan |
| `grep-badregex` | `grep @marker(` | `search failed (exit 2)` with ripgrep's parse error |

Every drive exited `0` for the turn; tool-level refusals appear as
`  <- error:` in the render, which is the intended outcome for the last two.
