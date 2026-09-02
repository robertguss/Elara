defmodule Mix.Tasks.Elara.Login do
  @shortdoc "Log in to Grok or OpenAI Codex"
  @moduledoc """
  Device-code login for Grok (the default) or a ChatGPT Codex subscription.

      mix elara.login
      mix elara.login grok
      mix elara.login openai
  """
  @requirements ["app.start"]
  use Mix.Task

  alias Elara.Auth
  alias Elara.Auth.OpenAICodex

  @impl true
  def run([]), do: login_grok()
  def run([provider]) when provider in ["grok", "xai"], do: login_grok()
  def run([provider]) when provider in ["openai", "openai-codex"], do: login_openai()

  def run(_argv) do
    Mix.shell().error("usage: mix elara.login [grok|openai]")
    exit({:shutdown, 1})
  end

  defp login_grok do
    Mix.shell().info("Requesting device code from xAI...")

    case Auth.request_device_code() do
      {:ok, response} ->
        user_code = Map.fetch!(response, "user_code")
        device_code = Map.fetch!(response, "device_code")

        verification_url =
          Map.get(response, "verification_uri_complete") ||
            Map.get(response, "verification_uri") ||
            Map.get(response, "verification_url")

        interval =
          case Map.get(response, "interval") do
            n when is_integer(n) and n > 0 -> n * 1000
            _ -> 5_000
          end

        Mix.shell().info("")
        Mix.shell().info("Open: #{verification_url}")
        Mix.shell().info("Code: #{user_code}")
        Mix.shell().info("")
        Mix.shell().info("Waiting for authorization...")

        case Auth.poll_token(device_code, interval_ms: interval) do
          {:ok, tokens} ->
            case Auth.save_tokens(tokens) do
              :ok ->
                Mix.shell().info("Logged in. Tokens saved to #{Auth.auth_path()}")

              {:error, reason} ->
                Mix.shell().error("Authorized but failed to save tokens: #{inspect(reason)}")
                exit({:shutdown, 1})
            end

          {:error, reason} ->
            Mix.shell().error("Login failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.shell().error("Device code request failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp login_openai do
    Mix.shell().info("Requesting device code from OpenAI...")

    case OpenAICodex.request_device_code() do
      {:ok, response} ->
        Mix.shell().info("")
        Mix.shell().info("Open: #{OpenAICodex.verification_url()}")
        Mix.shell().info("Code: #{response["user_code"]}")
        Mix.shell().info("")
        Mix.shell().info("Waiting for authorization...")

        result =
          OpenAICodex.poll_token(response["device_auth_id"], response["user_code"],
            interval_ms: response["interval_ms"]
          )

        case result do
          {:ok, tokens} ->
            case OpenAICodex.save_tokens(tokens) do
              :ok ->
                Mix.shell().info("Logged in. Tokens saved to #{OpenAICodex.auth_path()}")
                Mix.shell().info("Set ELARA_PROVIDER=openai-codex to use this login.")

              {:error, reason} ->
                Mix.shell().error("Authorized but failed to save tokens: #{inspect(reason)}")
                exit({:shutdown, 1})
            end

          {:error, reason} ->
            Mix.shell().error("Login failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.shell().error("Device code request failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
