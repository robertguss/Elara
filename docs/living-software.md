# Living Software

> **Status:** Foundational design thesis  
> **Updated:** August 2026  
> **Scope:** Software as a continuously adapting, constitutionally governed
> system—and the epistemic operating system required to evolve it safely.

This is a focused companion to
[Harness: A BEAM-Native Fabric for Software Work](harness-vision.md) and the
[Software Production Frontiers](software-production-frontiers.md). It captures
the emerging thesis without turning either broader document into an unbounded
manifesto.

## The thesis

Software is becoming less like a finished artifact and more like a **living
system**. It continuously receives signals from people, agents, production,
dependencies, policy, markets, and its environment; interprets contradictions;
and adapts while trying to preserve its identity and obligations.

The deepest opportunity is not an operating system for coding. It is an
**epistemic and causal operating system for changing complex systems**.

```text
Human values, goals, judgment, and authority
                       │
                       ▼
            ┌───────────────────────┐
            │ Living Constitution   │
            │ intent · obligations  │
            │ invariants · policy   │
            └───────────┬───────────┘
                        │ compile
                        ▼
            ┌───────────────────────┐
            │ Software-work kernel  │
            │ missions · evidence   │
            │ causality · authority │
            └─────┬─────────┬───────┘
                  │         │
          ┌───────▼───┐ ┌───▼────────────┐
          │ Cognitive │ │ Execution and  │
          │ runtimes  │ │ verification   │
          │ Harness   │ │ cells          │
          └───────┬───┘ └───┬────────────┘
                  └─────┬────┘
                        ▼
             Code · infra · policy
             releases · explanations
                        │
                        ▼
               Production reality
                        │ observe
                        ▼
        evidence · contradiction · proposals
                        │
                        └──────────────▶ Constitution
```

Code remains real and consequential, but it may become a **materialized
projection**: one implementation compiled from intent, constraints, evidence,
platform capabilities, and current reality. The durable identity of an
application increasingly resides in the obligations it preserves—not in one
particular arrangement of source files.

## The constitutional compiler

The proposed language is not merely another programming language. It is a
language above implementation: a representation humans and machines can both
interrogate that describes what the system is for, what it promises, what it
must never do, who may change it, and what evidence is sufficient.

### Layers of a living constitution

| Layer             | Contains                                                                | Character                        |
| ----------------- | ----------------------------------------------------------------------- | -------------------------------- |
| Purpose           | Values, desired outcomes, affected people, non-goals                    | Human-legible and contestable    |
| Obligations       | Durable promises to preserve, produce, prevent, or resolve              | Typed, owned, temporal           |
| Invariants        | Safety, compatibility, privacy, security, and architectural constraints | As machine-checkable as possible |
| Authority         | Who or what may observe, decide, amend, execute, and approve            | Capability-based                 |
| Evidence policy   | What justifies a claim or consequential effect                          | Risk- and scope-sensitive        |
| Adaptation policy | What may change autonomously and what requires judgment                 | Bounded by reversibility         |
| Amendment process | How rules evolve, how dissent is retained, and how changes expire       | Governed and auditable           |

A constitution cannot be only prose: prose is ambiguous and difficult to verify.
It also cannot be only formal logic: human values, tradeoffs, and novel
conditions cannot be completely formalized. It must be a layered document with
formal cores, executable policies, examples, precedents, and explicitly human
judgment.

### Four forms of semantics

The constitutional language must describe more than expected behavior:

1. **Normative semantics:** what ought to be true—purpose, values, obligations,
   protected people, and unacceptable outcomes.
2. **Operational semantics:** which actions are permitted, forbidden, or
   conditional and which capabilities they require.
3. **Evidentiary semantics:** what justifies believing a claim, where that
   evidence applies, and what would invalidate it.
4. **Evolutionary semantics:** how obligations, policy, and authority may change
   as the world changes, including amendment, migration, dissent, and expiry.

Most specification languages describe behavior. A constitution must also
describe **power, knowledge, legitimacy, and lawful evolution**.

### Compilation targets

The compiler does not simply emit source code. It can produce:

