defmodule Harness.Auth do
  @moduledoc "Grok OAuth device-code login and token persistence."

  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scope "openid profile email offline_access grok-cli:access api:access"
  @device_code_url "https://auth.x.ai/oauth2/device/code"
  @token_url "https://auth.x.ai/oauth2/token"
  @auth_dir_name ".harness"
  @auth_file_name "auth.json"
  @grok_auth_rel ".grok/auth.json"

  @derive {Inspect, except: [:access_token, :refresh_token]}
  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :token_type
  ]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: integer() | nil,
          token_type: String.t() | nil
        }

  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @spec auth_path() :: String.t()
  def auth_path do
    Path.join([System.user_home!(), @auth_dir_name, @auth_file_name])
  end

  @spec load_tokens() :: {:ok, t()} | {:error, term()}
  def load_tokens do
    path = auth_path()

    case read_auth_file(path) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, :enoent} ->
        import_grok_if_present()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec save_tokens(t()) :: :ok | {:error, term()}
  def save_tokens(%__MODULE__{} = tokens) do
    path = auth_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    payload =
      JSON.encode!(%{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token,
        "expires_at" => tokens.expires_at,
        "token_type" => tokens.token_type
      })

    tmp = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp, payload),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "RFC 8628 device authorization request."
  @spec request_device_code(keyword()) :: {:ok, map()} | {:error, term()}
  def request_device_code(opts \\ []) do
    http = Keyword.get(opts, :http, &Req.post/2)

    body = %{
      "client_id" => @client_id,
      "scope" => @scope
    }

    case http.(@device_code_url,
           form: body,
           decode_body: false,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: raw}} ->
        case JSON.decode(raw) do
          {:ok, map} when is_map(map) -> {:ok, map}
          other -> {:error, {:bad_device_code, other}}
        end

      {:ok, %Req.Response{status: status, body: raw}} ->
        {:error, {:device_code_http, status, raw}}

      {:error, err} ->
        {:error, err}
    end
  end

  @doc "Poll the token endpoint until authorized, denied, or expired."
  @spec poll_token(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def poll_token(device_code, opts \\ []) when is_binary(device_code) do
    http = Keyword.get(opts, :http, &Req.post/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    interval_ms = Keyword.get(opts, :interval_ms, 5_000)
    now_ms = Keyword.get(opts, :now_ms, &System.system_time/1)
    expires_at = Keyword.get(opts, :expires_at_ms, now_ms.(:millisecond) + 15 * 60 * 1000)

    do_poll(device_code, http, sleep, interval_ms, now_ms, expires_at)
  end

  @spec refresh(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def refresh(tokens, opts \\ [])

  def refresh(%__MODULE__{refresh_token: nil}, _opts), do: {:error, :missing_refresh_token}

  def refresh(%__MODULE__{refresh_token: refresh_token} = _tokens, opts) do
    http = Keyword.get(opts, :http, &Req.post/2)
    now_s = Keyword.get(opts, :now_s, fn -> System.system_time(:second) end)

    body = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => refresh_token
    }

    case http.(@token_url,
           form: body,
           decode_body: false,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: raw}} ->
        with {:ok, map} <- JSON.decode(raw),
             {:ok, tokens} <- tokens_from_response(map, now_s.()) do
          # xAI rotates refresh tokens; persist the new pair or login dies.
          case save_tokens(tokens) do
            :ok -> {:ok, tokens}
            {:error, reason} -> {:error, {:persist_failed, reason}}
          end
        end

      {:ok, %Req.Response{status: status, body: raw}} ->
        {:error, {:refresh_http, status, raw}}

      {:error, err} ->
        {:error, err}
    end
  end

  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now) when is_integer(now),
    do: now >= expires_at - 60

  defp do_poll(device_code, http, sleep, interval_ms, now_ms, expires_at) do
    if now_ms.(:millisecond) >= expires_at do
      {:error, :device_code_expired}
    else
      body = %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => device_code,
        "client_id" => @client_id
      }

      case http.(@token_url,
             form: body,
             decode_body: false,
             headers: [{"content-type", "application/x-www-form-urlencoded"}]
           ) do
        {:ok, %Req.Response{status: 200, body: raw}} ->
          with {:ok, map} <- JSON.decode(raw),
               {:ok, tokens} <- tokens_from_response(map, System.system_time(:second)) do
            {:ok, tokens}
          end

        {:ok, %Req.Response{status: status, body: raw}} when status in [400, 401, 403] ->
          case JSON.decode(raw) do
            {:ok, %{"error" => "authorization_pending"}} ->
              sleep.(interval_ms)
              do_poll(device_code, http, sleep, interval_ms, now_ms, expires_at)

            {:ok, %{"error" => "slow_down"}} ->
              sleep.(interval_ms * 2)
              do_poll(device_code, http, sleep, interval_ms, now_ms, expires_at)

            {:ok, %{"error" => "expired_token"}} ->
              {:error, :device_code_expired}

            {:ok, %{"error" => "access_denied"}} ->
              {:error, :access_denied}

            {:ok, map} ->
              {:error, {:token_error, map}}

            _ ->
              {:error, {:token_http, status, raw}}
          end

        {:ok, %Req.Response{status: status, body: raw}} ->
          {:error, {:token_http, status, raw}}

        {:error, err} ->
          {:error, err}
      end
    end
  end

  defp tokens_from_response(map, now_s) when is_map(map) do
    access = Map.get(map, "access_token")
    refresh = Map.get(map, "refresh_token")
    expires_in = Map.get(map, "expires_in")
    token_type = Map.get(map, "token_type")

    if is_binary(access) do
      expires_at =
        cond do
          is_integer(expires_in) -> now_s + expires_in
          is_binary(expires_in) -> now_s + String.to_integer(expires_in)
          true -> nil
        end

      {:ok,
       %__MODULE__{
         access_token: access,
         refresh_token: refresh,
         expires_at: expires_at,
         token_type: token_type
       }}
    else
      {:error, {:missing_access_token, map}}
    end
  end

  defp import_grok_if_present do
    grok_path = Path.join(System.user_home!(), @grok_auth_rel)

    case read_auth_file(grok_path) do
      {:ok, tokens} ->
        case save_tokens(tokens) do
          :ok -> {:ok, tokens}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :not_logged_in}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_auth_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, map} when is_map(map) ->
            access = Map.get(map, "access_token") || Map.get(map, "accessToken")
            refresh = Map.get(map, "refresh_token") || Map.get(map, "refreshToken")
            expires_at = Map.get(map, "expires_at") || Map.get(map, "expiresAt")
            token_type = Map.get(map, "token_type") || Map.get(map, "tokenType")

            if is_binary(access) do
              {:ok,
               %__MODULE__{
                 access_token: access,
                 refresh_token: refresh,
                 expires_at: expires_at,
                 token_type: token_type
               }}
            else
              {:error, :invalid_auth_file}
            end

          _ ->
            {:error, :invalid_auth_file}
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
