defmodule Harness.AuthTest do
  use ExUnit.Case, async: true

  alias Harness.Auth

  test "inspect redacts credential fields" do
    tokens = %Auth{
      access_token: "secret-access",
      refresh_token: "secret-refresh",
      expires_at: 1,
      token_type: "Bearer"
    }

    inspected = inspect(tokens)
    refute inspected =~ "secret-access"
    refute inspected =~ "secret-refresh"
    assert inspected =~ "#Harness.Auth<"
  end

  test "request_device_code and poll_token with injected http" do
    http = fn
      "https://auth.x.ai/oauth2/device/code", _opts ->
        body =
          JSON.encode!(%{
            "device_code" => "dev",
            "user_code" => "ABCD",
            "verification_uri" => "https://example.test/verify",
            "interval" => 1
          })

        {:ok, %Req.Response{status: 200, body: body}}

      "https://auth.x.ai/oauth2/token", opts ->
        form = Keyword.fetch!(opts, :form)

        cond do
          form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" and
              Process.get(:authed) != true ->
            Process.put(:authed, true)

            {:ok,
             %Req.Response{status: 400, body: JSON.encode!(%{"error" => "authorization_pending"})}}

          true ->
            body =
              JSON.encode!(%{
                "access_token" => "a",
                "refresh_token" => "r",
                "expires_in" => 3600,
                "token_type" => "Bearer"
              })

            {:ok, %Req.Response{status: 200, body: body}}
        end
    end

    assert {:ok, %{"user_code" => "ABCD", "device_code" => "dev"}} =
             Auth.request_device_code(http: http)

    assert {:ok, %Auth{access_token: "a", refresh_token: "r"}} =
             Auth.poll_token("dev", http: http, sleep: fn _ -> :ok end, interval_ms: 1)
  end

  test "expired?/2 uses a 60s skew" do
    tokens = %Auth{access_token: "a", refresh_token: "r", expires_at: 1_000}
    assert Auth.expired?(tokens, 950)
    refute Auth.expired?(tokens, 900)
  end
end
