defmodule Elara.Config do
  @moduledoc "Env and auth resolution for providers."

  alias Elara.Auth
  alias Elara.Auth.OpenAICodex, as: OpenAICodexAuth
  alias Elara.Provider.Grok
  alias Elara.Provider.OpenAI
  alias Elara.Provider.OpenAICodex

  @doc """
  Resolve provider config.

  `ELARA_PROVIDER=openai-codex` selects saved ChatGPT subscription credentials.
  Otherwise prefer ELARA_API_KEY, then XAI_API_KEY (optional ELARA_BASE_URL /
  ELARA_MODEL), then saved Grok OAuth tokens.
  """
  @spec resolve(%{String.t() => String.t()}) ::
          {:ok, {module(), term()}} | {:error, term()}
  def resolve(env \\ System.get_env()) do
    case present(env, "ELARA_PROVIDER") do
      "openai-codex" ->
        with {:ok, tokens} <- OpenAICodexAuth.load_tokens() do
          {:ok, {OpenAICodex, OpenAICodex.new(tokens, model: openai_codex_model(env))}}
        end

      "grok" ->
        load_grok()

      nil ->
        resolve_default(env)

      provider ->
        {:error, {:unknown_provider, provider}}
    end
  end

  defp resolve_default(env) do
    cond do
      key = present(env, "ELARA_API_KEY") -> {:ok, {OpenAI, env_openai(env, key)}}
      key = present(env, "XAI_API_KEY") -> {:ok, {OpenAI, env_openai(env, key)}}
      true -> load_grok()
    end
  end

  defp load_grok do
    with {:ok, tokens} <- Auth.load_tokens() do
      {:ok, {Grok, Grok.new(tokens)}}
    end
  end

  defp openai_codex_model(env), do: present(env, "ELARA_MODEL") || "gpt-5.3-codex"

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
