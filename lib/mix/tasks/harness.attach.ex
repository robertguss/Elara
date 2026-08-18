defmodule Mix.Tasks.Harness.Attach do
  use Mix.Task

  @shortdoc "Create or attach to a server-owned session"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    Harness.Attach.main(argv)
  end
end