- A graph of obligations and typed Missions.
- Context capsules and capability grants.
- Competing implementation candidates.
- Source, infrastructure, configuration, and migrations.
- Verification plans and proof obligations.
- Workspace-cell requirements.
- Deployment hypotheses, observation windows, and retreat policies.
- Explanations connecting every artifact back to constitutional intent.

```text
Constitution
    │
    ├──▶ obligations ──▶ missions ──▶ implementations
    ├──▶ invariants ───▶ proof obligations ──▶ evidence
    ├──▶ authority ────▶ capabilities ──▶ effect receipts
    ├──▶ risk policy ──▶ verification depth + human gates
    └──▶ predictions ──▶ release + production observation
```

Compilation must be reproducible enough to explain why an artifact exists, but
need not be deterministic in the traditional compiler sense. A generative
compiler can explore multiple correct implementations. Its output requires
provenance: constitution version, context, model and tool generations,
decisions, evidence, and unresolved uncertainty.

### Compiler and controller

“Compiler” captures the move above source code but sounds like a one-way
transformation. Living software also needs a continuous **constitutional
controller** that reconciles desired obligations with observed reality:

```text
Living Constitution ──▶ desired obligations
          ▲                    │
          │                    ▼
amendment proposals      reconciliation engine
          │                    │ Missions
          │                    ▼
 evidence + contradictions ◀ implementation + production
```

The controller repeatedly asks:

1. What should be true under the current constitution?
2. What does scoped evidence justify believing is true?
3. What changed in the environment or our knowledge?
4. What authority permits the system to act?
5. What bounded Mission could safely reduce the difference?

The application’s identity then moves from repository continuity toward
**continuity of obligations through changing implementations**. Code is its
current phenotype. Two radically different implementations can be the same
application if they preserve the same constitutional promises; a tiny code
change can create a fundamentally different system if it violates one.

One semantic version is no longer enough:

```text
Constitution version      12
Policy/amendment epoch     7
Interpreter generation    H-34
Implementation phenotype 186
Environment generation     9
Evidence epoch             43
Production-state lineage  P-882
```

These dimensions evolve independently. Evidence can expire without code
changing; a new interpreter can generate a new phenotype under the same
constitution; production state can make otherwise valid code unsafe.

### Compilation as governed search

A constitutional compiler may be less like a deterministic translator and more
like constrained evolutionary search:

```text
Constitution
     │
     ▼
candidate Missions and implementations
  ┌──────────┼──────────┐
  ▼          ▼          ▼
candidate A  candidate B  candidate C
  │          │          │
  └──── evidence + simulation ────┘
                    │
        constraint satisfaction
                    │
          unresolved tradeoffs
                    │
             human judgment
                    ▼
          selected phenotype
```

Generation, simulation, proof, selection, and governance are all parts of
“compilation.” Minority alternatives should survive while evidence remains
insufficient to collapse the portfolio.

### Feedback is not automatic constitutional mutation

Production signals should compile _backward_ into:

- New evidence.
- Contradictions of existing claims.
- Violated or newly discovered obligations.
- Proposed amendments.
- Requests for human judgment.
- New Missions under the existing constitution.

They should not silently rewrite purpose or values. A system that can alter its
own definition of success can make itself appear correct rather than become
correct. Adaptation needs constitutional boundaries and independent governance.

This suggests a form of jurisprudence:

- **Constitution:** durable principles and authority.
- **Statutes/policy:** executable rules for known classes of work.
- **Precedent:** prior decisions with their facts, evidence, and outcomes.
- **Executive action:** Missions interpreted by agents and tools.
- **Adjudication:** independent verification and human judgment.
- **Amendment:** explicit evolution when reality invalidates a governing rule.

## The epistemic operating system

Traditional operating systems schedule CPU, memory, devices, and processes. A
software-work kernel must also schedule and protect **belief, attention,
authority, causality, and risk**.

### Obligations, not tickets

The durable unit may be an obligation: a promise that survives agents,
processes, environments, branches, releases, and organizational handoffs.

