defmodule Elara.Session.Context do
  @moduledoc "Usage-anchored pre-request estimates; not exact tokenizer or wire occupancy."
  alias Elara.Message

  def messages(core) do
    core.history
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      case {message, Map.get(core.cleared_tools, index)} do
        {%Message.ToolResult{outcome: {kind, _}} = result, %{placeholder: text}} ->
          %{result | outcome: {kind, text}}

        {%Message.Assistant{} = assistant, _} when index < core.context_usage_after ->
          %{assistant | usage: nil}

        _ ->
          message
      end
    end)
  end

  def restore(core, store) do
    entries = Elara.Session.Store.path_entries(store, store.leaf)
    clearing = store.context["clearing"] || %{}
    ids = MapSet.new(clearing["entries"] || [])

    cleared =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _} ->
        is_struct(entry.message, Message.ToolResult) and MapSet.member?(ids, entry.id)
      end)
      |> Map.new(fn {entry, index} -> {index, target(entry, index, store.id)} end)

    reset = Enum.find_index(entries, &(&1.id == clearing["usage_reset_entry"]))
    after_index = if reset, do: reset + 1, else: length(entries)

    %{
      core
      | cleared_tools: cleared,
        context_usage_after: if(map_size(cleared) > 0, do: after_index, else: 0),
        web_content_entered:
          core.web_content_entered or store.context["web_content_entered"] == true
    }
  end

  def clearing(core, store, limit, provider) do
    results =
      core.history
      |> Enum.with_index()
      |> Enum.filter(fn {message, _} -> is_struct(message, Message.ToolResult) end)
      |> Enum.reverse()

    {protected, _} =
      results
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), 0}, fn {{result, index}, count}, {protected, bytes} ->
        keep? =
          count < core.config.context_keep_results or bytes < core.config.context_keep_tokens * 4

        {if(keep?, do: MapSet.put(protected, index), else: protected),
         bytes + byte_size(elem(result.outcome, 1))}
      end)

    seen_before =
      core.history
      |> Enum.with_index()
      |> Enum.filter(fn {message, _} ->
        match?(%Message.Assistant{interrupted: false}, message)
      end)
      |> List.last()
      |> case do
        nil -> 0
        {_, index} -> index
      end

    candidates =
      store
      |> Elara.Session.Store.path_entries(store.leaf)
      |> Enum.with_index()
      |> Enum.filter(fn {entry, index} ->
        is_struct(entry.message, Message.ToolResult) and index < seen_before and
          not MapSet.member?(protected, index) and not Map.has_key?(core.cleared_tools, index)
      end)
      |> Enum.map(fn {entry, index} -> target(entry, index, store.id) end)
      |> Enum.filter(&(&1.bytes > byte_size(&1.placeholder)))

    {_, selected, freed} =
      Enum.reduce_while(candidates, {core, [], 0}, fn entry, {projected, selected, freed} ->
        if budget(projected, limit, provider)["handoff_required"] do
          projected = %{
            projected
            | cleared_tools: Map.put(projected.cleared_tools, entry.index, entry),
              context_usage_after: length(core.history)
          }

          {:cont,
           {projected, [entry | selected], freed + entry.bytes - byte_size(entry.placeholder)}}
        else
          {:halt, {projected, selected, freed}}
        end
      end)

    {Enum.reverse(selected), freed}
  end

  defp target(entry, index, session_id) do
    result = entry.message
    bytes = byte_size(elem(result.outcome, 1))

    retrieval =
      JSON.encode!(%{
        "thread_id" => session_id,
        "source_message_id" => entry.id,
        "character_offset" => 0
      })

    %{
      index: index,
      entry_id: entry.id,
      bytes: bytes,
      placeholder:
        "[cleared #{result.name} result: #{bytes} bytes; entry #{entry.id}] " <>
          "Original retained. Retrieve with thread_read #{retrieval}; " <>
          "use the returned next_character_offset for more pages."
    }
  end

  def budget(core, limit \\ nil, provider \\ nil, estimated_tokens \\ nil) do
    window =
      Elara.Provider.Visibility.context_window(
        if(core.config.provider_settings,
          do: {core.config.provider_settings, core.config.provider_catalog},
          else: provider
        )
      )

    limit =
      limit ||
        case window do
          {:ok, tokens} -> tokens
          :unknown -> 128_000
        end

    {reported, newer} =
      messages(core)
      |> Enum.reverse()
      |> Enum.split_while(fn
        %Message.Assistant{usage: %{"input_tokens" => _}} -> false
        _ -> true
      end)
      |> then(fn {newer, rest} ->
        case rest do
          [%Message.Assistant{usage: usage} | _] ->
            {usage["input_tokens"] + Map.get(usage, "output_tokens", 0), newer}

          [] ->
            {nil, newer}
        end
      end)

    images = Enum.sum(Enum.map(newer, &images/1))

    estimate =
      if is_nil(estimated_tokens) do
        bytes = Enum.sum(Enum.map(newer, &byte_size(JSON.encode!(public_message(&1)))))

        bytes =
          if reported do
            bytes
          else
            bytes + byte_size(core.config.system) + 4096 +
              byte_size(
                JSON.encode!(
                  Enum.map(
                    Map.values(core.config.tools),
                    &Map.take(&1, [:name, :description, :parameters])
                  )
                )
              )
          end

        (reported || 0) + div(bytes + 3, 4) + images * 32_768
      else
        estimated_tokens
      end

    headroom = limit - div(limit * 9, 10)

    %{
      "limit" => limit,
      "advertised_limit" =>
        case window do
          {:ok, tokens} -> tokens
          :unknown -> nil
        end,
      "estimate_tokens" => estimate,
      "confidence" =>
        if(
          window != :unknown && images == 0 && (reported != nil || core.context_usage_after == 0),
          do: "estimated",
          else: "low"
        ),
      "basis" =>
        "Last main-provider input + output tokens, then newer UTF-8 bytes / 4; without usage, request bytes / 4 including framing. Unreported images add 32768/image; not exact tokenizer occupancy",
      "reserves" => %{
        "output" => headroom,
        "handoff" => 0,
        "tools" => 0,
        "uncertainty" => 0
      },
      "warning" => estimate >= div(limit * 4, 5),
      "handoff_required" => estimate + headroom >= limit
    }
  end

  defp images(%Message.User{attachments: attachments}),
    do: Enum.count(attachments, &(&1["kind"] == "image"))

  defp images(_), do: 0

  defp public_message(%Message.User{} = user),
    do:
      Elara.Session.Store.encode_message(%{
        user
        | attachments: Enum.map(user.attachments, &Elara.Attachment.metadata/1)
      })

  defp public_message(%Message.Assistant{} = assistant),
    do: Elara.Session.Store.encode_message(%{assistant | provider_state: nil})

  defp public_message(message), do: Elara.Session.Store.encode_message(message)
end
