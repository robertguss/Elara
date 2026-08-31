defmodule Mix.Tasks.Elara.Login do
  @shortdoc "Log in to Grok via OAuth device code"
  @moduledoc """
  Device-code login against auth.x.ai. Writes tokens to ~/.elara/auth.json.
  """
  @requirements ["app.start"]
  use Mix.Task

  alias Elara.Auth

  @impl true
  def run(_argv) do
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
end
