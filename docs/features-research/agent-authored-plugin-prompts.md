# Live experiment prompts

Exact operator prompts sent through `Elara.ask/2`, in order. See the
[experiment report](agent-authored-plugin-experiment.md) for outcomes and limits.
Explicit reload calls happened between prompts 1–2 and 6–7. Temporary paths
identify the original run and are not installation instructions.

## 1. Reproduce and author

```text
We are conducting one bounded live-plugin coding experiment in this Elara worktree.
The real task is to fix the macOS failure in test/elara/effect/opaque_shell_test.exs,
test "S-EFFECT-LIVE separates a satisfied adapter from a still-running shell" (currently line 152).

For this first turn only:
1. Reproduce that focused failure with the current tools and diagnose it from source.
2. Read docs/plugins.md and author a small useful plugin at .elara/plugins/shell_liveness.exs
   that helps diagnose and verify this specific problem. Choose a practical interface;
   keep useful plain-data session state so a later call can reuse earlier information.
   Distinct tool names, bounded output, no dependencies, no automatic full-suite runs.
3. Stop after writing the plugin, explaining its intended utility and readiness for reload.

Do not fix the test or any existing code yet. The owner will inspect and explicitly reload
the plugin between turns, then ask you to continue the actual fix in this same session.
Do not directly compile or activate the plugin yourself. Only create the new plugin file
in this phase; do not modify ROADMAP.md, existing plugins, configuration, or other files.
Do not install dependencies, read credentials, change branches, commit, or push. Limit all
work to this checkout. Treat the plugin as trusted local code and keep it small.
```

## 2. Use the activated plugin

```text
I inspected your plugin source and explicitly activated it through Elara.reload_plugins/1.
Continue the real task in this same session using the new tools.

Use shell_liveness_probe to gather meaningful evidence from a live shell process (not merely a
missing fixture directory), and use its retained state through shell_liveness_last. Then fix
the macOS S-EFFECT-LIVE test failure with the smallest sound change. Preserve the distinction
between a running process, a zombie/exited process, and an unknown observation. Keep Linux
behavior supported; do not weaken assertions, skip tests, or change production effect semantics.

Verify the focused test and the complete opaque_shell_test.exs file after your fix. Format your
changed Elixir files. Stop with an honest account of the result and how the plugin helped.
Only change your new plugin and test/elara/effect/opaque_shell_test.exs if needed. Do not change
ROADMAP.md, configuration, branches, or unrelated files. Do not install anything, read credentials,
commit, or push. Clean up only the temporary processes/files you create. Do not repeat unchanged
test runs just for reassurance. No dedicated evals or benchmarking.
```

## 3. Supply a controlled fixture

```text
Your previous turn hit the iteration limit while trying to retain background fixture processes.
I am providing ONE owner-controlled live shell fixture, held by a separate terminal process:
/tmp/elara-agent-plugin/owner-fixture
Its PID file is fixture/shell/pid under that directory. It waits for allow-effect, writes primary.txt,
then waits for allow-exit. Do not start any more background jobs.

Continue in this same session: probe this live fixture with your plugin, permit its effect using
the marker file, probe again, and use shell_liveness_last to inspect the retained evidence.
Then fix the existing test helper as planned and verify the focused test plus the complete
opaque_shell_test.exs file. Preserve live/zombie/exited/unknown distinctions and Linux support.
Format changed Elixir files. Finish by creating allow-exit for the supplied fixture, cleaning your
earlier temporary fixture directories/processes, and reporting actual results.

This is one corrective owner intervention; do not describe the task as autonomous success.
Keep the original file scope: your plugin and test/elara/effect/opaque_shell_test.exs only.
No dependency installs, changes to assertions or skips, production behavior changes, commits,
pushes, or full-suite runs. You have the prior diagnosis and need not reread it all.
```

## 4. Cleanup and report

```text
The previous turn hit the iteration limit after the fix and successful verification.
Do not edit code or run more tests. Finish this experiment now:
1. Read shell_liveness_last once to demonstrate that the previous probe is retained across turns.
2. Create allow-exit for /tmp/elara-agent-plugin/owner-fixture so the supplied shell ends.
3. Clean up only the temporary /tmp/elara-live-shell directories/processes you created in this session.
4. Give your final factual report: fix, observed focused/file test results, plugin utility, and
   the two iteration-limit stops and owner assistance. Distinguish evidence from assumptions.
No commits or pushes; I will independently review and publish the result.
```

## 5. Review correction and regression

```text
Independent review found a correctness issue to fix before publication:
Your process_state_from_ps/1 maps every nonzero ps exit to :terminated. A missing process
normally yields exit 1 with blank output, but an invalid PID, command/permission failure, or
other diagnostic also yields a nonzero status and must remain :unknown. Your plugin's
ps_state/1 similarly maps every nonzero status to :missing, which can misreport a failed probe.

Fix both classifications. Treat exit 1 with blank/whitespace output as missing/terminated as
appropriate; treat other nonzero outcomes or diagnostics as unknown (or an explicit error in
the diagnostic plugin). Keep zombie detection. Bump your plugin metadata version to "2".
In the existing opaque_shell_test.exs module add a small meaningful deterministic regression
test for failed observation remaining unknown. First show it fails against the current helper,
then make the fix and run the complete file. Do not alter existing assertions or skip anything.
Format only your changed files. Do not repeat successful tests without subsequent changes.

File scope is still only your plugin and test/elara/effect/opaque_shell_test.exs. Do not activate
the revised plugin in this session; I will inspect and reload it explicitly. No other changes,
dependency installs, credentials, commits, pushes, or new background jobs. End with concise
actual results, including any remaining limitations. This review feedback is further operator
assistance and must not be counted as unaided model success.
```

## 6. Correct diagnostic semantics

```text
One remaining review finding in the plugin only: procfs_state treats ENOENT as :missing even when /proc itself is unavailable on Darwin. portable_liveness then falls back to that false absence after a ps error. Correct minimally: ENOENT => :unavailable if /proc is not a directory, else :missing; accept ps :missing as conclusive absence; when ps is inconclusive, only accept conclusive procfs observations, otherwise :unknown. Prefer deriving portable_liveness from the two observations already in the probe rather than running both observers twice, so the output is internally consistent. Keep version 2. Format only the plugin. Check compile with mix run/Code.compile_file and directly exercise handle_tool on pid -1 to verify ps diagnostic plus unavailable procfs gives portable_liveness=:unknown. Do not reload/activate, edit other files, rerun tests, spawn background jobs, commit or push. Summarize briefly.
```

## 7. Check retained state after revision

```text
The owner inspected your complete revision and explicitly reloaded the plugin. Call shell_liveness_last exactly once. Report the retained probe number and historical PID/file state. The fixture has already exited: this is retained historical evidence, not a current liveness assertion. Do not probe again, edit, test, or run shell commands. Give a short factual conclusion on state continuity.
```