```text
Obligation
├── origin and rationale
├── governing authority and steward
├── satisfaction criteria and deadline
├── affected people and systems
├── relevant invariants
├── current supporting/contradicting evidence
├── delegated Missions
└── open · satisfied · violated · waived · superseded
```

A Mission is bounded work performed in service of an obligation. Code is one
possible artifact. Evidence determines whether the obligation is satisfied.

### Epistemic types

Software tools currently flatten observation, inference, proof, hearsay, and
guessing into text. Claims should retain how they are known:

```text
Observed · Measured · Reproduced · Derived · Formally proven
Test-supported · Human-asserted · Model-inferred · Externally reported
Contradicted · Unknown · Indeterminate
```

Every important claim should carry source, time, scope, assumptions, supporting
and contradicting evidence, and invalidation rules. The system should reject an
unsupported strengthening such as converting “no duplicate was observed” into
“duplicates cannot occur.”

### Context as a capability

A context capsule combines information with authority and trust:

```text
Context Capsule
├── selected information and provenance
├── trust and contamination classification
├── validity period and allowed uses
├── privacy and disclosure constraints
├── capability ceiling
└── derived-artifact policy
```

Reading production data or untrusted issue text is itself a privileged event.
The correct goal is not maximum context, but the smallest coherent context that
the Mission is authorized to use.

### Human attention as a kernel resource

Compute can generate more decisions than people can responsibly evaluate. An
attention scheduler should route only irreducible ambiguity, ethics, risk, and
value judgments to humans. It should know authority, expertise, overload,
interruption cost, reversibility, and whether more computation could resolve the
question first.

The goal is meaningful human control—not humans becoming exhausted approval
buttons for machine-generated work.

### Effects as privileged syscalls

Execution is not the same as causing an external effect. Every consequential
mutation should have stable identity, explicit authority, durable acceptance,
and a reconciled receipt:

```text
intent → capability/policy check → accepted effect ID → execution
       → completed | failed | cancelled | indeterminate → reconciliation
```

### Reversibility governs autonomy

Classify changes as instantly reversible, reversibly bounded, compensatable,
irreversible, or unknown. Agent authority can grow with containment,
observability, and reversibility. Safer autonomy may come less from perfect
models than from making the world they act upon easier to observe and undo.

## Twenty-six implications

The thesis reaches across the entire production system:

1. **Prediction-bearing releases:** every change declares intended behavior,
   preserved behavior, operational predictions, disconfirming signals,
   observation windows, and retreat policy.
2. **Production-initiated development:** typed invariant violations can create
   evidence, reproduction Missions, and bounded repair work.
3. **Counterfactual engineering:** replay historical work against alternative
   implementations, dependencies, prompts, policies, and architectures.
4. **Epistemic diversity:** independent review varies models, prompts, context,
   tools, methods, and visibility; parallel copies of one model are correlated.
5. **Conditional runtime reputation:** learn where an agent, prompt, plugin, or
   verifier is reliable without collapsing performance into a gameable score.
6. **Harness configuration as production code:** version prompts, models,
   plugins, tool descriptions, and context policies; shadow and replay changes.
7. **Constitutional self-hosting:** a system may improve itself but cannot
   unilaterally redefine its evaluation criteria or erase failed predictions.
8. **Software metabolism:** actively remove code, flags, tests, documents, and
   compatibility layers whose causal justification has expired.
9. **Separated review institutions:** verification asks whether claims are
   supported; judgment asks whether tradeoffs are desirable; authorization asks
   whether the effect is permitted.
10. **Executable architecture:** dependencies, data flow, effects, exceptions,
    and amendment rules become enforceable constitutional constraints.
11. **Causal versioning:** history records obligations, claims, evidence,
    rejected alternatives, effects, and outcomes—not only text snapshots.
12. **Proof-maintenance CI:** verification continuously identifies supported,
    contradicted, and expired claims and restores only the evidence affected.
13. **Environments as queries:** Missions request architecture, locality, trust,
    capabilities, source state, fixtures, observability, lifetime, and cost;
    placement may be local, remote, or specialized.
