defmodule Harness.Prompt do
  @moduledoc false

  @base """
  You are a coding agent in a local repository. Use tools to inspect and edit files.
  Prefer read before edit. Keep changes small and exact. Prefer edit over write when changing existing files.
  When done, answer briefly without unnecessary tool calls.
  """

  @spec system(String.t()) :: String.t()
  def system(cwd) when is_binary(cwd) do
    case File.read(Path.join(cwd, "AGENTS.md")) do
      {:ok, agents} -> String.trim(@base) <> "\n\n# AGENTS.md\n\n" <> String.trim(agents)
      {:error, _} -> String.trim(@base)
    end
  end
end
