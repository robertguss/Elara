# Shipping: a small Elara dogfooding workspace

This is a dependency-free Mix project with passing baseline tests and two
unfinished exercises. Copy it outside the Elara checkout so `--cwd` must select
a different workspace. No secrets, services, plugins or network are needed by
the example itself. Elara's model provider still uses your configured account.

## Prepare on your Mac

From your updated Elara checkout, run:

```bash
ELARA_ROOT="$PWD"
PRACTICE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/elara-practice.XXXXXX")"
cp -R examples/shipping "$PRACTICE_ROOT/chat"
cp -R examples/shipping "$PRACTICE_ROOT/tui"
git -C "$PRACTICE_ROOT/chat" init
git -C "$PRACTICE_ROOT/tui" init
(cd "$PRACTICE_ROOT/chat" && mix test)
(cd "$PRACTICE_ROOT/tui" && mix test)
```

Both baselines should pass one test. Keep this terminal open: the variables
below refer to these paths. Each exercise starts from its own fresh copy.
Provider login must already be configured in Elara. Review the proposed manual
budget before starting: one task per interface, no unattended runs, no automatic
retries; interrupt if a task exceeds five minutes or expands beyond this scope.
This is a suggested human stop rule, **not an enforced token/spend cap**. Do not
run until you are comfortable with your provider's account usage.

## Task 1 — chat: discounts affect shipping eligibility

From the Elara checkout:

```bash
mix elara.chat --cwd "$PRACTICE_ROOT/chat" --name shipping-practice
```

Paste this prompt:

> In this shipping example, extend shipping_fee to accept an optional discount
> in integer cents, defaulting to zero. Decide free-shipping eligibility using
> subtotal minus discount. The threshold stays 5,000 cents and the fee stays
> 500 cents. Assume valid inputs: nonnegative integers and discount no greater
> than subtotal. Preserve one-argument callers. Add focused tests, run them,
> and report exactly what changed and what passed. Do not add dependencies.

After `/quit`, verify independently:

```bash
(cd "$PRACTICE_ROOT/chat" && mix test && mix format --check-formatted)
(cd "$PRACTICE_ROOT/chat" && mix run -e '
  for {subtotal, discount, expected} <- [{5000, 1, 500}, {5500, 500, 0}, {5500, 501, 500}] do
    actual = Shipping.shipping_fee(subtotal, discount)
    if actual != expected, do: raise("expected #{expected}, got #{actual}")
  end
  if Shipping.shipping_fee(5000) != 0, do: raise("one-argument behavior changed")
  IO.puts("discount acceptance passed")
')
```

The asymmetric cases catch checking the original subtotal instead of the
discounted subtotal and using `>` instead of `>=` at the threshold.

## Task 2 — TUI: return a complete quote

From the Elara checkout:

```bash
mix elara.tui --cwd "$PRACTICE_ROOT/tui" new
```

Paste this prompt:

> In this shipping example, add quote(subtotal) returning a map with
> :subtotal, :shipping and :total, all integer cents. Reuse shipping_fee/1;
> total is subtotal plus shipping. Preserve shipping_fee/1. Add boundary tests,
> run them, and report exactly what changed and what passed. Do not add
> dependencies or discount support in this fresh workspace.

Detach with Ctrl-C, then verify independently:

```bash
(cd "$PRACTICE_ROOT/tui" && mix test && mix format --check-formatted)
(cd "$PRACTICE_ROOT/tui" && mix run -e '
  for {subtotal, fee, total} <- [{4999, 500, 5499}, {5000, 0, 5000}, {5001, 0, 5001}] do
    expected = %{subtotal: subtotal, shipping: fee, total: total}
    actual = Shipping.quote(subtotal)
    if actual != expected, do: raise("expected #{inspect(expected)}, got #{inspect(actual)}")
  end
  IO.puts("quote acceptance passed")
')
```

## Report back

Keep the copies until findings are resolved. Send the interface used, task,
completion/interrupt result, independent check output, session ID, and any
keyboard/paste/rendering/tool problems. Note provider/model and elapsed time.
Do not share tokens or credentials. Screenshots are useful for TUI problems.
Compare the original and changed source with:

```bash
diff -u "$ELARA_ROOT/examples/shipping/lib/shipping.ex" "$PRACTICE_ROOT/chat/lib/shipping.ex"
diff -u "$ELARA_ROOT/examples/shipping/lib/shipping.ex" "$PRACTICE_ROOT/tui/lib/shipping.ex"
```

A difference exits 1; that is expected after completing a task.

This exercise does not close owner-terminal acceptance automatically, qualify
LAB-8's awaited-job real-model gate, or measure replay/policy quality.
