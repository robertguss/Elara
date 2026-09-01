defmodule Elara.Benchmark.Dogfood.Redactor do
  @moduledoc false

  @redacted "[REDACTED]"
  @secret_keys ~w(
    access_token
    api_key
    authorization
    cookie
    password
    private_key
    refresh_token
    secret
  )
  @value_patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/-]{8,}/i,
    ~r/\b(?:sk|xai)-[A-Za-z0-9_-]{8,}\b/,
    ~r/\bgh[oprsu]_[A-Za-z0-9]{12,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/
  ]

  @spec redact(term()) :: term()
  def redact(value), do: redact_value(value)

  @spec secret_paths(term()) :: [[String.t() | non_neg_integer()]]
  def secret_paths(value), do: value |> find_paths([], []) |> Enum.reverse()

  defp redact_value(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key), do: {key, @redacted}, else: {key, redact_value(value)}
    end)
  end

  defp redact_value(list) when is_list(list), do: Enum.map(list, &redact_value/1)

  defp redact_value(value) when is_binary(value) do
    Enum.reduce(@value_patterns, value, &Regex.replace(&1, &2, @redacted))
  end

  defp redact_value(value), do: value

  defp find_paths(map, path, found) when is_map(map) do
    Enum.reduce(map, found, fn {key, value}, paths ->
      key_path = path ++ [to_string(key)]

      if secret_key?(key) do
        [key_path | paths]
      else
        find_paths(value, key_path, paths)
      end
    end)
  end

  defp find_paths(list, path, found) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(found, fn {value, index}, paths ->
      find_paths(value, path ++ [index], paths)
    end)
  end

  defp find_paths(value, path, found) when is_binary(value) do
    if Enum.any?(@value_patterns, &Regex.match?(&1, value)), do: [path | found], else: found
  end

  defp find_paths(_value, _path, found), do: found

  defp secret_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in @secret_keys or
      Enum.any?(
        ~w(_api_key _access_token _refresh_token _password _private_key _secret),
        &String.ends_with?(normalized, &1)
      )
  end
end
