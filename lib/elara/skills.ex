defmodule Elara.Skills do
  @moduledoc "Discovery and selective loading of Agent Skills."

  alias Elara.Tool

  @known_fields ~w(name description license compatibility metadata allowed-tools)
  @name_re ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @spec discover(Path.t(), keyword()) :: %{
          skills: map(),
          diagnostics: [String.t()],
          options: keyword()
        }
  def discover(cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    home = Path.expand(Keyword.get(opts, :home, System.user_home!()))
    explicit = Enum.map(Keyword.get(opts, :skill_paths, env_paths()), &Path.expand(&1, cwd))

    sources =
      Enum.map(explicit, &{&1, "explicit", true}) ++
        Enum.map(project_roots(cwd), &{&1, "project", false}) ++
        [
          {Path.join(home, ".config/agents/skills"), "user-config", false},
          {Path.join(home, ".agents/skills"), "user-legacy", false}
        ]

    {skills, diagnostics} =
      Enum.reduce(sources, {%{}, []}, fn source, acc -> discover_source(source, acc) end)

    %{skills: skills, diagnostics: diagnostics, options: [home: home, skill_paths: explicit]}
  end

  @spec summary(map()) :: String.t()
  def summary(%{skills: skills, diagnostics: diagnostics}) do
    entries =
      skills
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {_name, skill} ->
        compatibility =
          if skill.compatibility,
            do: " Compatibility (check these dependencies before use): #{skill.compatibility}",
            else: ""

        warnings =
          case skill.warnings do
            [] -> ""
            values -> " Warnings: " <> Enum.join(values, "; ")
          end

        "- #{skill.name}: #{skill.description} [source: #{skill.source}; path: #{skill.path}]" <>
          compatibility <> warnings
      end)

    diagnostic_lines = Enum.map(diagnostics, &"- #{&1}")

    ([
       "Available skills (metadata only; instruction bodies have not been loaded).",
       "Use the `skill` tool with a skill name to selectively load its instructions. Loading a skill does not add capabilities or start vendor tools/plugins."
     ] ++
       entries ++
       ["Diagnostics:"] ++ if(diagnostic_lines == [], do: ["- none"], else: diagnostic_lines))
    |> Enum.join("\n")
  end

  @spec load(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def load(%{skills: skills}, name) when is_binary(name) do
    case Map.fetch(skills, name) do
      :error ->
        {:error, "unknown skill #{inspect(name)}"}

      {:ok, skill} ->
        with {:ok, text} <- read_metadata_file(skill.path),
             {:ok, yaml} <- frontmatter(text, skill.path),
             {:ok, data} <- parse_yaml(yaml, skill.path),
             :ok <- validate(data, name, skill.path) do
          {:ok,
           "Resource base path: #{skill.directory}\nRead referenced resources with the read tool. Execute referenced scripts only through the ordinary bash tool; this skill does not execute anything independently or change capabilities. Experimental allowed-tools and vendor-specific fields are not enabled. Check compatibility requirements before executing; report missing dependencies instead of assuming vendor integrations exist.\n\n" <>
             text}
        else
          {:error, reason} ->
            {:error, "cannot load skill #{inspect(name)} from #{skill.path}: #{reason}"}
        end
    end
  end

  def load(_catalog, name), do: {:error, "invalid skill name #{inspect(name)}"}

  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "skill",
      description: "Load one discovered skill's full instructions by name.",
      parameters: %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "description" => "Skill name"}},
        "required" => ["name"]
      },
      run: {__MODULE__, :load},
      capabilities: ["filesystem:read"],
      placement: :local
    }
  end

  defp discover_source({path, kind, explicit?}, {skills, diagnostics}) do
    candidates =
      cond do
        File.exists?(Path.join(path, "SKILL.md")) -> {:ok, [path]}
        true -> list_skill_dirs(path, explicit?)
      end

    case candidates do
      {:error, diagnostic} -> {skills, diagnostics ++ [diagnostic]}
      {:ok, dirs} -> Enum.reduce(dirs, {skills, diagnostics}, &discover_dir(&1, kind, &2))
    end
  end

  defp list_skill_dirs(path, explicit?) do
    case File.ls(path) do
      {:ok, children} ->
        dirs =
          children
          |> Enum.sort()
          |> Enum.map(&Path.join(path, &1))
          |> Enum.filter(&(File.dir?(&1) and File.exists?(Path.join(&1, "SKILL.md"))))

        {:ok, dirs}

      {:error, :enoent} when not explicit? ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot inspect skill path #{path}: #{file_error(reason)}"}
    end
  end

  defp discover_dir(directory, kind, {skills, diagnostics}) do
    path = Path.expand(Path.join(directory, "SKILL.md"))
    identity = "#{kind}:#{path}"

    case metadata(path, directory, identity) do
      {:error, message} ->
        {skills, diagnostics ++ [message]}

      {:ok, entry, warnings} ->
        case Map.fetch(skills, entry.name) do
          :error ->
            {Map.put(skills, entry.name, entry), diagnostics ++ warnings}

          {:ok, selected} ->
            warning =
              "duplicate skill #{inspect(entry.name)}: selected #{selected.source}, shadowed #{identity}"

            {skills, diagnostics ++ warnings ++ [warning]}
        end
    end
  end

  defp metadata(path, directory, identity) do
    with {:ok, contents} <- read_metadata_file(path),
         {:ok, yaml} <- frontmatter(contents, path),
         {:ok, data} <- parse_yaml(yaml, path),
         :ok <- validate(data, Path.basename(directory), path) do
      unknown = Map.keys(data) -- @known_fields

      warnings =
        Enum.map(Enum.sort(unknown), &"#{path}: unsupported frontmatter field #{inspect(&1)}") ++
          if(Map.has_key?(data, "allowed-tools"),
            do: ["#{path}: experimental allowed-tools is ignored"],
            else: []
          )

      entry = %{
        name: data["name"],
        description: data["description"],
        path: path,
        directory: Path.dirname(path),
        compatibility: data["compatibility"],
        license: data["license"],
        metadata: data["metadata"] || %{},
        warnings: warnings,
        source: identity
      }

      {:ok, entry, warnings}
    end
  end

  defp read_metadata_file(path) do
    result =
      case File.stat(path) do
        {:ok, %{type: :regular}} -> File.read(path)
        {:ok, _} -> {:error, :einval}
        error -> error
      end

    case result do
      {:ok, contents} ->
        if String.valid?(contents),
          do: {:ok, contents},
          else: {:error, "cannot read #{path}: not valid UTF-8"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{file_error(reason)}"}
    end
  end

  defp frontmatter(contents, path) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s, contents) do
      [_, yaml] -> {:ok, yaml}
      _ -> {:error, "#{path}: SKILL.md must contain complete YAML frontmatter delimiters"}
    end
  end

  defp parse_yaml(yaml, path) do
    try do
      case YamlElixir.read_from_string(yaml) do
        {:ok, data} when is_map(data) -> {:ok, data}
        {:ok, _} -> {:error, "#{path}: YAML frontmatter must be a mapping"}
        {:error, error} -> {:error, "#{path}: malformed YAML frontmatter: #{inspect(error)}"}
      end
    rescue
      error -> {:error, "#{path}: malformed YAML frontmatter: #{Exception.message(error)}"}
    catch
      kind, error -> {:error, "#{path}: malformed YAML frontmatter: #{inspect({kind, error})}"}
    end
  end

  defp validate(data, parent, path) do
    cond do
      not Enum.all?(Map.keys(data), &is_binary/1) ->
        invalid(path, "frontmatter field names must be strings")

      not is_binary(data["name"]) ->
        invalid(path, "name is required and must be a string")

      String.length(data["name"]) > 64 or not Regex.match?(@name_re, data["name"]) ->
        invalid(path, "name must be <=64 lowercase letters, numbers, and single hyphens")

      data["name"] != parent ->
        invalid(path, "name must match parent directory #{inspect(parent)}")

      not is_binary(data["description"]) or String.trim(data["description"]) == "" or
          String.length(data["description"]) > 1024 ->
        invalid(path, "description is required and must be a nonempty string <=1024 characters")

      Map.has_key?(data, "license") and not is_binary(data["license"]) ->
        invalid(path, "license must be a string")

      Map.has_key?(data, "compatibility") and
          (not is_binary(data["compatibility"]) or
             String.length(data["compatibility"]) not in 1..500) ->
        invalid(path, "compatibility must be a nonempty string <=500 characters")

      Map.has_key?(data, "metadata") and not string_map?(data["metadata"]) ->
        invalid(path, "metadata must be a map of string keys to string values")

      true ->
        :ok
    end
  end

  defp string_map?(value),
    do: is_map(value) and Enum.all?(value, fn {key, val} -> is_binary(key) and is_binary(val) end)

  defp invalid(path, message), do: {:error, "#{path}: #{message}"}

  defp project_roots(cwd) do
    ancestors = ancestors(cwd)

    scoped =
      case Enum.find_index(
             ancestors,
             &(File.dir?(Path.join(&1, ".git")) or File.regular?(Path.join(&1, ".git")))
           ) do
        nil -> ancestors
        index -> Enum.take(ancestors, index + 1)
      end

    Enum.map(scoped, &Path.join(&1, ".agents/skills"))
  end

  defp ancestors(path) do
    Stream.iterate(path, &Path.dirname/1)
    |> Enum.reduce_while([], fn current, acc ->
      if acc != [] and current == hd(acc), do: {:halt, acc}, else: {:cont, [current | acc]}
    end)
    |> Enum.reverse()
  end

  defp env_paths do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    System.get_env("ELARA_SKILL_PATHS", "")
    |> String.split(separator, trim: true)
  end

  defp file_error(reason), do: reason |> :file.format_error() |> List.to_string()
end
