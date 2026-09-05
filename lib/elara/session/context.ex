defmodule Elara.Session.Context do
  @moduledoc "Conservative pre-request accounting, independent of the wire/snapshot budget."
  alias Elara.Message

  def budget(core, limit \\ nil) do
    selected =
      Enum.find(Elara.Provider.Visibility.catalog(), fn item ->
        core.config.provider_settings &&
          item["model"] == core.config.provider_settings["model"]
      end)

    limit = limit || (selected && selected["context_window"]) || 128_000
    images = Enum.sum(Enum.map(core.history, &images/1))

    bytes =
      byte_size(core.config.system) +
        byte_size(JSON.encode!(Enum.map(core.history, &public_message/1))) +
        byte_size(
          JSON.encode!(
            Enum.map(
              Map.values(core.config.tools),
              &Map.take(&1, [:name, :description, :parameters])
            )
          )
        ) + 4096

    # One token per UTF-8 byte is deliberately pessimistic. Image preprocessing
    # is unobserved: reserve 32K per image rather than treating base64 as tokens.
    reported =
      Enum.reduce(core.history, 0, fn
        %Message.Assistant{usage: %{"input_tokens" => input} = usage}, _ ->
          input + Map.get(usage, "output_tokens", 0)

        message, count ->
          count + byte_size(JSON.encode!(public_message(message))) + images(message) * 32_768
      end)

    estimate = max(bytes + images * 32_768, reported)
    output = max(div(limit, 10), 4096)
    handoff = max(div(limit, 10), 4096)
    tools = core.config.max_tool_output_bytes + 2048
    uncertainty = if selected, do: div(limit, 20), else: div(limit, 4)
    reserve = output + handoff + tools + uncertainty

    %{
      "limit" => limit,
      "estimate_tokens" => estimate,
      "confidence" => if(selected && images == 0, do: "conservative", else: "low"),
      "basis" =>
        "UTF-8 bytes + framing + 32768/image, floored by reported usage; not tokenizer occupancy",
      "reserves" => %{
        "output" => output,
        "handoff" => handoff,
        "tools" => tools,
        "uncertainty" => uncertainty
      },
      "warning" => estimate + reserve >= div(limit * 4, 5),
      "handoff_required" => estimate + reserve >= limit
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
