defmodule Elara.Completion do
  @moduledoc "Wait for a correlated durable inbox completion; never starts or retries work."
  alias Elara.{Tool, TestJobs.Record}
  alias Elara.Session.{Handoff, Store}

  def tool do
    %Tool{
      name: "completion_wait",
      description:
        "Wait for an owned job or direct related thread's retained completion without model polling. Supply source job/job_id or thread/thread_id. An explicit wait consumes that completion once and returns a bounded untrusted preview with the full retained input ID; interrupt cancels waiting without cancelling the job.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "source" => %{"type" => "string", "enum" => ["job", "thread"]},
          "job_id" => %{"type" => "string"},
          "thread_id" => %{"type" => "string"}
        },
        "required" => ["source"],
        "additionalProperties" => false
      },
      run: {__MODULE__, :run},
      placement: :local
    }
  end

  def run(%{"source" => "job", "job_id" => id}, %Tool.Ctx{session_id: session} = ctx) do
    case wait(session, "job", id) do
      {:ok, response} -> encode_response(response, ctx.max_output_bytes)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def run(%{"thread_id" => id}, %Tool.Ctx{tool_name: "thread_wait"} = ctx),
    do: run(%{"source" => "thread", "thread_id" => id}, %{ctx | tool_name: "completion_wait"})

  def run(%{"source" => "thread", "thread_id" => id}, %Tool.Ctx{session_id: session} = ctx) do
    case Elara.Threads.Communication.wait(session, id) do
      {:ok, response} -> encode_response(response, ctx.max_output_bytes)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def run(_, _), do: {:error, "invalid completion_wait arguments"}

  defp encode_response(response, limit) do
    json = JSON.encode!(response)

    cond do
      is_nil(limit) or byte_size(json) <= limit ->
        {:ok, json}

      Map.has_key?(response, :record) or Map.has_key?(response, :messages) ->
        response
        |> Map.drop([:record, :messages])
        |> Map.put("status_details_omitted", true)
        |> encode_response(limit)

      get_in(response, ["evidence", "text"]) not in [nil, ""] ->
        text = response["evidence"]["text"]
        preview = String.slice(text, 0, div(String.length(text), 2))
        encode_response(put_in(response, ["evidence", "text"], preview), limit)

      true ->
        {:error, "completion receipt exceeds tool output limit; input remains retained"}
    end
  end

  def wait(session, "job", id)
      when is_binary(session) and is_binary(id) and byte_size(id) in 1..128 do
    with {:ok, record} <- Record.load(Record.key(Handoff.logical_id(session), id)),
         {:ok, pid} <- Elara.session_pid(Handoff.owner(session)),
         correlation = %{"source" => "job", "id" => "job:" <> record["key"]},
         {:ok, entry} <- GenServer.call(pid, {:input_status, "test-job:" <> record["key"]}),
         {:ok, _} <-
           if(entry,
             do:
               GenServer.call(
                 pid,
                 {:submit_input,
                  entry
                  |> Map.take([:id, :sender_id, :kind, :user])
                  |> Map.put(:correlation, correlation)}
               ),
             else: {:ok, nil}
           ) do
      GenServer.call(pid, {:await_completion, correlation}, :infinity)
    end
  catch
    :exit, _ -> {:error, :completion_owner_disconnected_no_replay}
  end

  def wait(session, "thread", id) when is_binary(session) and is_binary(id) do
    with {:ok, pid} <- Elara.session_pid(Handoff.owner(session)) do
      case Elara.Threads.Communication.subscribe_completion(session, id) do
        {:ok, correlation, transport} ->
          GenServer.call(pid, {:await_completion, correlation, transport}, :infinity)

        {:idle, status} ->
          {:ok, Map.put(status, "awaited", false)}

        {:error, _} = error ->
          error
      end
    end
  catch
    :exit, _ -> {:error, :completion_owner_disconnected_no_replay}
  end

  def wait(_, _, _), do: {:error, :invalid_completion_target}

  @doc false
  def occurrence(%Store{completion_occurrence: occurrence}) when is_binary(occurrence),
    do: occurrence

  def occurrence(store) do
    case Enum.find(
           store |> Store.path_entries(store.leaf) |> Enum.reverse(),
           &match?(%Store.Entry{message: %Elara.Message.User{}}, &1)
         ) do
      nil -> nil
      entry -> entry.id
    end
  end

  @doc false
  def thread_correlation(store) do
    if occurrence = occurrence(store),
      do: %{
        "source" => "thread",
        "id" => "thread:" <> Handoff.logical_id(store.id) <> ":" <> occurrence
      }
  end

  @doc false
  def valid_correlation?(nil), do: true

  def valid_correlation?(%{"source" => source, "id" => id} = correlation) do
    map_size(correlation) == 2 and source in ["job", "thread"] and is_binary(id) and
      String.valid?(id) and byte_size(id) in 1..256 and not String.contains?(id, <<0>>)
  end

  def valid_correlation?(_), do: false
end
