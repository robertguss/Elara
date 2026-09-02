defmodule Elara.ConfigTest do
  use ExUnit.Case, async: false

  alias Elara.Auth.OpenAICodex, as: OpenAICodexAuth
  alias Elara.Config
  alias Elara.Provider.OpenAI
  alias Elara.Provider.OpenAICodex

  setup do
    previous = Application.get_env(:elara, :openai_codex_auth_path)
    root = Path.join(System.tmp_dir!(), "elara-config-#{System.unique_integer([:positive])}")
    Application.put_env(:elara, :openai_codex_auth_path, Path.join(root, "auth.json"))

    on_exit(fn ->
      if previous do
        Application.put_env(:elara, :openai_codex_auth_path, previous)
      else
        Application.delete_env(:elara, :openai_codex_auth_path)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "resolve prefers ELARA_API_KEY with xAI defaults" do
    assert {:ok,
            {OpenAI, %OpenAI{api_key: "k", model: "grok-4", base_url: "https://api.x.ai/v1"}}} =
             Config.resolve(%{"ELARA_API_KEY" => "k"})
  end

  test "resolve accepts XAI_API_KEY" do
    assert {:ok, {OpenAI, %OpenAI{api_key: "x"}}} = Config.resolve(%{"XAI_API_KEY" => "x"})
  end

  test "resolve honors model and base url overrides" do
    assert {:ok, {OpenAI, %OpenAI{model: "m", base_url: "http://localhost:11434/v1"}}} =
             Config.resolve(%{
               "ELARA_API_KEY" => "k",
               "ELARA_MODEL" => "m",
               "ELARA_BASE_URL" => "http://localhost:11434/v1"
             })
  end

  test "resolve prefers ELARA_API_KEY over XAI_API_KEY" do
    assert {:ok, {OpenAI, %OpenAI{api_key: "h"}}} =
             Config.resolve(%{"ELARA_API_KEY" => "h", "XAI_API_KEY" => "x"})
  end

  test "explicit openai-codex provider loads subscription credentials and model" do
    tokens = %OpenAICodexAuth{
      access_token: "access",
      refresh_token: "refresh",
      expires_at: System.system_time(:second) + 3_600,
      account_id: "account"
    }

    assert :ok = OpenAICodexAuth.save_tokens(tokens)

    assert {:ok, {OpenAICodex, %OpenAICodex{tokens: ^tokens, model: "custom"}}} =
             Config.resolve(%{
               "ELARA_PROVIDER" => "openai-codex",
               "ELARA_MODEL" => "custom",
               "ELARA_API_KEY" => "ignored"
             })
  end

  test "unknown explicit provider fails closed" do
    assert {:error, {:unknown_provider, "other"}} =
             Config.resolve(%{"ELARA_PROVIDER" => "other"})
  end
end
