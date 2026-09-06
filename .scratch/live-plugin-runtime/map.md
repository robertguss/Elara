# Live plugin discovery and reload

Labels: wayfinder:map
Status: resolved

## Destination

Settle the decisions needed to implement one bounded live-plugin discovery and
reload experiment, including its useful workflow, activation and failure
contracts, acceptance scenarios, prerequisites, and handoff to the roadmap.

## Notes

- The owner selected this experiment to explore BEAM/Elixir while developing a
  useful coding harness. Elara is not yet in daily use.
- This map holds planning decisions. [ROADMAP.md](../../ROADMAP.md) owns
  implementation sequencing and status. On 2026-09-06 the owner accepted the
  focused test→fix→rerun workflow and said “Yes do it.” That authorizes the
  bounded implementation recorded as PLUGIN-1 before returning to SPLIT-5.
  The implementation details below are agent decisions under that authorization,
  not claims that the owner separately answered every original interview question.
- Read the [runtime feature priorities](../../docs/features-research/priorities.md)
  for comparative rationale and verified limits; read the linked source notes
  when their detailed proposals are relevant.
- Consult the wayfinder, grilling, and domain-modeling skills when working a
  ticket. Ask the owner only one question at a time. Recommended answers are
  proposals until the owner decides.
- This effort uses the local Markdown tracker: one child file per ticket in
  `issues/`. `Parent` links back to this map; `Type` and `Labels` identify its
  kind. `Status: open` with `Assignee: unassigned` is unclaimed. Set the assignee
  to the driving developer and status to `claimed` before working a ticket.
  Resolve by appending `## Answer`, setting status to `resolved`, and adding a
  named context pointer below. Re-read files before updates to preserve other
  sessions' work.
- `Blocked by` lists local ticket numbers. A ticket is unblocked when all its
  listed blockers are resolved; `none` means no blockers. Query the child
  files for open, unblocked, unclaimed tickets in number order to find the
  frontier. The map itself does not duplicate the open-ticket list.

## Decisions so far

- [Accepted workflow and owner activation](issues/01-workflow-and-activation.md#answer)
- [Catalog continuity and ordinary failure rollback](issues/02-replacement-and-failure.md#answer)
- [Trusted local code and bounded experiment limits](issues/03-trust-and-generation-lifetime.md#answer)
- [Acceptance and PLUGIN-1 roadmap entry](issues/04-acceptance-and-roadmap-entry.md#answer)

## Not yet specified

The chosen workflow may reveal additional requirements for plugin dependencies,
shared resources, or author feedback. Revisit those areas as the initial tickets
resolve; create further tickets only when their questions become concrete.

## Out of scope

- Dedicated eval suites, benchmarking, and cross-harness comparisons: owner
  deferred evals. Ordinary correctness tests and acceptance scenarios are in scope.
- Removal, model-driven activation, and activation during a turn are deferred.
- MCP, general capability acquisition, disposable extension runtimes, core
  upgrades, distributed capability fabrics, and new UI/layout systems: separate
  experiments beyond this destination. The priorities document retains them.
- A broad fix of all baseline failures: identify prerequisites relevant to this
  experiment and track unrelated defects separately through the roadmap process.
