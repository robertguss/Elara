defmodule Elara.CommandRules do
  @moduledoc "Command-text guardrails, not a shell parser or OS sandbox."

  @empty %{"deny" => [], "ask" => []}
  @max_bytes 65_536

  def startup do
    case System.get_env("ELARA_COMMAND_RULES") do
      nil ->
        @empty

      bytes ->
        case parse(bytes) do
          {:ok, rules} -> rules
          {:error, reason} -> raise ArgumentError, "ELARA_COMMAND_RULES: #{reason}"
        end
    end
  end

  def review(cwd, previous, operator) do
    with {:ok, bytes} <- read(Path.join(cwd, ".elara/command-rules.json")),
         {:ok, proposed} <- parse(bytes) do
      previous = previous || @empty
      retained = merge(previous, proposed)
      effective = merge(operator, retained)
      loosening = not subsumes?(proposed, previous)

      {:ok,
       %{
         bytes: bytes,
         proposed: proposed,
         retained: retained,
         effective: effective,
         loosening: loosening
       }}
    end
  end

  def classify(rules, command) do
    case Enum.find(rules["deny"], &String.contains?(command, &1)) do
      nil ->
        case Enum.find(rules["ask"], &String.contains?(command, &1)) do
          nil -> :allow
          rule -> {:ask, rule}
        end

      rule ->
        {:deny, rule}
    end
  end

  def parse(nil), do: {:ok, @empty}

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, rules} when is_map(rules) <- JSON.decode(bytes),
         true <- Enum.all?(Map.keys(rules), &(&1 in ["deny", "ask"])),
         deny <- Map.get(rules, "deny", []),
         ask <- Map.get(rules, "ask", []),
         true <- names?(deny) and names?(ask) do
      {:ok, %{"deny" => Enum.uniq(deny), "ask" => Enum.uniq(ask)}}
    else
      _ -> {:error, "expected an object with deny/ask arrays of nonempty command substrings"}
    end
  end

  def parse(_), do: {:error, "command rules exceed #{@max_bytes} bytes"}

  defp names?(names) when is_list(names),
    do: Enum.all?(names, &(is_binary(&1) and byte_size(&1) > 0))

  defp names?(_), do: false

  defp merge(a, b),
    do: Map.new(["deny", "ask"], &{&1, Enum.uniq(a[&1] ++ b[&1])})

  defp subsumes?(new, old) do
    Enum.all?(old["deny"], &(&1 in new["deny"])) and
      Enum.all?(old["ask"], &(&1 in new["ask"] or &1 in new["deny"]))
  end

  defp read(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, "cannot read command rules: #{inspect(reason)}"}
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      {:ok, _} -> {:error, "command rules exceed #{@max_bytes} bytes"}
      {:error, reason} -> {:error, "cannot read command rules: #{inspect(reason)}"}
    end
  end
end
