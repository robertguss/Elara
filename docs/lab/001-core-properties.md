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

`max_iterations` is 3 so the budget is reached often. Each trace is also
recorded through `Elara.FlightRecorder` in memory.

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
| Provider calls per turn ≤ `max_iterations`                                   | holds             |
| Interrupted / timed-out / crashed running mutating call is `indeterminate`   | **failed**, fixed |
| Calls not yet started report `error` on interrupt                            | holds             |
| Recorded facts replay to `:match`                                            | holds             |

Long run: all 9 properties held for 5,000 cases each (45,000 traces) in
22.3 seconds (seed 421279). The default 200-case run is part of `mix test`.

**Counterexample (shrunk):**
`[{:ask, "a"}, {:reply, [{"change", 0, false}], :match, ""}, :crash]` produced
`{:error, "tool crashed: boom"}` for a mutating call that had started. Interrupt
and timeout behaved the same way.

## Interpretation

The hypothesis is supported apart from the known counterexample. Everything else
held across generated traces, including steering, deferral, stale refs and the
iteration limit.

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

## Limits and next

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
