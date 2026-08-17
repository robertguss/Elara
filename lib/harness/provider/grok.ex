defmodule Harness.Provider.Grok do
  @moduledoc "Grok chat via xAI with OAuth token refresh threaded through config."

  @behaviour Harness.Provider

  alias Harness.Auth
  alias Harness.Provider
  alias Harness.Provider.Error
  alias Harness.Provider.OpenAI

  @derive {Inspect, except: [:tokens]}
  defstruct [:tokens, :model, :base_url, :now_s, :refresh]

  @type config :: %__MODULE__{
          tokens: Auth.t(),
          model: String.t(),
          base_url: String.t(),
          now_s: (-> integer()),
          refresh: (Auth.t() -> {:ok, Auth.t()} | {:error, term()})
        }

  @spec new(Auth.t(), keyword()) :: config()
  def new(%Auth{} = tokens, opts \\ []) do
    %__MODULE__{
      tokens: tokens,
      model: Keyword.get(opts, :model, "grok-4"),
      base_url: Keyword.get(opts, :base_url, "https://api.x.ai/v1"),
      now_s: Keyword.get(opts, :now_s, fn -> System.system_time(:second) end),
      refresh: Keyword.get(opts, :refresh, &Auth.refresh/1)
    }
  end

  @impl true
  def chat(%__MODULE__{} = config, %Provider.Request{} = request) do
    case maybe_refresh(config) do
      {:ok, config} ->
        openai = %OpenAI{
          api_key: config.tokens.access_token,
          base_url: config.base_url,
          model: config.model
        }

        case OpenAI.chat(openai, request) do
          {:ok, assistant, _} -> {:ok, assistant, config}
          {:error, %Error{} = err, _} -> {:error, err, config}
        end

      {:error, err, config} ->
        {:error, err, config}
    end
  end

  defp maybe_refresh(%__MODULE__{} = config) do
    if Auth.expired?(config.tokens, config.now_s.()) do
      case config.refresh.(config.tokens) do
        {:ok, tokens} ->
          {:ok, %{config | tokens: tokens}}

        {:error, reason} ->
          {:error, %Error{kind: :transport, message: "token refresh failed: #{inspect(reason)}"},
           config}
      end
    else
      {:ok, config}
    end
  end
end
