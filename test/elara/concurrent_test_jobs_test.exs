Code.require_file("../support/concurrent_test_jobs.exs", __DIR__)

defmodule Elara.ConcurrentTestJobsTest do
  use ExUnit.Case, async: false
  alias Elara.Message

  @tag timeout: 60_000
  test "cancellation frees one of four slots without disturbing other jobs or duplicating delivery" do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-concurrent-offline-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if File.exists?(Path.join(root, "cleanup_complete")), do: File.rm_rf!(root)
    end)

    factory = fn ->
      {:ok, queue} =
        Agent.start_link(fn ->
          [
            {:ok,
             %Message.Assistant{
               tool_calls: [
                 %Message.ToolCall{
                   id: "status",
                   name: "test_job",
                   args: {:ok, %{"action" => "status", "job_id" => "focused"}}
                 }
               ]
             }},
            {:ok, %Message.Assistant{text: "CONCURRENT_JOB_COMPLETE"}}
          ]
        end)

      {{Elara.Provider.Scripted, queue}, fn -> Agent.stop(queue) end}
    end

    report = ConcurrentTestJobs.run(root, factory)
    for {check, passed} <- report.checks, do: assert(passed, "failed invariant: #{check}")
  end
end
