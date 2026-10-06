import Config

# Mix evaluates this before starting :elara, so the execution stub and the
# job and thread managers never see the developer's environment or state.
if config_env() == :test do
  for {name, _value} <- System.get_env(),
      String.starts_with?(name, "ELARA_") or name == "XAI_API_KEY",
      do: System.delete_env(name)

  # One directory per run holds TMPDIR and every state root, so a crashed run's
  # leftovers never collide with a later run's unique_integer names. Mix may
  # evaluate this file more than once, and TMPDIR changes after the first pass,
  # so the directory is chosen once per VM with a random suffix (a reused OS pid
  # never reopens an old run).
  run_dir =
    case :persistent_term.get(:elara_test_run_dir, nil) do
      nil ->
        name = "elara-test-run-#{System.pid()}-#{:rand.uniform(1_000_000_000)}"
        dir = Path.join(System.tmp_dir!(), name)
        :persistent_term.put(:elara_test_run_dir, dir)
        dir

      dir ->
        dir
    end

  File.mkdir_p!(run_dir)
  System.put_env("TMPDIR", run_dir)
  System.put_env("ELARA_SERVER_TOKEN", "isolated-test-gateway-token-not-a-real-credential")

  # Crash-recovery tests kill Elara.TestJobs and Elara.Exec on purpose; under
  # OTP's default of 3 restarts in 5 seconds some test orders stop the whole
  # application (reproduced with seed 734866).
  config :elara,
    max_restarts: 100,
    test_run_dir: run_dir,
    sessions_root: Path.join(run_dir, "sessions"),
    skills_home: Path.join(run_dir, "home"),
    plugin_trust_root: Path.join(run_dir, "plugin-trust")
end
