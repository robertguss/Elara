source = File.read!("priv/benchmark/materialize_exp003_v3.exs")

source =
  source
  |> String.replace("Exp003V3", "Exp003V4")
  |> String.replace("exp003-v3", "exp003-v4")
  |> String.replace("ER-3/FND-2-v3", "ER-3/FND-2-v4")
  |> String.replace("corpus.v3", "corpus.v4")
  |> String.replace("fixture.v3", "fixture.v4")
  |> String.replace("plan.v3", "plan.v4")
  |> String.replace("dogfood-plan.v3", "dogfood-plan.v4")
  |> String.replace("compatibility.v3", "compatibility.v4")
  |> String.replace("external-adapter-equivalence.v3", "external-adapter-equivalence.v4")
  |> String.replace("fnd-2:v3", "fnd-2:v4")
  |> String.replace("receipt-v3", "receipt-v4")
  |> String.replace("preregistration-v3", "preregistration-v4")
  |> String.replace("materialize_exp003_v3.exs", "materialize_exp003_v4.exs")
  |> String.replace("6_427_122", "6_428_786")
  |> String.replace(
    "b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9",
    "1d57c7e11d3dbb9b77b3cef5c359c39a787e7327"
  )
  |> String.replace("ROB-849", "ROB-855")
  |> String.replace("2026-09-01T06:38:00Z", "2026-09-01T20:30:00Z")
  |> String.replace("V3 materialization", "V4 materialization")
  |> String.replace("V3 reuses", "V4 reuses")
  |> String.replace("v3 changes", "v4 changes")
  |> String.replace("v3 evidence", "v4 evidence")

Code.eval_string(source, [], file: "priv/benchmark/materialize_exp003_v3.exs")
