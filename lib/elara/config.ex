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
        with {:ok, source} <- codex_auth_source(env),
             {:ok, effort} <- codex_effort(env),
             {:ok, tokens} <- OpenAICodexAuth.load_tokens(source, env) do
          {:ok,
           {OpenAICodex, OpenAICodex.new(tokens, model: openai_codex_model(env), effort: effort)}}
        end

      "grok" ->
        load_grok()

      nil ->
        resolve_default(env)

      provider ->
        {:error, {:unknown_provider, provider}}
    end
  end

  def error_message(:codex_not_logged_in),
    do:
      "No reusable Codex login found. Sign in through Codex, then retry with ELARA_CODEX_AUTH_SOURCE=codex."

  def error_message(:invalid_codex_auth_file),
    do:
      "The Codex login file is invalid or unsupported. Sign in again through Codex; Elara will only read this file."

  def error_message(:codex_login_refresh_required),
    do:
      "Refresh your login in Codex, then retry Elara. Elara does not refresh or rotate borrowed Codex credentials."

  def error_message(reason), do: inspect(reason)

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

  defp openai_codex_model(env), do: present(env, "ELARA_MODEL") || OpenAICodex.default_model()

  defp codex_auth_source(env) do
    case present(env, "ELARA_CODEX_AUTH_SOURCE") do
      nil -> {:ok, :elara}
      "elara" -> {:ok, :elara}
      "codex" -> {:ok, :codex}
      source -> {:error, {:unknown_codex_auth_source, source}}
    end
  end

  defp codex_effort(env) do
    case present(env, "ELARA_REASONING_EFFORT") || "low" do
      effort when effort in ["low", "medium", "high", "xhigh"] -> {:ok, effort}
      effort -> {:error, {:invalid_reasoning_effort, effort}}
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
