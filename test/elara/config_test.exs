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

    {:ok, root: root}
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

  test "Codex config defaults to gpt-5.5 and low effort" do
    assert :ok =
             OpenAICodexAuth.save_tokens(%OpenAICodexAuth{
               access_token: "fake",
               refresh_token: "fake",
               account_id: "fake",
               expires_at: System.system_time(:second) + 3600
             })

    assert {:ok, {OpenAICodex, config}} = Config.resolve(%{"ELARA_PROVIDER" => "openai-codex"})
    assert config.model == "gpt-5.5"
    assert config.effort == "low"

    assert {:ok, {OpenAICodex, custom}} =
             Config.resolve(%{
               "ELARA_PROVIDER" => "openai-codex",
               "ELARA_REASONING_EFFORT" => "high"
             })

    assert custom.effort == "high"
  end

  test "Codex credential source is explicit and invalid settings fail closed", %{root: root} do
    env = %{"ELARA_PROVIDER" => "openai-codex", "CODEX_HOME" => Path.join(root, "codex")}
    assert {:error, :not_logged_in} = Config.resolve(env)

    assert {:error, :codex_not_logged_in} =
             Config.resolve(Map.put(env, "ELARA_CODEX_AUTH_SOURCE", "codex"))

    assert {:error, {:unknown_codex_auth_source, "other"}} =
             Config.resolve(Map.put(env, "ELARA_CODEX_AUTH_SOURCE", "other"))

    assert {:error, {:invalid_reasoning_effort, "bogus"}} =
             Config.resolve(Map.put(env, "ELARA_REASONING_EFFORT", "bogus"))

    assert {:ok, {OpenAI, %OpenAI{api_key: "fake"}}} =
             Config.resolve(%{"ELARA_CODEX_AUTH_SOURCE" => "codex", "ELARA_API_KEY" => "fake"})
  end

  test "explicit Codex source resolves fake Codex schema without replacing owned credentials", %{
    root: root
  } do
    owned = %OpenAICodexAuth{
      access_token: "owned-fake",
      refresh_token: "owned-refresh",
      account_id: "owned-account",
      expires_at: System.system_time(:second) + 3600
    }

    assert :ok = OpenAICodexAuth.save_tokens(owned)
    owned_body = File.read!(OpenAICodexAuth.auth_path())
    codex_home = Path.join(root, "codex")
    File.mkdir_p!(codex_home)

    payload =
      Base.url_encode64(JSON.encode!(%{"exp" => System.system_time(:second) + 3600}),
        padding: false
      )

    codex_body =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => "h.#{payload}.s",
          "account_id" => "codex-account",
          "refresh_token" => "unused-fake",
          "id_token" => "unused-fake-id"
        }
      })

    File.write!(Path.join(codex_home, "auth.json"), codex_body)
    env = %{"ELARA_PROVIDER" => "openai-codex", "CODEX_HOME" => codex_home}
    assert {:ok, {OpenAICodex, %{tokens: ^owned}}} = Config.resolve(env)

    assert {:ok,
            {OpenAICodex, %{tokens: %{source: :codex, account_id: "codex-account"} = tokens}}} =
             Config.resolve(Map.put(env, "ELARA_CODEX_AUTH_SOURCE", "codex"))

    assert {:error, :codex_auth_read_only} = OpenAICodexAuth.save_tokens(tokens)

    assert {:error, :codex_login_refresh_required} =
             OpenAICodexAuth.refresh_if_needed(%{tokens | expires_at: 1})

    assert File.read!(OpenAICodexAuth.auth_path()) == owned_body
    assert File.read!(Path.join(codex_home, "auth.json")) == codex_body
  end

  test "unknown explicit provider fails closed" do
    assert {:error, {:unknown_provider, "other"}} =
             Config.resolve(%{"ELARA_PROVIDER" => "other"})
  end
end
