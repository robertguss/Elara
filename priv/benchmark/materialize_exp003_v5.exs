source = File.read!("priv/benchmark/materialize_exp003_v3.exs")

source =
  source
  |> String.replace("Exp003V3", "Exp003V5")
  |> String.replace("exp003-v3", "exp003-v5")
  |> String.replace("ER-3/FND-2-v3", "ER-3/FND-2-v5")
  |> String.replace("corpus.v3", "corpus.v5")
  |> String.replace("fixture.v3", "fixture.v5")
  |> String.replace("plan.v3", "plan.v5")
  |> String.replace("dogfood-plan.v3", "dogfood-plan.v5")
  |> String.replace("compatibility.v3", "compatibility.v5")
  |> String.replace("external-adapter-equivalence.v3", "external-adapter-equivalence.v5")
  |> String.replace("fnd-2:v3", "fnd-2:v5")
  |> String.replace("receipt-v3", "receipt-v5")
  |> String.replace("preregistration-v3", "preregistration-v5")
  |> String.replace("materialize_exp003_v3.exs", "materialize_exp003_v5.exs")
  |> String.replace("6_427_122", "6_428_936")
  |> String.replace(
    "b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9",
    "bc1444aacc773b9e7009063e7f40a48f51f0884d"
  )
  |> String.replace("ROB-849", "ROB-861")
  |> String.replace("2026-09-01T06:38:00Z", "2026-09-01T21:45:00Z")
  |> String.replace("V3 materialization", "V5 materialization")
  |> String.replace("V3 reuses", "V5 reuses")
  |> String.replace("v3 changes", "v5 changes")
  |> String.replace("v3 evidence", "v5 evidence")
  |> String.replace("v3_evidence", "v5_evidence")
  |> String.replace(
    "        |> Map.put(\"expected_workspace_observation\", contract[\"barrier_workspace\"])\n",
    "        |> Map.put(\"expected_workspace_observation\", contract[\"barrier_workspace\"])\n" <>
      "        |> Map.put(\"causal_terminal_evidence_expected_to_survive\", " <>
      "contract[\"causal_terminal_evidence_expected_to_survive\"])\n"
  )

Code.eval_string(source, [], file: "priv/benchmark/materialize_exp003_v3.exs")
