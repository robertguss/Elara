defmodule Elara.Provider.Visibility do
  @moduledoc "Public subscription capability and telemetry boundary; never accepts native reasoning."

  @typedoc "Public part: kind, item_id, output_index, part_index and cumulative text only."
  @type public_part :: %{String.t() => String.t() | non_neg_integer()}
  @type settings :: %{String.t() => String.t()}
  @type usage :: %{String.t() => non_neg_integer()}

  alias Elara.Provider.{Catalog, Grok, OpenAI, OpenAICodex}

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

  @spec context_window(term()) :: {:ok, pos_integer()} | :unknown
  def context_window({%{"model" => model}, %{"models" => models}}) do
    case Enum.find(models, &(&1["model"] == model)) do
      %{"context_window" => tokens} when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _ -> :unknown
    end
  end

  def context_window({settings, nil}) when is_map(settings), do: context_window(settings)
  def context_window({_, %{model: model}}), do: context_window(model)
  def context_window(%{"model" => model}), do: context_window(model)

  def context_window(model) when is_binary(model) do
    case Enum.find(catalog(), &(&1["model"] == model)) do
      %{"context_window" => tokens} -> {:ok, tokens}
      nil -> :unknown
    end
  end

  def context_window(_), do: :unknown

  def validate(%{"model" => model, "effort" => effort} = settings) when map_size(settings) == 2 do
    if Enum.any?(catalog(), &(&1["model"] == model and effort in &1["efforts"])),
      do: :ok,
      else: {:error, :unsupported_provider_settings}
  end

  def validate(_), do: {:error, :unsupported_provider_settings}

  def validate(settings, nil), do: validate(settings)

  def validate(%{"model" => model} = settings, %{"kind" => "grok"}) do
    if map_size(settings) == 1 and Catalog.valid_id?(model),
      do: :ok,
      else: {:error, :unsupported_provider_settings}
  end

  def validate(%{"model" => model, "effort" => effort} = settings, %{
        "kind" => "codex",
        "models" => models
      }) do
    if map_size(settings) == 2 and
         Enum.any?(models, &(&1["model"] == model and effort in &1["efforts"])),
       do: :ok,
       else: {:error, :unsupported_provider_settings}
  end

  def validate(_, _), do: {:error, :unsupported_provider_settings}

  def normalize(%{"model" => model} = settings, %{"kind" => "codex", "models" => models})
      when map_size(settings) == 1 do
    case Enum.find(models, &(&1["model"] == model)) do
      %{"efforts" => [first | _]} = row ->
        Map.put(settings, "effort", row["default_effort"] || first)

      _ ->
        settings
    end
  end

  def normalize(settings, _), do: settings

  def settings({OpenAICodex, config}),
    do: %{"model" => config.model, "effort" => config.effort}

  def settings({Grok, config}), do: %{"model" => config.model}

  def settings({OpenAI, config}) do
    if URI.parse(config.base_url).host == "api.x.ai", do: %{"model" => config.model}, else: nil
  end

  def settings(_), do: nil

  def configure({OpenAICodex, config}, %{"model" => model, "effort" => effort}),
    do: {OpenAICodex, %{config | model: model, effort: effort}}

  def configure({Grok, config}, %{"model" => model}), do: {Grok, %{config | model: model}}
  def configure({OpenAI, config}, %{"model" => model}), do: {OpenAI, %{config | model: model}}
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

  def view(core, estimated_tokens \\ nil) do
    settings = core.config.provider_settings
    snapshot = core.config.provider_catalog
    catalog = if snapshot, do: snapshot["models"], else: if(settings, do: catalog(), else: [])

    catalog =
      if settings && snapshot && not Enum.any?(catalog, &(&1["model"] == settings["model"])) do
        catalog ++
          [
            %{
              "model" => settings["model"],
              "efforts" => [],
              "context_window" => nil,
              "provenance" => "unverified"
            }
          ]
      else
        catalog
      end

    budget = Elara.Session.Context.budget(core, nil, nil, estimated_tokens)

    last =
      core.history
      |> Enum.reverse()
      |> Enum.find(fn
        %Elara.Message.Assistant{} -> true
        %Elara.Message.ToolResult{usage: usage} -> is_map(usage)
        _ -> false
      end)

    images? =
      Enum.any?(core.history, fn
        %Elara.Message.User{attachments: attachments} ->
          Enum.any?(attachments, &(&1["kind"] == "image"))

        _ ->
          false
      end)

    # Image token cost depends on provider preprocessing, not encoded blob size.
    # Do not serialize image-bearing history on each streaming patch.
    estimate = if images?, do: nil, else: budget["estimate_tokens"]

    %{
      "extension" => "provider_visibility_v1",
      "catalog" => catalog,
      "catalog_source" => snapshot && snapshot["source"],
      "catalog_error" => snapshot && snapshot["error"],
      "settings_notice" => snapshot && snapshot["settings_notice"],
      "next_request" => settings,
      "active_request" => if(core.streaming, do: core.streaming.settings, else: nil),
      "usage" => %{
        "last_request" => if(last, do: last.usage, else: nil),
        "session_totals" => totals(core.history),
        "cost" => Elara.Provider.Billing.summary(core.history)
      },
      "context" => %{
        "advertised_limit" => budget["advertised_limit"],
        "occupancy" => nil,
        "estimate_tokens" => estimate,
        "estimate_basis" =>
          if(images?,
            do: "Unknown: history contains images whose provider token cost is unavailable",
            else: budget["basis"]
          )
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
    input_details = value["input_tokens_details"] || value["prompt_tokens_details"]
    output_details = value["output_tokens_details"] || value["completion_tokens_details"]

    %{
      "input_tokens" => value["input_tokens"] || value["prompt_tokens"],
      "output_tokens" => value["output_tokens"] || value["completion_tokens"],
      "total_tokens" => value["total_tokens"],
      "cached_input_tokens" => detail(input_details, "cached_tokens"),
      "cache_write_tokens" => detail(input_details, "cache_write_tokens"),
      "reasoning_tokens" => detail(output_details, "reasoning_tokens")
    }
    |> Enum.filter(fn {_key, n} -> is_integer(n) and n >= 0 end)
    |> Map.new()
    |> then(fn fields -> if map_size(fields) == 0, do: nil, else: fields end)
  end

  def usage(_), do: nil
  defp detail(details, key) when is_map(details), do: Map.get(details, key)
  defp detail(_, _), do: nil

  def totals(history) do
    Enum.reduce(history, %{}, fn
      %{__struct__: type, usage: usage}, totals
      when type in [Elara.Message.Assistant, Elara.Message.ToolResult] and is_map(usage) ->
        Map.merge(totals, usage, fn _key, a, b -> a + b end)

      _, totals ->
        totals
    end)
  end

  def valid_usage?(nil), do: true

  def valid_usage?(usage) when is_map(usage) do
    Enum.all?(usage, fn {key, value} ->
      key in ~w(input_tokens output_tokens total_tokens cached_input_tokens cache_write_tokens reasoning_tokens) and
        is_integer(value) and value >= 0
    end)
  end

  def valid_usage?(_), do: false
end
