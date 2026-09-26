# Mix starts :elara before this file runs, so the execution stub has already
# inherited the shell environment and the job managers have read the default
# sessions root. Clean the environment and state roots, then restart the app.
for {name, _value} <- System.get_env(),
    String.starts_with?(name, "ELARA_") or name == "XAI_API_KEY",
    do: System.delete_env(name)

sessions_root =
  Path.join(
    System.tmp_dir!(),
    "elara-test-sessions-#{System.unique_integer([:positive])}"
  )

# User skill roots resolve under this empty home instead of the developer's.
skills_home =
  Path.join(
    System.tmp_dir!(),
    "elara-test-home-#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(skills_home)
Application.put_env(:elara, :sessions_root, sessions_root)
Application.put_env(:elara, :skills_home, skills_home)

:ok = Application.stop(:elara)
{:ok, _apps} = Application.ensure_all_started(:elara)

ExUnit.start()

ExUnit.after_suite(fn _result ->
  File.rm_rf!(sessions_root)
  File.rm_rf!(skills_home)
end)
