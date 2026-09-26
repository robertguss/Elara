# 001 — Core invariants under generated fact sequences

- **Question:** RQ-1. Do the pure session reducer's safety invariants hold for
  arbitrary fact sequences?
- **Hypothesis:** every invariant below holds; the one known counterexample (an
  interrupted running mutation reported as an error) is the only one.
- **Queue item:** LAB-1 · **Date:** 2026-09-26

## Method

`test/elara/session/core_property_test.exs` (StreamData 1.4). Generated lists of
up to 40 abstract actions are interpreted against the current Core phase:

- **Live ref:** most facts carry the live ref.
- **Stale ref:** `{:stale, _}` actions carry a ref that can never be live.
- **Out of phase:** actions that don't apply to the current phase exercise the
  reducer's ignore paths.

The traces include:

- Asks and streamed deltas.
- Replies with 0–3 calls to a mutating tool, a non-mutating tool, or an unknown
  tool. Arguments are drawn from a small space so repeats are likely, and some
  are malformed.
- Matching and mismatching final text.
- Provider errors.
- All three tool outcomes, crashes, timeouts, deferrals and usage.
- Interrupt, steer, settings, instruction and inbox facts.

`max_iterations` is 3 so the budget can be reached within 40 actions. Each
trace is also recorded through `Elara.FlightRecorder` in memory.

Randomized properties can pass without ever exercising the state they guard.
To rule that out:
- **Coverage test.** It samples 1,000 generated traces and requires each
  guarded state to be reached by at least 5 of them.
- **Fixed boundary traces.** Steering during a tool, a deferred call and the
  iteration limit each have a trace that forces them deterministically.

A _terminal drain_ answers whatever Core awaits (provider: final text matching
the stream; tool: success) until idle.

    mix test test/elara/session/core_property_test.exs                          # 200 cases each
    LAB_PROPERTY_RUNS=5000 mix test test/elara/session/core_property_test.exs   # opt-in

## Results

| Property                                                                     | Result            |
| ---------------------------------------------------------------------------- | ----------------- |
| Same facts → same states and effects                                         | holds             |
| Stale-ref facts change nothing                                               | holds             |
| History is append-only                                                       | holds             |
| Turns end at most once on every prefix, exactly once after a drain           | holds             |
| Each call gets at most one result on every prefix, exactly one after a drain | holds             |
| No call dispatched twice or given two results, checked per step              | holds             |
| Calls rejected without dispatch get an error                                 | holds             |
| Provider calls per turn ≤ `max_iterations`                                   | holds             |
| Interrupted / timed-out / crashed running mutating call is `indeterminate`   | **failed**, fixed |
| Calls not yet started report `error` on interrupt                            | holds             |
| Recorded facts replay to `:match`                                            | holds             |

Long run: the first 9 properties held for 5,000 cases each (45,000 traces) in
22.3 seconds (seed 421279). The per-step and rejection properties were added
after review. The default 200-case run of all 11 is part of `mix test`.

Coverage, as traces reaching each state out of 1,000 (range over five seeds):

| State | Traces |
| --- | --- |
| Steering during a running tool | 35–40 |
| Deferral of a running call | 39–48 |
| Interrupt of a running mutating call | 22–30 |
| Timeout of a running mutating call | 18–29 |
| Iteration limit reached | 11–21 |
| Repeated call rejected | 39–65 |
| Stale-ref fact | most traces |

These counts use crash, timeout and deferral weights raised from 1 to 2. At
weight 1 with 500 traces, timeouts reached as few as 6.

**Counterexample (shrunk):**
`[{:ask, "a"}, {:reply, [{"change", 0, false}], :match, ""}, :crash]` produced
`{:error, "tool crashed: boom"}` for a mutating call that had started. Interrupt
and timeout behaved the same way.

## Interpretation

The hypothesis is supported for the reducer apart from the known counterexample.
Everything else held across generated traces, and the coverage counts show the
guarded states were actually reached.

The first fix was incomplete across execution paths. The reducer and local
`bash` reported `indeterminate` correctly, but the review found two paths that
still lost it:
- The remote worker could not encode it, and crashed.
- The durable effect executor turned it back into an ordinary failure.

Both were fixed in follow-up commits.

This establishes a property of Elara's reducer, not of the BEAM (see the
attribution rule).

## Changes

- `Core` now fails closed: a _running_ call to a mutating tool that is
  interrupted, times out or crashes without its own result is
  `{:indeterminate, "…; it may have partially changed the workspace"}`. Calls
  that never started, and non-mutating tools, keep an ordinary error.
- Fixing Core exposed the same gap one layer down, as a race in the tool-timeout
  test. `bash` reported `{:error, …}` when the stub killed it (timeout,
  cancellation, output cap). Those outcomes are now `indeterminate` too;
  commands that exit on their own still report their status.
- Five integration and protocol tests that encoded the old outcomes now assert
  the new ones. The TUI shows `indeterminate` for those tool calls.
- **Remote worker protocol (`9688605`):**
  - The worker encodes `indeterminate`, and the client decodes it.
  - A mutating job killed at the worker's deadline, or a tool that crashes
    there, is `indeterminate`.
  - Lines longer than the socket buffer are reassembled; large remote results
    previously failed to decode.
  - Follow-up: killing a job at the worker deadline or on disconnect no longer
    kills the whole worker (it unlinks first), and the client waits a
    one-second grace period for the worker's deadline reply.
- **Durable effect path (`a32e9ae`):**
  - The executor ledger (schema 2, migrated in place) has a terminal
    `indeterminate` state.
  - A callback that returns uncertainty, crashes or returns an invalid result
    is recorded as `indeterminate`.
  - Sidecar, the controller journal, the recovery barrier and `DeclarativeWrite`
    share one terminal-state guard. Without it, a completion would have waited
    for the timeout, and new input after a restart would have been held
    indefinitely (both reproduced before the fix).

## Limits and next

- **Child integration is now blocked more often.** Any `indeterminate` result in
  a delegated child's history refuses integration (`lib/elara/threads.ex:533`),
  and routine timeouts and output-cap kills now produce one. This is tested and
  documented. A scoped operator acknowledgement is queued as LAB-9.
- **Terminal evidence is not proof that a process stopped.** A terminal
  `indeterminate` record proves the callback returned or crashed, not that a
  remote or escaped process has stopped. The recovery barrier accepts it
  (`lib/elara/session.ex:969`); LAB-5 should probe this.
- **The experimental `LiteralPatch` and `OpaqueShell` modules** were updated for
  the new state without dedicated tests. They are test-only and scheduled for
  removal in LAB-6.
- **Plugin tools are always registered as non-mutating**
  (`lib/elara/plugin/server.ex:264-272`), so an interrupted mutating plugin
  still reports an error. Fixing that needs plugin authority declarations; it is
  recorded, not fixed.
- **The restart path was not changed.** `recover_store` already reconciles every
  journaled call, and `repair_history`'s `interrupted` only covers calls that
  never journaled intent. LAB-5 (chaos) should confirm this under faults.
- **Generator gaps:** public-content deltas, `ask_input` with attachments,
  `rebase_history` and `replace_tools` are not generated. Shell policy (inbox,
  handoff, capability gate) is out of scope, per LAB-1.
