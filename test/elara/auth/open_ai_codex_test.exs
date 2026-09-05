defmodule Elara.Auth.OpenAICodexTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Elara.Auth.OpenAICodex

  setup do
    previous = Application.get_env(:elara, :openai_codex_auth_path)
    root = Path.join(System.tmp_dir!(), "elara-openai-auth-#{System.unique_integer([:positive])}")
    path = Path.join(root, "auth.json")
    Application.put_env(:elara, :openai_codex_auth_path, path)

    on_exit(fn ->
      if previous do
        Application.put_env(:elara, :openai_codex_auth_path, previous)
      else
        Application.delete_env(:elara, :openai_codex_auth_path)
      end

      File.rm_rf!(root)
    end)

    {:ok, path: path}
  end

  test "device login polls pending authorization and exchanges the code" do
    access_token = access_token("account-123")

    http = fn
      "https://auth.openai.com/api/accounts/deviceauth/usercode", opts ->
        assert opts[:json] == %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"}

        response(%{
          "device_auth_id" => "device-1",
          "user_code" => "ABCD-1234",
          "interval" => "1"
        })

      "https://auth.openai.com/api/accounts/deviceauth/token", opts ->
        assert opts[:json] == %{"device_auth_id" => "device-1", "user_code" => "ABCD-1234"}

        if Process.get(:openai_polled) do
          response(%{
            "authorization_code" => "authorization-1",
            "code_verifier" => "verifier-1"
          })
        else
          Process.put(:openai_polled, true)

          {:ok,
           %Req.Response{
             status: 403,
             body:
               JSON.encode!(%{
                 "error" => %{"code" => "deviceauth_authorization_pending"}
               })
           }}
        end

      "https://auth.openai.com/oauth/token", opts ->
        assert opts[:form] == %{
                 "grant_type" => "authorization_code",
                 "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
                 "code" => "authorization-1",
                 "code_verifier" => "verifier-1",
                 "redirect_uri" => "https://auth.openai.com/deviceauth/callback"
               }

        response(%{
          "access_token" => access_token,
          "refresh_token" => "refresh-1",
          "expires_in" => 3_600
        })
    end

    assert {:ok,
            %{
              "device_auth_id" => "device-1",
              "user_code" => "ABCD-1234",
              "interval_ms" => 1_000
            }} = OpenAICodex.request_device_code(http: http)

    assert {:ok, %OpenAICodex{account_id: "account-123", refresh_token: "refresh-1"}} =
             OpenAICodex.poll_token("device-1", "ABCD-1234",
               http: http,
               sleep: fn 1_000 -> :ok end,
               interval_ms: 1_000
             )
  end

  test "credentials persist privately and refresh with a rotated token", %{path: path} do
    current = %OpenAICodex{
      access_token: access_token("old-account"),
      refresh_token: "old-refresh",
      expires_at: 1,
      account_id: "old-account"
    }

    assert :ok = OpenAICodex.save_tokens(current)
    assert {:ok, ^current} = OpenAICodex.load_tokens()
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700

    http = fn "https://auth.openai.com/oauth/token", opts ->
      assert opts[:form] == %{
               "grant_type" => "refresh_token",
               "refresh_token" => "old-refresh",
               "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"
             }

      response(%{
        "access_token" => access_token("new-account"),
        "refresh_token" => "new-refresh",
        "expires_in" => 3_600
      })
    end

    assert {:ok, %OpenAICodex{account_id: "new-account", refresh_token: "new-refresh"} = fresh} =
             OpenAICodex.refresh(current, http: http)

    assert {:ok, ^fresh} = OpenAICodex.load_tokens()
  end

  test "refresh_if_needed reuses a fresh token saved by another caller" do
    expired = %OpenAICodex{
      access_token: access_token("old-account"),
      refresh_token: "old-refresh",
      expires_at: 1,
      account_id: "old-account"
    }

    fresh = %OpenAICodex{
      access_token: access_token("fresh-account"),
      refresh_token: "fresh-refresh",
      expires_at: System.system_time(:second) + 3_600,
      account_id: "fresh-account"
    }

    assert :ok = OpenAICodex.save_tokens(fresh)
    assert {:ok, ^fresh} = OpenAICodex.refresh_if_needed(expired)
  end

  test "JWT account extraction and inspect fail closed without exposing credentials" do
    token = access_token("account-123")
    assert {:ok, "account-123"} = OpenAICodex.account_id(token)
    assert {:error, :invalid_access_token} = OpenAICodex.account_id("not-a-jwt")

    inspected =
      inspect(%OpenAICodex{
        access_token: "secret-access",
        refresh_token: "secret-refresh",
        expires_at: 1,
        account_id: "account"
      })

    refute inspected =~ "secret-access"
    refute inspected =~ "secret-refresh"
  end

  test "explicit Codex reuse reads JWT expiry and cannot persist or refresh", %{path: path} do
    codex_home = Path.join(Path.dirname(path), "codex")
    File.mkdir_p!(codex_home)
    codex_path = Path.join(codex_home, "auth.json")
    expiry = System.system_time(:second) + 3_600
    payload = Base.url_encode64(JSON.encode!(%{"exp" => expiry}), padding: false)

    body =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => "header.#{payload}.signature",
          "refresh_token" => "fake-codex-refresh",
          "account_id" => "fake-account"
        }
      })

    File.write!(codex_path, body)
    env = %{"CODEX_HOME" => codex_home}

    assert {:error, :not_logged_in} = OpenAICodex.load_tokens()
    assert {:ok, tokens} = OpenAICodex.load_tokens(:codex, env)
    assert tokens.source == :codex
    assert tokens.expires_at == expiry
    assert tokens.refresh_token == nil
    assert {:ok, ^tokens} = OpenAICodex.refresh_if_needed(tokens)
    assert {:error, :codex_auth_read_only} = OpenAICodex.save_tokens(tokens)

    assert {:error, :codex_login_refresh_required} =
             OpenAICodex.refresh(tokens,
               http: fn _, _ -> flunk("must not refresh Codex credentials") end
             )

    assert {:error, :codex_login_refresh_required} =
             OpenAICodex.refresh_if_needed(%{
               tokens
               | expires_at: System.system_time(:second) + 60
             })

    assert File.read!(codex_path) == body
    refute File.exists?(path)
  end

  test "Codex reuse rejects missing, malformed, incomplete and expired credentials", %{path: path} do
    codex_home = Path.join(Path.dirname(path), "codex")
    File.mkdir_p!(codex_home)
    codex_path = Path.join(codex_home, "auth.json")
    env = %{"CODEX_HOME" => codex_home}
    assert {:error, :codex_not_logged_in} = OpenAICodex.load_tokens(:codex, env)

    for body <- [
          "invalid",
          "{}",
          ~s({"tokens":{}}),
          ~s({"tokens":{"access_token":"bad","account_id":"account"}})
        ] do
      File.write!(codex_path, body)
      assert {:error, :invalid_codex_auth_file} = OpenAICodex.load_tokens(:codex, env)
    end

    for claims <- [%{}, %{"exp" => "123"}, %{"exp" => nil}, %{"exp" => -1}] do
      payload = Base.url_encode64(JSON.encode!(claims), padding: false)

      File.write!(
        codex_path,
        JSON.encode!(%{"tokens" => %{"access_token" => "h.#{payload}.s", "account_id" => "fake"}})
      )

      assert {:error, :invalid_codex_auth_file} = OpenAICodex.load_tokens(:codex, env)
    end

    for expiry <- [1, System.system_time(:second) + 60] do
      payload = Base.url_encode64(JSON.encode!(%{"exp" => expiry}), padding: false)

      File.write!(
        codex_path,
        JSON.encode!(%{"tokens" => %{"access_token" => "h.#{payload}.s", "account_id" => "fake"}})
      )

      assert {:error, :codex_login_refresh_required} = OpenAICodex.load_tokens(:codex, env)
    end

    refute File.exists?(path)
  end

  defp access_token(account_id) do
    payload =
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    "header.#{payload}.signature"
  end

  defp response(body),
    do: {:ok, %Req.Response{status: 200, body: JSON.encode!(body)}}
end
