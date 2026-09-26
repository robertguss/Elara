# config/runtime.exs clears ELARA_* and XAI_API_KEY and sets isolated state
# roots before the application starts; this file only cleans them up.
ExUnit.start()

ExUnit.after_suite(fn _result ->
  File.rm_rf!(Application.fetch_env!(:elara, :sessions_root))
  File.rm_rf!(Application.fetch_env!(:elara, :skills_home))
end)
