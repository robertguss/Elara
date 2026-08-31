ExUnit.start()

sessions_root =
  Path.join(
    System.tmp_dir!(),
    "elara-test-sessions-#{System.unique_integer([:positive])}"
  )

Application.put_env(:elara, :sessions_root, sessions_root)
ExUnit.after_suite(fn _result -> File.rm_rf!(sessions_root) end)
