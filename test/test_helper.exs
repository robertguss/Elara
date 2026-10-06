# config/runtime.exs clears ELARA_* and XAI_API_KEY and puts TMPDIR and the
# state roots under one per-run directory before the application starts; this
# file only removes it. Tests tagged :requires_app are excluded under
# `mix test --no-start`.
exclude = if Process.whereis(Elara.Supervisor), do: [], else: [:requires_app]
ExUnit.start(exclude: exclude)

# Historical operation drivers exercise production primitives only in tests.
Code.require_file("support/fixtures/literal_patch.exs", __DIR__)
Code.require_file("support/fixtures/opaque_shell.exs", __DIR__)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(Application.fetch_env!(:elara, :test_run_dir))
end)
