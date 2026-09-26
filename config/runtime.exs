import Config

# Mix evaluates this before starting :elara, so the execution stub and the
# job and thread managers never see the developer's environment or state.
if config_env() == :test do
  cleared =
    for {name, _value} <- System.get_env(),
        String.starts_with?(name, "ELARA_") or name == "XAI_API_KEY" do
      System.delete_env(name)
      name
    end

  # Mix may evaluate this file more than once per run; derive paths from the OS
  # pid so every evaluation agrees. Neither directory needs to exist up front:
  # the store creates its root, and missing user skill roots are empty.
  run = System.pid()
  sessions_root = Path.join(System.tmp_dir!(), "elara-test-sessions-#{run}")
  skills_home = Path.join(System.tmp_dir!(), "elara-test-home-#{run}")

  config :elara,
    sessions_root: sessions_root,
    skills_home: skills_home,
    test_cleared_env: Enum.sort(cleared)
end
