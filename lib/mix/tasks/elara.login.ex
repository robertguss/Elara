defmodule Mix.Tasks.Elara.Login do
  @shortdoc "Log in to Grok, OpenAI Codex, or Exa"
  @moduledoc """
  Device-code login for Grok (the default) or a ChatGPT Codex subscription.

      mix elara.login
      mix elara.login grok
      mix elara.login openai
      mix elara.login exa
  """
  @requirements ["app.start"]
  use Mix.Task

  alias Elara.Auth
  alias Elara.Auth.OpenAICodex

  @impl true
  def run([]), do: login_grok()
  def run([provider]) when provider in ["grok", "xai"], do: login_grok()
  def run([provider]) when provider in ["openai", "openai-codex"], do: login_openai()
  def run(["exa"]), do: login_exa()

  def run(_argv) do
    Mix.shell().error("usage: mix elara.login [grok|openai|exa]")
    exit({:shutdown, 1})
  end

  defp login_exa do
    result =
      with options when is_list(options) <- :io.getopts(),
           true <- options[:terminal] == true and options[:stdin] == true,
           {tty, 0} <- System.cmd("ps", ["-p", System.pid(), "-o", "tty="]),
           tty = Path.join("/dev", String.trim(tty)),
           {mode, 0} <-
             System.cmd("sh", ["-c", "stty -g < \"$1\"", "elara-login", tty],
               stderr_to_stdout: true
             ),
           {_, 0} <-
             System.cmd("sh", ["-c", "stty -echo < \"$1\"", "elara-login", tty],
               stderr_to_stdout: true
             ) do
        try do
          case IO.gets("Exa API key (hidden): ") do
            key when is_binary(key) -> Elara.Auth.Exa.save_key(String.trim(key))
            _ -> {:error, :no_key}
          end
        after
          System.cmd("sh", ["-c", "stty \"$1\" < \"$2\"", "elara-login", String.trim(mode), tty],
            stderr_to_stdout: true
          )

          IO.puts("")
        end
      else
        _ -> {:error, :not_interactive}
      end

    case result do
      :ok ->
        Mix.shell().info("Exa key saved to #{Elara.Auth.Exa.auth_path()}")

      _ ->
        Mix.shell().error("Exa login failed; enter a non-empty key at an interactive terminal.")
        exit({:shutdown, 1})
    end
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
