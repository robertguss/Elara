defmodule Elara.Provider.Billing do
  @moduledoc "Immutable token-price provenance, not invoices or subscription spend."

  alias Elara.Message.{Assistant, ToolResult}

  @type receipt :: %{String.t() => term()}
  @version "standard-token-prices-2026-10-13"
  @openai "https://developers.openai.com/api/docs/models/gpt-4.1"
  @xai "https://docs.x.ai/developers/pricing"

  @spec source(String.t()) :: String.t()
  def source(base_url) do
    case URI.parse(base_url) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when path in ["/v1", "/v1/"] ->
        case host do
          "api.openai.com" -> "openai"
          "api.x.ai" -> "xai"
          _ -> "compatible"
        end

      _ ->
        "compatible"
    end
  end

  @spec stamp(Assistant.t(), String.t(), String.t() | nil) :: Assistant.t()
  def stamp(assistant, provider, tier \\ nil)

  def stamp(assistant, provider, _tier) when provider in ["openai_codex", "grok_oauth"] do
    %{assistant | billing_receipt: %{"kind" => "subscription", "provider" => provider}}
  end

  def stamp(assistant, provider, tier) when provider in ["openai", "xai", "compatible"] do
    price = if tier in [nil, "default", "standard"], do: price(provider, assistant)

    %{
      assistant
      | billing_receipt: %{
          "kind" => if(provider == "compatible", do: "unknown", else: "api"),
          "provider" => provider,
          "price" => price
        }
    }
  end

  defp price("openai", %Assistant{response_model: model})
       when model in ["gpt-4.1", "gpt-4.1-2025-04-14"] do
    rates(model, @openai, 2_000_000, 500_000, 8_000_000)
  end

  defp price("xai", %Assistant{response_model: model, usage: %{"input_tokens" => input}})
       when model in ["grok-4.6", "grok-4.7"] do
    multiplier = if input >= 200_000, do: 2, else: 1
    rates(model, @xai, 2_000_000 * multiplier, 500_000 * multiplier, 6_000_000 * multiplier)
  end

  defp price(_, _), do: nil

  defp rates(model, source, input, cached, output) do
    %{
      "model" => model,
      "source" => source,
      "version" => @version,
      "input_usd_micros_per_million" => input,
      "cached_input_usd_micros_per_million" => cached,
      "output_usd_micros_per_million" => output
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true

  def valid?(%{"kind" => "subscription", "provider" => provider} = receipt),
    do: map_size(receipt) == 2 and provider in ["openai_codex", "grok_oauth"]

  def valid?(%{"kind" => kind, "provider" => provider, "price" => price} = receipt) do
    map_size(receipt) == 3 and
      ((kind == "api" and provider in ["openai", "xai"]) or
         (kind == "unknown" and provider == "compatible" and is_nil(price))) and
      valid_price?(price)
  end

  def valid?(_), do: false
  defp valid_price?(nil), do: true

  defp valid_price?(price) when is_map(price) do
    map_size(price) == 6 and
      Enum.all?(~w(model source version), &(is_binary(price[&1]) and price[&1] != "")) and
      Enum.all?(
        ~w(input_usd_micros_per_million cached_input_usd_micros_per_million output_usd_micros_per_million),
        &(is_integer(price[&1]) and price[&1] >= 0)
      )
  end

  defp valid_price?(_), do: false

  @spec cost(Assistant.t() | ToolResult.t()) :: non_neg_integer() | :tokens_only | :unknown
  defp cost(%Assistant{billing_receipt: %{"kind" => "subscription"}}), do: :tokens_only

  defp cost(%Assistant{
         billing_receipt: %{"kind" => "api", "price" => price},
         usage: usage,
         response_model: model
       })
       when is_map(price) and is_map(usage) do
    with %{"input_tokens" => input, "cached_input_tokens" => cached, "output_tokens" => output} <-
           usage,
         true <- price["model"] == model and cached <= input,
         true <- Map.get(usage, "cache_write_tokens", 0) == 0 do
      div(
        (input - cached) * price["input_usd_micros_per_million"] +
          cached * price["cached_input_usd_micros_per_million"] +
          output * price["output_usd_micros_per_million"],
        1000
      )
    else
      _ -> :unknown
    end
  end

  defp cost(_), do: :unknown

  @spec summary([Elara.Message.t()]) :: map()
  def summary(history) do
    records =
      Enum.filter(history, fn
        %Assistant{} -> true
        %ToolResult{usage: usage} -> is_map(usage)
        _ -> false
      end)

    records
    |> Enum.group_by(fn record ->
      receipt = Map.get(record, :billing_receipt) || %{}
      {receipt["provider"], receipt["kind"], Map.get(record, :response_model)}
    end)
    |> Enum.map(fn {{provider, kind, model}, messages} ->
      Map.merge(quote_records(messages), %{
        "provider" => provider,
        "billing" => kind,
        "model" => model,
        "tokens" => Elara.Provider.Visibility.totals(messages)
      })
    end)
    |> Enum.sort_by(&{&1["provider"], &1["billing"], &1["model"]})
    |> then(&Map.put(quote_records(records), "models", &1))
  end

  defp quote_records(records) do
    initial = %{
      "estimated_usd_nanos" => nil,
      "priced_records" => 0,
      "subscription_records" => 0,
      "unpriced_records" => 0
    }

    Enum.reduce(records, initial, fn record, totals ->
      case cost(record) do
        :tokens_only ->
          Map.update!(totals, "subscription_records", &(&1 + 1))

        :unknown ->
          Map.update!(totals, "unpriced_records", &(&1 + 1))

        nanos ->
          totals
          |> Map.update!("priced_records", &(&1 + 1))
          |> Map.update!("estimated_usd_nanos", &((&1 || 0) + nanos))
      end
    end)
    |> then(&Map.put(&1, "complete", &1["unpriced_records"] == 0))
  end
end
