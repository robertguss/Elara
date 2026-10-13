defmodule Elara.Config do
  @moduledoc "Runtime limits and env/auth resolution for providers."

  alias Elara.Auth
  alias Elara.Auth.OpenAICodex, as: OpenAICodexAuth
  alias Elara.Provider.Grok
  alias Elara.Provider.OpenAI
  alias Elara.Provider.OpenAICodex

  @limits [max_iterations: 100, tool_timeout_ms: 600_000, max_tool_timeout_ms: 3_600_000]

  @doc "Resolve positive runtime limits: session options, environment, app config, defaults."
  def runtime_limits(opts \\ [], env \\ System.get_env()) do
    resolve_positive(@limits, opts, env)
    |> case do
      {:ok, limits} ->
        if limits[:tool_timeout_ms] <= limits[:max_tool_timeout_ms],
          do: {:ok, limits},
          else: {:error, {:invalid_runtime_limit, :tool_timeout_ms}}

      error ->
        error
    end
  end

  def context_retention(opts \\ [], env \\ System.get_env()) do
    resolve_positive([context_keep_results: 5, context_keep_tokens: 20_000], opts, env)
  end

  defp resolve_positive(defaults, opts, env) do
    Enum.reduce_while(defaults, {:ok, []}, fn {key, default}, {:ok, limits} ->
      value =
        Keyword.get_lazy(opts, key, fn ->
          present(env, "ELARA_" <> String.upcase(Atom.to_string(key))) ||
            Application.get_env(:elara, key, default)
        end)

      parsed = if is_binary(value), do: Integer.parse(value), else: {value, ""}

      case parsed do
        {number, ""} when is_integer(number) and number > 0 ->
          {:cont, {:ok, Keyword.put(limits, key, number)}}

        _ ->
          {:halt, {:error, {:invalid_runtime_limit, key}}}
      end
    end)
  end

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

  def error_message(:server_token_required),
    do:
      "Set ELARA_SERVER_TOKEN to a shared random token of 32–512 bytes in the server and client terminals."

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
