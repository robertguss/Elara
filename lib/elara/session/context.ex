defmodule Elara.Session.Context do
  @moduledoc "Usage-anchored pre-request estimates; not exact tokenizer or wire occupancy."
  alias Elara.Message

  def budget(core, limit \\ nil, provider \\ nil) do
    window = Elara.Provider.Visibility.context_window(core.config.provider_settings || provider)

    limit =
      limit ||
        case window do
          {:ok, tokens} -> tokens
          :unknown -> 128_000
        end

    {reported, newer} =
      core.history
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

    bytes = Enum.sum(Enum.map(newer, &byte_size(JSON.encode!(public_message(&1)))))
    images = Enum.sum(Enum.map(newer, &images/1))

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

    estimate = (reported || 0) + div(bytes + 3, 4) + images * 32_768
    headroom = limit - div(limit * 9, 10)

    %{
      "limit" => limit,
      "advertised_limit" =>
        case window do
          {:ok, tokens} -> tokens
          :unknown -> nil
        end,
      "estimate_tokens" => estimate,
      "confidence" => if(window != :unknown && images == 0, do: "estimated", else: "low"),
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
