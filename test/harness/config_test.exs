defmodule Harness.ConfigTest do
  use ExUnit.Case, async: true

  alias Harness.Config
  alias Harness.Provider.OpenAI

  test "from_env requires key and model together" do
    assert {:error, {:missing_env, ["HARNESS_API_KEY", "HARNESS_MODEL"]}} = Config.from_env(%{})

    assert {:error, {:missing_env, ["HARNESS_MODEL"]}} =
             Config.from_env(%{"HARNESS_API_KEY" => "k"})
  end

  test "from_env defaults base url" do
    assert {:ok, %OpenAI{api_key: "k", model: "m", base_url: "https://api.openai.com/v1"}} =
             Config.from_env(%{"HARNESS_API_KEY" => "k", "HARNESS_MODEL" => "m"})
  end

  test "from_env honors base url override" do
    assert {:ok, %OpenAI{base_url: "http://localhost:11434/v1"}} =
             Config.from_env(%{
               "HARNESS_API_KEY" => "k",
               "HARNESS_MODEL" => "m",
               "HARNESS_BASE_URL" => "http://localhost:11434/v1"
             })
  end

  test "resolve prefers HARNESS_API_KEY" do
    assert {:ok,
            {OpenAI, %OpenAI{api_key: "k", model: "grok-4", base_url: "https://api.x.ai/v1"}}} =
             Config.resolve(%{"HARNESS_API_KEY" => "k"})
  end
end
