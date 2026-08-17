defmodule Harness.Provider.GrokTest do
  use ExUnit.Case, async: true

  alias Harness.Auth
  alias Harness.Provider.Error
  alias Harness.Provider.Grok

  test "new stores tokens without closures" do
    tokens = %Auth{access_token: "a", refresh_token: "r", expires_at: 1}
    config = Grok.new(tokens)
    assert config.tokens == tokens
    refute Map.has_key?(config, :now_s)
    refute Map.has_key?(config, :refresh)
  end

  test "classify_error remaps HTTP 403 to entitlement" do
    err = %Error{kind: :http, status: 403, message: "403 nope"}
    classified = Grok.classify_error(err)
    assert classified.kind == :entitlement
    assert classified.message =~ "XAI_API_KEY"
    assert classified.message =~ "Re-login will not help"
  end

  test "classify_error leaves other errors alone" do
    err = %Error{kind: :http, status: 500, message: "500 oops"}
    assert Grok.classify_error(err) == err
  end
end
