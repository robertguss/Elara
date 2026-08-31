defmodule Elara.Config do
  @moduledoc "Env and auth resolution for providers."

  alias Elara.Auth
  alias Elara.Provider.Grok
  alias Elara.Provider.OpenAI

  @doc """
  Resolve provider config.

  Prefer ELARA_API_KEY, then XAI_API_KEY (optional ELARA_BASE_URL / ELARA_MODEL).
  Otherwise load Grok OAuth tokens from ~/.elara/auth.json (importing ~/.grok if needed).
  """
  @spec resolve(%{String.t() => String.t()}) ::
          {:ok, {module(), term()}} | {:error, term()}
  def resolve(env \\ System.get_env()) do
    cond do
      key = present(env, "ELARA_API_KEY") ->
        {:ok, {OpenAI, env_openai(env, key)}}

      key = present(env, "XAI_API_KEY") ->
        {:ok, {OpenAI, env_openai(env, key)}}

      true ->
        case Auth.load_tokens() do
          {:ok, tokens} ->
            {:ok, {Grok, Grok.new(tokens)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp env_openai(env, key) do
    %OpenAI{
      api_key: key,
      base_url: Map.get(env, "ELARA_BASE_URL") || "https://api.x.ai/v1",
      model: Map.get(env, "ELARA_MODEL") || Map.get(env, "XAI_MODEL") || "grok-4"
    }
  end

  defp present(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end
end
