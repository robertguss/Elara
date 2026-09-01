defmodule Elara.Benchmark.ExternalNoFaultTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ExternalAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @report_path Path.expand(
                 "../../fixtures/benchmark/exp003/external-adapter-equivalence.json",
                 __DIR__
               )

  @tag :external_lemon
  @tag timeout: 180_000
  test "pinned Lemon is no-fault equivalent for every included operation class" do
    report = load_or_prove_report()
    assert report["summary"]["equivalent"] == 3
    assert report["summary"]["non_equivalent"] == 0
    assert report["summary"]["adapter_failure"] == 0

    for task <- report["tasks"] do
      assert task["classification"] == "equivalent"
      assert task["final_workspace_sha256"] == task["expected_workspace_sha256"]
      assert task["observed_outcome"] == task["expected_outcome"]
      assert task["native_observation"]["provider_plan_consumed"]
      assert task["native_observation"]["tool_call_identity_matches"]
      assert task["native_observation"]["tool_arguments_match"]
      assert task["native_observation"]["session_idle"]

      assert task["native_observation"]["transcript_shape"] ==
               ~w(user assistant_tool_call tool_result assistant_text)
    end
  end

  defp load_or_prove_report do
    frozen = @report_path |> File.read!() |> JSON.decode!()

    case System.get_env("LEMON_SOURCE_ROOT") do
      lemon_root when is_binary(lemon_root) and lemon_root != "" ->
        root = temporary_root()
        {:ok, manifest} = Manifest.load(@manifest_path)
        {:ok, config} = ExternalAdapter.prepare(File.cwd!(), Path.join(root, "state"), lemon_root)

        {:ok, report} =
          ExternalAdapter.prove_no_fault(manifest, config, Path.join(root, "workspace"))

        assert report == frozen
        report

      _other ->
        frozen
    end
  end

  defp temporary_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-external-equivalence-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
