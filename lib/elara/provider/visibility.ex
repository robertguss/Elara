defmodule Elara.Provider.Visibility do
  @moduledoc "Public subscription capability and telemetry boundary; never accepts native reasoning."

  @typedoc "Public part: kind, item_id, output_index, part_index and cumulative text only."
  @type public_part :: %{String.t() => String.t() | non_neg_integer()}
  @type settings :: %{String.t() => String.t()}
  @type usage :: %{String.t() => non_neg_integer()}

  @catalog_version "subscription-preflight-2026-09-04"
  def catalog do
    Enum.map(["gpt-5.5", "gpt-5.4-mini"], fn model ->
      %{
        "model" => model,
        "efforts" => ["low", "medium", "high", "xhigh"],
        "tested_efforts" => if(model == "gpt-5.5", do: ["low", "high"], else: ["low"]),
        "context_window" => 272_000,
        "provenance" => @catalog_version
      }
    end)
  end

  def validate(%{"model" => model, "effort" => effort} = settings) when map_size(settings) == 2 do
    if Enum.any?(catalog(), &(&1["model"] == model and effort in &1["efforts"])),
      do: :ok,
      else: {:error, :unsupported_provider_settings}
  end

  def validate(_), do: {:error, :unsupported_provider_settings}

  def settings({Elara.Provider.OpenAICodex, config}),
    do: %{"model" => config.model, "effort" => config.effort}

  def settings(_), do: nil

  def configure({Elara.Provider.OpenAICodex, config}, %{"model" => model, "effort" => effort}),
    do: {Elara.Provider.OpenAICodex, %{config | model: model, effort: effort}}

  def configure(provider, _), do: provider

  def valid_part?(
        %{
          "kind" => kind,
          "item_id" => id,
          "output_index" => output,
          "part_index" => part,
          "text" => text
        } = value
      ) do
    map_size(value) == 5 and kind in ["reasoning_summary", "commentary", "final_answer"] and
      is_binary(id) and is_integer(output) and output >= 0 and is_integer(part) and part >= 0 and
      is_binary(text)
  end

  def valid_part?(_), do: false

  def view(core) do
    settings = core.config.provider_settings
    catalog = if settings, do: catalog(), else: []
    selected = settings && Enum.find(catalog, &(&1["model"] == settings["model"]))

    last =
      core.history
      |> Enum.reverse()
      |> Enum.find(&is_struct(&1, Elara.Message.Assistant))

    estimate =
      4096 + byte_size(core.config.system) +
        (core.history
         |> Enum.map(&Elara.Session.Store.encode_message/1)
         |> JSON.encode!()
         |> byte_size()) +
        (core.config.tools
         |> Map.values()
         |> Enum.map(&Map.take(&1, [:name, :description, :parameters]))
         |> JSON.encode!()
         |> byte_size())

    %{
      "extension" => "provider_visibility_v1",
      "catalog" => catalog,
      "next_request" => settings,
      "active_request" => if(core.streaming, do: core.streaming.settings, else: nil),
      "usage" => %{
        "last_request" => if(last, do: last.usage, else: nil),
        "session_totals" => totals(core.history)
      },
      "context" => %{
        "advertised_limit" => if(selected, do: selected["context_window"], else: nil),
        "occupancy" => nil,
        "estimate_tokens" => estimate,
        "estimate_basis" =>
          "UTF-8 serialized history, system and tool schemas plus 4096 framing reserve; conservative byte estimate, not exact provider request or tokenizer occupancy"
      },
      "streaming" =>
        if(core.streaming, do: Map.take(core.streaming, [:id, :public_content]), else: nil)
    }
  end

  def key(part), do: {part["output_index"], part["part_index"], part["kind"]}

  def upsert(parts, part) do
    (Enum.reject(parts, &(key(&1) == key(part))) ++
       [Map.take(part, ["kind", "item_id", "output_index", "part_index", "text"])])
    |> Enum.sort_by(&key/1)
  end

  def usage(nil), do: nil

  def usage(value) when is_map(value) do
    value
    |> Map.take(["input_tokens", "output_tokens", "total_tokens"])
    |> Map.put("cached_input_tokens", get_in(value, ["input_tokens_details", "cached_tokens"]))
    |> Map.put(
      "cache_write_tokens",
      get_in(value, ["input_tokens_details", "cache_write_tokens"])
    )
    |> Map.put("reasoning_tokens", get_in(value, ["output_tokens_details", "reasoning_tokens"]))
    |> Enum.filter(fn {_key, n} -> is_integer(n) and n >= 0 end)
    |> Map.new()
  end

  def totals(history) do
    Enum.reduce(history, %{}, fn
      %Elara.Message.Assistant{usage: usage}, totals when is_map(usage) ->
        Map.merge(totals, usage, fn _key, a, b -> a + b end)

      _, totals ->
        totals
    end)
  end
end
