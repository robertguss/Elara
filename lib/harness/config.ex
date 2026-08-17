defmodule Harness.Config do
  @moduledoc "Env and auth resolution for providers."

  alias Harness.Auth
  alias Harness.Provider.OpenAI

  @spec from_env(%{String.t() => String.t()}) ::
          {:ok, OpenAI.config()} | {:error, {:missing_env, [String.t()]}}
  def from_env(env) when is_map(env) do
    key = Map.get(env, "HARNESS_API_KEY")
    model = Map.get(env, "HARNESS_MODEL")
    base = Map.get(env, "HARNESS_BASE_URL", "https://api.openai.com/v1")

    missing =
      []
      |> then(fn m -> if blank?(key), do: ["HARNESS_API_KEY" | m], else: m end)
      |> then(fn m -> if blank?(model), do: ["HARNESS_MODEL" | m], else: m end)
      |> Enum.reverse()

    case missing do
      [] ->
        {:ok, %OpenAI{api_key: key, base_url: base, model: model}}

      missing ->
        {:error, {:missing_env, missing}}
    end
  end

  @doc """
  Resolve provider config for CLI use.

  Prefer HARNESS_API_KEY (+ optional HARNESS_BASE_URL / HARNESS_MODEL).
  Otherwise load Grok OAuth tokens from ~/.harness/auth.json (importing ~/.grok if needed).
  """
  @spec resolve(%{String.t() => String.t()}) ::
          {:ok, {module(), term()}} | {:error, term()}
  def resolve(env \\ System.get_env()) do
    cond do
      not blank?(Map.get(env, "HARNESS_API_KEY")) ->
        model = Map.get(env, "HARNESS_MODEL") || Map.get(env, "XAI_MODEL") || "grok-4"
        base = Map.get(env, "HARNESS_BASE_URL") || "https://api.x.ai/v1"

        {:ok,
         {OpenAI,
          %OpenAI{
            api_key: Map.fetch!(env, "HARNESS_API_KEY"),
            base_url: base,
            model: model
          }}}

      not blank?(Map.get(env, "XAI_API_KEY")) ->
        model = Map.get(env, "HARNESS_MODEL") || Map.get(env, "XAI_MODEL") || "grok-4"

        {:ok,
         {OpenAI,
          %OpenAI{
            api_key: Map.fetch!(env, "XAI_API_KEY"),
            base_url: Map.get(env, "HARNESS_BASE_URL") || "https://api.x.ai/v1",
            model: model
          }}}

      true ->
        case Auth.load_tokens() do
          {:ok, tokens} ->
            {:ok, {Harness.Provider.Grok, Harness.Provider.Grok.new(tokens)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
end
