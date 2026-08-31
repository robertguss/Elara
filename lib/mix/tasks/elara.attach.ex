defmodule Mix.Tasks.Elara.Attach do
  use Mix.Task

  @shortdoc "Create or attach to a server-owned session"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    Elara.Attach.main(argv)
  end
end
