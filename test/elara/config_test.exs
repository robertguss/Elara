defmodule Elara.ConfigTest do
  use ExUnit.Case, async: true

  alias Elara.Config
  alias Elara.Provider.OpenAI

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
end
