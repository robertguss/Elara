defmodule Mix.Tasks.Elara.Launch do
  use Mix.Task

  @moduledoc false

  @impl true
  def run([caller | argv]) do
    # Finish all checkout-relative config/build work before starting any Elara
    # processes. Relative credentials and state paths then belong to the caller.
    Mix.Task.run("app.config")
    binary = Mix.Tasks.Elara.Tui.binary!()
    File.cd!(caller)
    Mix.Task.run("app.start", ["--no-compile"])
    Mix.Tasks.Elara.Tui.run_binary(binary, ["--default-new" | argv])
  end
end
