# Opt-in real-provider interpretation after host-controlled concurrent execution.
# mix run --no-start test/support/concurrent_test_jobs_live.exs OUTPUT.json
Code.require_file("concurrent_test_jobs.exs", __DIR__)

case System.argv() do
  [output] ->
    if Process.whereis(Elara.Exec), do: raise("Use mix run --no-start")
    root = Path.join(System.tmp_dir!(), "elara-concurrent-live-#{System.pid()}")
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    {:ok, _} = Application.ensure_all_started(:elara)

    env =
      Map.merge(System.get_env(), %{
        "ELARA_PROVIDER" => "openai-codex",
        "ELARA_CODEX_AUTH_SOURCE" => "codex",
        "ELARA_MODEL" => "gpt-5.5",
        "ELARA_REASONING_EFFORT" => "low"
      })

    {:ok, provider} = Elara.Config.resolve(env)
    report = ConcurrentTestJobs.run(root, fn -> {provider, fn -> :ok end} end)
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    report =
      Map.merge(report, %{
        date: Date.to_iso8601(Date.utc_today()),
        revision: String.trim(revision),
        settings: %{model: "gpt-5.5", effort: "low"},
        assistance:
          "Host starts, rejects, cancels, deduplicates and releases gated real Mix fixtures through TestJobs.run. Owners stay paused through terminal delivery, then host resumes them. Real models only inspect retained status once and interpret completion. No model polling, runtime changes or autonomous cancellation claims. Fixture entry markers count admitted test entries; PID markers identify top-level Mix VMs, and process checks do not cover detached descendants.",
        retained_root: root
      })

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(report))
    IO.inspect(report.checks, label: "CHECKS")
    IO.puts("Evidence: #{output}; retained records: #{root}")
    unless Enum.all?(report.checks, &elem(&1, 1)), do: raise("Experiment checks failed")

  _ ->
    raise "usage: mix run --no-start test/support/concurrent_test_jobs_live.exs OUTPUT.json"
end
