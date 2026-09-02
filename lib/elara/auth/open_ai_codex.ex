defmodule Elara.Auth.OpenAICodex do
  @moduledoc "OpenAI Codex subscription device login and token persistence."

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @device_code_url "https://auth.openai.com/api/accounts/deviceauth/usercode"
  @device_token_url "https://auth.openai.com/api/accounts/deviceauth/token"
  @verification_url "https://auth.openai.com/codex/device"
  @token_url "https://auth.openai.com/oauth/token"
  @redirect_url "https://auth.openai.com/deviceauth/callback"
  @refresh_skew_seconds 300
  @poll_timeout_ms 15 * 60 * 1_000
  @form_headers [{"content-type", "application/x-www-form-urlencoded"}]

  @derive {Inspect, except: [:access_token, :refresh_token]}
  defstruct [:access_token, :refresh_token, :expires_at, :account_id]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer(),
          account_id: String.t()
        }

  @spec verification_url() :: String.t()
  def verification_url, do: @verification_url

  @spec auth_path() :: String.t()
  def auth_path do
    case Application.get_env(:elara, :openai_codex_auth_path) do
      path when is_binary(path) and path != "" -> path
      _ -> Path.join([System.user_home!(), ".elara", "openai-codex-auth.json"])
    end
  end

  @spec request_device_code(keyword()) :: {:ok, map()} | {:error, term()}
  def request_device_code(opts \\ []) do
    http = Keyword.get(opts, :http, &Req.post/2)

    case http.(@device_code_url,
           json: %{"client_id" => @client_id},
           decode_body: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        with {:ok, map} <- decode_map(body),
             device_auth_id when is_binary(device_auth_id) and device_auth_id != "" <-
               Map.get(map, "device_auth_id"),
             user_code when is_binary(user_code) and user_code != "" <-
               Map.get(map, "user_code"),
             {:ok, interval_ms} <- poll_interval(Map.get(map, "interval")) do
          {:ok,
           %{
             "device_auth_id" => device_auth_id,
             "user_code" => user_code,
             "interval_ms" => interval_ms
           }}
        else
          _ -> {:error, :invalid_device_code_response}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:device_code_http, status, body_snippet(body)}}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec poll_token(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def poll_token(device_auth_id, user_code, opts \\ [])
      when is_binary(device_auth_id) and is_binary(user_code) do
    http = Keyword.get(opts, :http, &Req.post/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    interval_ms = Keyword.get(opts, :interval_ms, 5_000)
    deadline = Keyword.get(opts, :deadline_ms, now_ms.() + @poll_timeout_ms)

    do_poll(device_auth_id, user_code, http, sleep, now_ms, interval_ms, deadline)
  end

  @spec save_tokens(t()) :: :ok | {:error, term()}
  def save_tokens(%__MODULE__{} = tokens) do
    path = auth_path()
    dir = Path.dirname(path)
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    payload =
      JSON.encode!(%{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token,
        "expires_at" => tokens.expires_at,
        "account_id" => tokens.account_id
      })

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, payload),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @spec load_tokens() :: {:ok, t()} | {:error, term()}
  def load_tokens do
    with {:ok, body} <- File.read(auth_path()),
         {:ok, map} <- decode_map(body),
         {:ok, tokens} <- tokens_from_saved_map(map) do
      {:ok, tokens}
    else
      {:error, :enoent} -> {:error, :not_logged_in}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec refresh_if_needed(t()) :: {:ok, t()} | {:error, term()}
  def refresh_if_needed(%__MODULE__{} = tokens) do
    if expired?(tokens, System.system_time(:second)) do
      case :global.trans({{__MODULE__, :refresh}, self()}, fn -> refresh_latest(tokens) end) do
        :aborted -> {:error, :refresh_lock}
        result -> result
      end
    else
      {:ok, tokens}
    end
  end

  @spec refresh(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def refresh(%__MODULE__{refresh_token: refresh_token}, opts \\ []) do
    http = Keyword.get(opts, :http, &Req.post/2)

    with {:ok, map} <-
           post_form(http, %{
             "grant_type" => "refresh_token",
             "refresh_token" => refresh_token,
             "client_id" => @client_id
           }),
         {:ok, tokens} <- tokens_from_response(map),
         :ok <- save_tokens(tokens) do
      {:ok, tokens}
    end
  end

  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now)
      when is_integer(expires_at) and is_integer(now),
      do: now >= expires_at - @refresh_skew_seconds

  def expired?(%__MODULE__{}, _now), do: true

  @doc false
  @spec account_id(String.t()) :: {:ok, String.t()} | {:error, :invalid_access_token}
  def account_id(access_token) when is_binary(access_token) do
    with [_header, payload, _signature] <- String.split(access_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- decode_map(json),
         %{"chatgpt_account_id" => id} when is_binary(id) and id != "" <-
           Map.get(claims, "https://api.openai.com/auth") do
      {:ok, id}
    else
      _ -> {:error, :invalid_access_token}
    end
  end

  defp do_poll(device_auth_id, user_code, http, sleep, now_ms, interval_ms, deadline) do
    if now_ms.() >= deadline do
      {:error, :device_code_expired}
    else
      result =
        http.(@device_token_url,
          json: %{"device_auth_id" => device_auth_id, "user_code" => user_code},
          decode_body: false,
          retry: false
        )

      case poll_result(result) do
        {:ok, code, verifier} ->
          exchange_code(http, code, verifier)

        :pending ->
          sleep.(interval_ms)
          do_poll(device_auth_id, user_code, http, sleep, now_ms, interval_ms, deadline)

        :slow_down ->
          interval_ms = interval_ms + 5_000
          sleep.(interval_ms)
          do_poll(device_auth_id, user_code, http, sleep, now_ms, interval_ms, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp poll_result({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, map} <- decode_map(body),
         code when is_binary(code) and code != "" <- Map.get(map, "authorization_code"),
         verifier when is_binary(verifier) and verifier != "" <- Map.get(map, "code_verifier") do
      {:ok, code, verifier}
    else
      _ -> {:error, :invalid_device_token_response}
    end
  end

  defp poll_result({:ok, %Req.Response{status: status}}) when status in [403, 404],
    do: :pending

  defp poll_result({:ok, %Req.Response{status: status, body: body}}) do
    case error_code(body) do
      "deviceauth_authorization_pending" -> :pending
      "slow_down" -> :slow_down
      _ -> {:error, {:device_token_http, status, body_snippet(body)}}
    end
  end

  defp poll_result({:error, error}), do: {:error, error}

  defp exchange_code(http, code, verifier) do
    with {:ok, map} <-
           post_form(http, %{
             "grant_type" => "authorization_code",
             "client_id" => @client_id,
             "code" => code,
             "code_verifier" => verifier,
             "redirect_uri" => @redirect_url
           }) do
      tokens_from_response(map)
    end
  end

  defp post_form(http, form) do
    case http.(@token_url,
           form: form,
           headers: @form_headers,
           decode_body: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_map(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:token_http, status, body_snippet(body)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp tokens_from_response(%{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "expires_in" => expires_in
       })
       when is_binary(access_token) and access_token != "" and is_binary(refresh_token) and
              refresh_token != "" and is_integer(expires_in) and expires_in > 0 do
    with {:ok, account_id} <- account_id(access_token) do
      {:ok,
       %__MODULE__{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at: System.system_time(:second) + expires_in,
         account_id: account_id
       }}
    end
  end

  defp tokens_from_response(_response), do: {:error, :invalid_token_response}

  defp tokens_from_saved_map(%{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "expires_at" => expires_at,
         "account_id" => account_id
       })
       when is_binary(access_token) and access_token != "" and is_binary(refresh_token) and
              refresh_token != "" and is_integer(expires_at) and is_binary(account_id) and
              account_id != "" do
    {:ok,
     %__MODULE__{
       access_token: access_token,
       refresh_token: refresh_token,
       expires_at: expires_at,
       account_id: account_id
     }}
  end

  defp tokens_from_saved_map(_map), do: {:error, :invalid_auth_file}

  defp refresh_latest(tokens) do
    case load_tokens() do
      {:ok, latest} ->
        if expired?(latest, System.system_time(:second)), do: refresh(latest), else: {:ok, latest}

      {:error, :not_logged_in} ->
        refresh(tokens)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_interval(interval) when is_integer(interval) and interval > 0,
    do: {:ok, max(interval, 1) * 1_000}

  defp poll_interval(interval) when is_binary(interval) do
    case Integer.parse(interval) do
      {number, ""} when number > 0 -> {:ok, max(number, 1) * 1_000}
      _ -> {:error, :invalid_interval}
    end
  end

  defp poll_interval(_interval), do: {:error, :invalid_interval}

  defp error_code(body) do
    with {:ok, map} <- decode_map(body) do
      case Map.get(map, "error") do
        %{"code" => code} when is_binary(code) -> code
        error when is_binary(error) -> error
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp decode_map(map) when is_map(map), do: {:ok, map}

  defp decode_map(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_map(_body), do: {:error, :invalid_json}

  defp body_snippet(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_snippet(body), do: body |> inspect() |> String.slice(0, 500)
end