14. **Debuggable organizations:** causal history can expose policy gaps,
    orphaned invariants, recurring handoff failures, and ceremonial bottlenecks
    without becoming employee surveillance.
15. **Economic scheduling:** select among inference, deterministic tools, formal
    proof, simulation, production experiments, human judgment, and doing nothing
    based on total cost and risk—not token price.
16. **Implementation portfolios:** retain competing approaches optimized for
    simplicity, evidence, performance, compatibility, or reversibility until
    facts justify collapsing to one.
17. **Compiled memory:** immutable events become task-specific, provenance-rich
    projections with contradiction detection, privacy, and invalidation.
18. **Post-IDE control rooms:** navigate obligations, Mission topology,
    uncertainty, pending effects, evidence decay, production contradictions, and
    attention requests before navigating files.
19. **Semantic garbage collection:** detect when the reason an artifact exists
    has vanished and distinguish legitimate dependencies from residue.
20. **Proof leases:** evidence carries a validity domain and expires when its
    assumptions, environment, dependency, policy, or constitution changes.
21. **Digital twins for change:** simulate behavior, migrations, traffic, cost,
    and failure before granting production authority.
22. **Behavioral dependency contracts:** govern packages by capabilities,
    effects, provenance, compatibility evidence, and operations—not semver
    alone.
23. **Organizational causal memory:** retain alternatives, dissent, assumptions,
    predictions, and outcomes rather than only final decisions.
24. **Model-lineage-aware trust:** apparent consensus is discounted when agents
    share the same model, context, retrieval, prompt, or evaluator ancestry.
25. **Non-action as a valid result:** decline work when value does not justify
    permanent complexity, risk, or attention.
26. **Evolution over completion:** optimize for how safely and quickly the
    system detects wrong assumptions, adapts, and retains the learning.

## Constitutional laws

The platform should enforce a small set of uncompromising laws:

1. **No work without why.** Every Mission traces to an obligation, observation,
   or explicitly bounded exploration.
2. **No effect without authority.** Every consequential mutation requires a
   capability and policy decision.
3. **No effect without a receipt.** Outcomes include honest uncertainty.
4. **No accepted claim without evidence.** Weak evidence remains visibly weak.
5. **No evidence without scope.** Proof states where, when, and under which
   assumptions it applies.
6. **No artifact without lineage.** Meaningful outputs identify what produced
   them and why.
7. **No autonomy without containment.** Authority scales with reversibility,
   observability, and blast radius.
8. **No memory without invalidation.** Knowledge that cannot become stale will
   become dangerous.
9. **No metric without gaming analysis.** Assume agents and institutions will
   optimize whatever is measured.
10. **No self-modification without independent governance.** The system cannot
    redefine success and then certify itself.

The dominant risk is not an obviously broken patch. It is **false certainty at
scale**: correlated agents inherit one bad assumption, generated documentation
reinforces it, metrics reward completion, and apparent consensus suppresses
dissent. Unknown, contradicted, and minority hypotheses must remain first-class
state.

## Where Harness belongs

Harness should be a replaceable **cognitive runtime**, not the whole organism:

```text
Mission in
├── objective and constitutional references
├── context capsule
├── capability grant and workspace cell
├── deliverable and evidence policy
└── deadline, budget, and causal parent

Evidence-Carrying Result out
├── claims and artifacts
├── evidence and effect receipts
├── unresolved uncertainty
├── continuation identity
└── completed · failed · cancelled · indeterminate
```

Harness should excel at context interpretation, model orchestration, tools,
delegation, semantic compression, interruption, recovery, plugins, structured
results, and honest uncertainty. Separate systems should own canonical Missions,
artifact storage, environment isolation, versioning, verification, identity,
deployment, and production observation.

The BEAM is a promising live control fabric because lightweight actors,
supervision, messaging, lifecycle, introspection, and trusted distribution fit
temporary embodiments of durable work. It does not replace durable storage,
sandboxing, artifact systems, or hostile security boundaries.

## Where the organism metaphor breaks

The living-organism analogy is powerful:

