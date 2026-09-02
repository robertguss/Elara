source = File.read!("priv/benchmark/materialize_exp003_v6.exs")

source =
  source
  |> String.replace("Exp003V6", "Exp003V7")
  |> String.replace("exp003-v6", "exp003-v7")
  |> String.replace("ER-3/FND-2-v6", "ER-3/FND-2-v7")
  |> String.replace("corpus.v6", "corpus.v7")
  |> String.replace("fixture.v6", "fixture.v7")
  |> String.replace("plan.v6", "plan.v7")
  |> String.replace("dogfood-plan.v6", "dogfood-plan.v7")
  |> String.replace("external-adapter-equivalence.v6", "external-adapter-equivalence.v7")
  |> String.replace("fnd-2:v6", "fnd-2:v7")
  |> String.replace("receipt-v6", "receipt-v7")
  |> String.replace("preregistration-v6", "preregistration-v7")
  |> String.replace("materialize_exp003_v6.exs", "materialize_exp003_v7.exs")
  |> String.replace("6_429_026", "6_429_446")
  |> String.replace(
    "da1187a4e2f7053c917fabcd2edf5e96109b22ab08db3318f19efe59757dfd55",
    "04a354a886b685477dd10dc439ded5fd66202f1e4d7077ac1b019447f3c75049"
  )
  |> String.replace(
    "ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c",
    "98cf40a03b68a943f75342ac9704257bbb083885"
  )
  |> String.replace("ROB-868", "ROB-875")
  |> String.replace("2026-09-01T22:30:00Z", "2026-09-02T02:00:00Z")
  |> String.replace("V6 materialization", "V7 materialization")
  |> String.replace("V6 reuses", "V7 reuses")
  |> String.replace("v6 changes", "v7 changes")
  |> String.replace("v6 evidence", "v7 evidence")
  |> String.replace("v6_evidence", "v7_evidence")
  |> String.replace("    :ok = Elara.Benchmark.Exp003V7Preflight.run()\\n", "")
  |> String.replace(
    "003-effect-receipt-v7-preflight.json",
    "003-effect-receipt-v7-command-path-preflight.json"
  )
  |> String.replace(
    "8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216",
    "c7522da0fd1730b61241898450893b7761d59ea8dab0721cb01d0e4e7eabf435"
  )
  |> String.replace(
    "48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121",
    "edb3045813584c98bb8d984d5f43c1d5e8d3ad05598f3cd4a62982cb1170cb64"
  )
  |> String.replace(
    ~S[|> String.replace("compatibility.v3", "compatibility.v7")],
    ~S[|> String.replace("compatibility.v3", "compatibility.v5")]
  )

frame_replacement = ~S'''
    true = Enum.sort(Map.keys(profiles)) == Enum.sort(Enum.map(candidates, & &1["id"]))

    eligible_ids = ~w(P01 P02 P04 P06 P07 P08 S01 S02 S03 S04 W01 W02 W03 W05 W06 W07 W08)
    eligible = Enum.filter(candidates, &(&1["id"] in eligible_ids))
    true = Enum.sort(Enum.map(eligible, & &1["id"])) == Enum.sort(eligible_ids)
    Map.put(source, "candidate_frame", eligible)
'''

source =
  String.replace(
    source,
    "Code.eval_string(source, [], file: \"priv/benchmark/materialize_exp003_v3.exs\")",
    ~S"""
    source =
      source
      |> String.replace(
        ~S'''
            true = Enum.sort(Map.keys(profiles)) == Enum.sort(Enum.map(candidates, & &1["id"]))
            Map.put(source, "candidate_frame", candidates)
        ''',
        frame_replacement
      )
      |> String.replace(
        ~S'''
              "candidate_count" => 20,
              "validated_assignment_count" => 40,
        ''',
        ~S'''
              "candidate_count" => 17,
              "source_mapping_count" => 20,
              "validated_assignment_count" => 34,
              "validated_command_path_run_count" => 112,
        '''
      )

    Code.eval_string(source, [], file: "priv/benchmark/materialize_exp003_v3.exs")
    """
  )

Code.eval_string(source, [frame_replacement: frame_replacement],
  file: "priv/benchmark/materialize_exp003_v6.exs"
)
