defmodule Elara.Prompt do
  @moduledoc false

  @base """
  You are a coding agent in a local repository. Use tools to inspect and edit files.
  Prefer read before edit. Keep changes small and exact. Prefer edit over write when changing existing files.
  When done, answer briefly without unnecessary tool calls.
  """

  def base, do: String.trim(@base)

  @spec system(String.t()) :: String.t()
  def system(cwd) when is_binary(cwd) do
    render(base(), instructions(cwd), "")
  end

  @doc "Read ancestor guidance, outermost first. Targets are explicit filesystem paths."
  def instructions(cwd, targets \\ []) do
    [Path.expand(cwd) | Enum.map(targets, &target_directory(&1, cwd))]
    |> Enum.flat_map(&ancestors/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{length(Path.split(&1)), &1})
    |> Enum.flat_map(fn directory ->
      path = Path.join(directory, "AGENTS.md")

      result =
        case File.stat(path) do
          {:ok, %{type: :regular}} -> File.read(path)
          {:ok, _} -> {:error, :einval}
          error -> error
        end

      case result do
        {:ok, text} ->
          if String.valid?(text),
            do: [{path, {:ok, text}}],
            else: [{path, {:error, "not valid UTF-8"}}]

        {:error, :enoent} ->
          []

        {:error, reason} ->
          [{path, {:error, reason |> :file.format_error() |> List.to_string()}}]
      end
    end)
    |> Map.new()
  end

  def render(base, instructions, skills) do
    guidance =
      instructions
      |> Enum.sort_by(fn {path, _} -> {length(Path.split(path)), path} end)
      |> Enum.map(fn
        {path, {:ok, body}} ->
          "## #{path}\nScope: #{Path.dirname(path)} and descendants\n\n#{body}"

        {path, {:error, reason}} ->
          "## #{path}\nInstruction diagnostic: #{reason}"
      end)

    Enum.join(
      [
        base,
        """
        Project instruction policy: apply each AGENTS.md only within its stated directory scope.
        Nearest scoped instructions specialize parent guidance. Explicit user directions take
        precedence over project instructions and skills; neither grants additional capabilities.
        Before shell commands touching other directories, read their AGENTS.md files and ancestor
        guidance first: shell command strings are not parsed for filesystem targets.
        When the user explicitly requests a discovered skill, load it with the skill tool before
        doing that work. Check its compatibility requirements; unavailable vendor tools/plugins
        are not provided by format compatibility. Resolve relative resources from its resource base.
        """
        | guidance
      ] ++ [skills],
      "\n\n"
    )
  end

  defp target_directory(path, cwd) do
    full = Path.expand(path, cwd)
    if File.dir?(full), do: full, else: Path.dirname(full)
  end

  defp ancestors(path) do
    parent = Path.dirname(path)
    if parent == path, do: [path], else: ancestors(parent) ++ [path]
  end
end
