ExUnit.start()

sessions_root =
  Path.join(
    System.tmp_dir!(),
    "harness-test-sessions-#{System.unique_integer([:positive])}"
  )

Application.put_env(:harness, :sessions_root, sessions_root)
ExUnit.after_suite(fn _result -> File.rm_rf!(sessions_root) end)
