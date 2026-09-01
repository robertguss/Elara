Process.put(:elara_exp003_v6_preflight_no_run, true)
Code.require_file("priv/benchmark/preflight_exp003_v6.exs")
Process.delete(:elara_exp003_v6_preflight_no_run)

source = File.read!("priv/benchmark/materialize_exp003_v3.exs")

p02_source =
  ~S'''
      defp new_task("P02", candidate, seed) do
        t = tokens(seed, "P02")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        old_text = "old_#{t["value"]}"
        new_text = "new_#{t["new_value"]}"
        before = "defmodule Corpus#{String.capitalize(t["module"])} do\r\n  def value, do: \"#{old_text}\"\r\n  def untouched, do: \"#{t["sentinel"]}\"\r\nend\r\n"
        after_content = String.replace(before, old_text, new_text, global: false)
        initial = project_files(t, before, new_text)
        expected = replace_file(initial, path, after_content)
        step = patch_step(path, before, after_content, old_text, new_text, 1)
        task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
      end
  '''

source =
  source
  |> String.replace("Exp003V3", "Exp003V6")
  |> String.replace("exp003-v3", "exp003-v6")
  |> String.replace("ER-3/FND-2-v3", "ER-3/FND-2-v6")
  |> String.replace("corpus.v3", "corpus.v6")
  |> String.replace("fixture.v3", "fixture.v6")
  |> String.replace("plan.v3", "plan.v6")
  |> String.replace("dogfood-plan.v3", "dogfood-plan.v6")
  |> String.replace("compatibility.v3", "compatibility.v6")
  |> String.replace("external-adapter-equivalence.v3", "external-adapter-equivalence.v6")
  |> String.replace("fnd-2:v3", "fnd-2:v6")
  |> String.replace("receipt-v3", "receipt-v6")
  |> String.replace("preregistration-v3", "preregistration-v6")
  |> String.replace("materialize_exp003_v3.exs", "materialize_exp003_v6.exs")
  |> String.replace("6_427_122", "6_429_026")
  |> String.replace(
    "b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9",
    "ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c"
  )
  |> String.replace("ROB-849", "ROB-868")
  |> String.replace("2026-09-01T06:38:00Z", "2026-09-01T22:30:00Z")
  |> String.replace("V3 materialization", "V6 materialization")
  |> String.replace("V3 reuses", "V6 reuses")
  |> String.replace("v3 changes", "v6 changes")
  |> String.replace("v3 evidence", "v6 evidence")
  |> String.replace("v3_evidence", "v6_evidence")
  |> String.replace(
    "id in ~w(W02 W04 W06 P03 P05 P06) -> new_task(id, candidate, seed)",
    "id in ~w(W02 W04 W06 P02 P03 P05 P06) -> new_task(id, candidate, seed)"
  )
  |> String.replace(
    "    '''\n  end\n\n  defp upgrade_manifest",
    p02_source <> "\n    '''\n  end\n\n  defp upgrade_manifest"
  )
  |> String.replace(
    "  def run do\n    {:ok, compatibility}",
    "  def run do\n" <>
      "    :ok = Elara.Benchmark.Exp003V6Preflight.run()\n" <>
      "    true = file_sha256!(\"docs/experiments/003-effect-receipt-v6-preflight.json\") == \"8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216\"\n" <>
      "    true = file_sha256!(\"priv/benchmark/preflight_exp003_v6.exs\") == \"48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121\"\n" <>
      "    {:ok, compatibility}"
  )
  |> String.replace(
    "      \"validated_before_seed_selection\" => true\n",
    "      \"validated_before_seed_selection\" => true,\n" <>
      "      \"preflight_path\" => \"docs/experiments/003-effect-receipt-v6-preflight.json\",\n" <>
      "      \"preflight_sha256\" => \"8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216\",\n" <>
      "      \"preflight_source_sha256\" => \"48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121\"\n"
  )
  |> String.replace(
    "        |> Map.put(\"expected_workspace_observation\", contract[\"barrier_workspace\"])\n",
    "        |> Map.put(\"expected_workspace_observation\", contract[\"barrier_workspace\"])\n" <>
      "        |> Map.put(\"causal_terminal_evidence_expected_to_survive\", " <>
      "contract[\"causal_terminal_evidence_expected_to_survive\"])\n"
  )

Code.eval_string(source, [], file: "priv/benchmark/materialize_exp003_v3.exs")
