defmodule Elara.CheckDiagnosisTest do
  use ExUnit.Case, async: true

  alias Elara.{CheckDiagnosis, CheckEvidence}

  setup do
    cwd = Path.join(System.tmp_dir!(), "check-diagnosis-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "example.ex"), "def answer, do: :wrong\n")
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "evidence retains pre-check bytes and reports a source change during the check", %{
    cwd: cwd
  } do
    assert {:ok, sources} = CheckEvidence.capture(cwd, ["example.ex"])
    File.write!(Path.join(cwd, "example.ex"), "def answer, do: :correct\n")

    evidence =
      CheckEvidence.finish(cwd, sources, "mix test", 1, 20, "expected :correct, got :wrong")

    assert CheckEvidence.valid?(evidence)
    source = Enum.find(evidence["artifacts"], &(&1["kind"] == "source"))
    assert source["content"] == "def answer, do: :wrong\n"
    assert evidence["source_observations"] == [%{"path" => "example.ex", "state" => "changed"}]
    assert evidence["exit_status"] == 1
  end

  test "capture rejects escaping paths and retains bounded text with explicit omissions", %{
    cwd: cwd
  } do
    assert {:error, _} = CheckEvidence.capture(cwd, ["../outside.ex"])
    File.write!(Path.join(cwd, "large.ex"), String.duplicate("é", 10_000))
    assert {:ok, sources} = CheckEvidence.capture(cwd, ["large.ex"])

    evidence =
      CheckEvidence.finish(cwd, sources, "mix test", 1, 10, String.duplicate("x", 80_000))

    assert CheckEvidence.valid?(evidence)
    assert Enum.all?(evidence["artifacts"], & &1["clipped"])
    assert Enum.all?(evidence["artifacts"], &(byte_size(&1["content"]) <= 8_192))
    assert Enum.all?(evidence["artifacts"], &String.valid?(&1["content"]))
  end

  test "accepts a diagnosis only with complete fields and references into captured evidence", %{
    cwd: cwd
  } do
    evidence =
      CheckEvidence.finish(cwd, [], "mix test", 1, 10, "assertion failed\nexpected 2, got 1")

    [log] = evidence["artifacts"]
    result = diagnosis(log["id"])

    assert {:ok, ^result} = CheckDiagnosis.validate(JSON.encode!(result), evidence)

    assert {:error, _} =
             CheckDiagnosis.validate(JSON.encode!(Map.delete(result, "unknowns")), evidence)

    fabricated =
      put_in(result, ["supporting_evidence"], [
        %{"artifact_id" => "invented", "start_line" => 1, "end_line" => 1}
      ])

    assert {:error, _} = CheckDiagnosis.validate(JSON.encode!(fabricated), evidence)

    beyond =
      put_in(result, ["supporting_evidence"], [
        %{"artifact_id" => log["id"], "start_line" => 1, "end_line" => 999}
      ])

    assert {:error, _} = CheckDiagnosis.validate(JSON.encode!(beyond), evidence)

    for {first, last} <- [{0, 1}, {2, 1}, {1, 17}] do
      invalid_range =
        put_in(result, ["supporting_evidence"], [
          %{"artifact_id" => log["id"], "start_line" => first, "end_line" => last}
        ])

      assert {:error, "Invalid diagnosis: evidence reference is outside the captured line range"} =
               CheckDiagnosis.validate(JSON.encode!(invalid_range), evidence)
    end
  end

  test "the original live diagnoses accept their complete captured failure blocks" do
    records =
      Path.expand("../../docs/features-research/check-diagnosis-live-runs.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    for run <- records["runs"] do
      text = run["diagnosis"]["raw_response"]
      expected = JSON.decode!(text)

      assert Enum.any?(
               expected["supporting_evidence"],
               &(&1["end_line"] - &1["start_line"] >= 10)
             )

      assert CheckEvidence.valid?(run["evidence"])
      assert {:ok, ^expected} = CheckDiagnosis.validate(text, run["evidence"])
    end
  end

  test "malformed, oversized, or empty diagnoses remain failures", %{cwd: cwd} do
    evidence = CheckEvidence.finish(cwd, [], "mix test", 1, 10, "failed")
    assert {:error, _} = CheckDiagnosis.validate("not JSON", evidence)
    assert {:error, _} = CheckDiagnosis.validate(String.duplicate("x", 20_000), evidence)
    assert {:error, _} = CheckDiagnosis.validate("{}", evidence)
  end

  test "repeated file selections and non-UTF8 command output remain inspectable", %{cwd: cwd} do
    assert {:ok, [_source] = sources} =
             CheckEvidence.capture(cwd, ["example.ex", "example.ex"])

    evidence = CheckEvidence.finish(cwd, sources, "mix test", 1, 10, "failed: " <> <<255>>)
    assert CheckEvidence.valid?(evidence)
    assert evidence["output_encoding_repaired"]
    assert hd(evidence["artifacts"])["content"] =~ "failed: �"
  end

  defp diagnosis(id) do
    %{
      "observed_failure" => "The assertion failed.",
      "likely_cause" => nil,
      "supporting_evidence" => [%{"artifact_id" => id, "start_line" => 1, "end_line" => 1}],
      "unknowns" => ["The implementation was not captured."],
      "next_check" => "Capture the implementation and rerun the focused test."
    }
  end
end
