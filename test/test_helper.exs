ExUnit.start()

# Keep the developer's shell configuration out of the suite.
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

ExUnit.after_suite(fn _result ->
  File.rm_rf!(sessions_root)
  File.rm_rf!(skills_home)
end)