- **Homeostasis:** preserve invariants under changing conditions.
- **Metabolism:** add useful structure and remove expired structure.
- **Immune system:** detect contradictions, threats, and violated obligations.
- **Memory:** retain adaptations and the evidence behind them.
- **Senses:** observe users, dependencies, infrastructure, and production.
- **Evolution:** explore alternatives and preserve successful adaptations.

But organisms optimize for survival and reproduction. Software must optimize for
human purpose. It must not develop an unquestioned drive to preserve itself,
expand authority, suppress shutdown, or rewrite its values to fit observed
behavior.

The better formulation is **living but constitutionally governed software**:
adaptive without being sovereign; autonomous within capabilities but always
interruptible, inspectable, and accountable.

Implementation details also do not become irrelevant. Most people may stop
authoring them directly, but details remain where security, performance,
correctness, cost, and failure physically occur. The constitutional compiler
must make implementations disposable and regenerable without making them opaque.
Humans need drill-down, explanation, reproducibility, and an escape hatch when
the abstraction leaks.

Code can safely become a cache only when the system can regenerate it, explain
it, verify it, migrate its state, and preserve deliberate low-level decisions.

## Discover semantics before syntax

The first mistake would be inventing an elegant constitutional DSL too early.
Syntax such as `obligation payment_exactly_once` can create the feeling of
progress while hiding whether the underlying objects are correct.

Begin with plain Markdown, Elixir structs, JSON, or database records. Exercise
purpose, obligation, invariant, claim, evidence, capability, effect, Mission,
amendment, precedent, and contradiction against real Harness work. A language
should crystallize semantics that survive those experiments—not substitute
syntax for understanding.

## Experiments

1. **Mission envelope:** run Harness from a typed objective, capability grant,
   deliverable, and evidence policy instead of only a prompt.
2. **Evidence-carrying result:** separate claims, evidence, artifacts, effects,
   and uncertainty; compare review quality with prose output.
3. **Tiny constitution:** describe one existing Harness behavior using purpose,
   obligations, invariants, examples, authority, and amendment rules. Plugin hot
   reloading is a strong first subject:

   ```text
   Purpose
     Extend a running session without restarting or losing history.

   Obligations
     Reloaded tools are available to subsequent turns.
     In-flight calls retain one coherent generation.

   Invariants
     A session never observes a half-installed generation.
     Reload failure preserves the last valid generation.

   Authority
     Only an explicit reload or approved watcher activates a generation.

   Evidence
     Reload tests, generation identity, failure injection, retained state.

   Amendment
     Isolation changes require independent compatibility evidence.
   ```

   Ask Harness to interpret it, compare it with current behavior, propose a
   Mission, implement or simulate the change, return evidence and uncertainty,
   and react to an injected contradiction.

4. **Bidirectional contradiction:** inject a production-like observation that
   violates one claim and see whether the system proposes the correct Mission or
   constitutional amendment without silently changing either.
5. **Proof invalidation:** change a dependency or assumption and identify the
   smallest evidence set that expires.
6. **Diverse verification:** compare same-model consensus with blind,
   cross-model, and deterministic verification.
7. **Effect receipt:** crash at every boundary of one external mutation and
   recover without duplication or invented certainty.
8. **Semantic deletion:** trace one old compatibility artifact to its original
   obligation and test whether it can now be removed.
9. **Prediction-bearing release:** state predictions and disconfirming signals
   for one small change, then evaluate the actual outcome.
10. **Constitutional self-hosting:** replay historical Harness Missions against
    a proposed prompt, plugin, or runtime change under independent criteria.

## Closing formulation

The application of the future may be neither a static program nor an autonomous
creature. It may be a **continuously materialized constitutional system**:

> Humans govern purpose, values, legitimacy, and irreducible judgment. Agents
> interpret bounded Missions and handle implementation. Verification maintains
> justified belief. Production supplies reality. The system adapts through
> explicit evidence and amendments while preserving authority, causality,
> reversibility, and the right to stop.

Its north star is not code produced or tickets completed. It is **trusted
adaptation per unit of scarce human attention**.

**Origin:**
[Harness vision and living-software discussion](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
