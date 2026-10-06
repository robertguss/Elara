defmodule Elara.Lab.InputObserver do
  @moduledoc """
  Read-only evidence for linear lab fixtures, including persisted handoff
  successors. Physical side effects are not completion evidence.
  Successful completion requires a consumed receipt and its own persisted
  terminal; failures, interrupted turns and paused queues are separate outcomes.
  An observed interrupted-turn event can establish interruption only when it
  follows that input's observed User and matches its persisted consumed receipt.
  """

  alias Elara.Message.{Assistant, ToolResult, User}
  alias Elara.Session.Store

  def read(path, expected, events \\ []) do
    with {:ok, stores} <- chain(path, [], 0, nil) do
      {:ok, judge(stores, expected, events)}
    end
  end

  def judge(stores, expected, events \\ []) do
    entries = for store <- stores, entry <- store.entries, do: {store, entry}

    inputs =
      Map.new(expected, fn {label, attrs} ->
        receipts =
          for store <- stores,
              receipt <- store.inbox,
              receipt.id == attrs.id,
              do: {store, receipt}

        users = Enum.filter(entries, fn {_store, entry} -> entry.message == attrs.user end)

        selected =
          Enum.find(Enum.reverse(receipts), fn {_store, receipt} ->
            receipt.state in [:consumed, :failed, :cancelled]
          end) || List.last(receipts)

        {store, receipt} = selected || {nil, nil}
        terminals = Enum.flat_map(users, fn {owner, user} -> terminals(owner, user) end)
        state = outcome(store, receipt, users, terminals, attrs)

        interrupted =
          case {state, receipt, users, terminals} do
            {:incomplete, %{state: :consumed, error: nil}, [{owner, user}], []} ->
              store.active_input_id != receipt.id and
                settled_segment?(owner, user, nil) and
                interrupted_event?(owner.id, attrs.user, events)

            _ ->
              false
          end

        state = if interrupted, do: :interrupted, else: state

        {label,
         %{
           accepted_id: attrs.id,
           state: state,
           terminal: state in [:completed, :failed, :interrupted, :cancelled],
           completed: state == :completed,
           receipt: receipt && Map.drop(receipt, [:user]),
           receipt_user: receipt && Store.encode_message(receipt.user),
           receipt_owner: store && store.id,
           user_entries:
             Enum.map(users, fn {owner, entry} -> %{session: owner.id, id: entry.id} end),
           terminal_entries: Enum.map(terminals, & &1.id),
           interrupted_event: interrupted,
           identity:
             receipts != [] and
               Enum.all?(receipts, fn {owner, receipt} ->
                 receipt.session_id == owner.id and receipt.sender_id == attrs.sender_id and
                   receipt.kind == attrs.kind and receipt.user == attrs.user
               end)
         }}
      end)

    checks = %{
      input_identities: Enum.all?(inputs, fn {_label, input} -> input.identity end),
      known_history_inputs:
        Enum.all?(entries, fn {_store, entry} ->
          not is_struct(entry.message, User) or
            Enum.any?(expected, fn {_label, attrs} -> attrs.user == entry.message end)
        end),
      known_receipts:
        Enum.all?(stores, fn store ->
          Enum.all?(store.inbox, fn receipt ->
            Enum.any?(expected, fn {_label, attrs} -> attrs.id == receipt.id end)
          end)
        end),
      unique_accepted_ids: expected |> Map.values() |> Enum.map(& &1.id) |> unique?(),
      unique_input_payloads: expected |> Map.values() |> Enum.map(& &1.user) |> unique?(),
      at_most_once_consumption:
        Enum.all?(inputs, fn {_label, input} -> length(input.user_entries) <= 1 end),
      linear_history: Enum.all?(stores, &linear?/1),
      unique_history_ids: Enum.map(entries, fn {_store, entry} -> entry.id end) |> unique?(),
      call_result_identity: calls_valid?(entries),
      handoff_chain_ready:
        Enum.all?(stores, fn store ->
          case store.context["handoff"] do
            nil -> true
            %{"stage" => "started"} -> true
            _ -> false
          end
        end)
    }

    valid = Enum.all?(checks, fn {_name, passed} -> passed end)

    %{
      checks: checks,
      inputs: inputs,
      all_terminal: valid and Enum.all?(inputs, fn {_label, input} -> input.terminal end),
      all_completed: valid and Enum.all?(inputs, fn {_label, input} -> input.completed end),
      stores:
        Enum.map(stores, fn store ->
          %{
            id: store.id,
            path: store.path,
            cwd: store.cwd,
            parent_session: store.parent_session,
            handoff: store.context["handoff"],
            inputs_paused: store.inputs_paused,
            active_input_id: store.active_input_id,
            inbox:
              Enum.map(store.inbox, fn receipt ->
                Map.put(receipt, :user, Store.encode_message(receipt.user))
              end),
            history:
              Enum.map(store.entries, fn entry ->
                %{
                  id: entry.id,
                  parent_id: entry.parent_id,
                  message: Store.encode_message(entry.message)
                }
              end)
          }
        end)
    }
  end

  defp chain(_path, _stores, depth, _expected_id) when depth > 8,
    do: {:error, :handoff_chain_limit}

  defp chain(path, stores, depth, expected_id) do
    with {:ok, store} <- Store.open(path),
         false <- Enum.any?(stores, &(&1.id == store.id)),
         :ok <- identity(expected_id, store.id),
         true <- linked?(List.last(stores), store) do
      stores = stores ++ [store]

      case store.context["handoff"] do
        nil ->
          {:ok, stores}

        %{"id" => next, "path" => next_path, "stage" => "prepared"} ->
          if File.exists?(next_path),
            do: chain(next_path, stores, depth + 1, next),
            else: {:ok, stores}

        %{"id" => next, "path" => next_path} ->
          chain(next_path, stores, depth + 1, next)

        _ ->
          {:error, :invalid_handoff_link}
      end
    else
      true -> {:error, :handoff_cycle}
      false -> {:error, :invalid_handoff_parent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity(nil, _id), do: :ok
  defp identity(id, id), do: :ok
  defp identity(_expected, _actual), do: {:error, :handoff_identity_mismatch}

  defp linked?(nil, _store), do: true

  defp linked?(parent, store),
    do:
      store.parent_session == parent.id and
        store.context["source"] == parent.id and store.cwd == parent.cwd

  defp linear?(%{entries: [], leaf: nil}), do: true
  defp linear?(%{entries: []}), do: false

  defp linear?(store),
    do:
      store.leaf == List.last(store.entries).id and
        Enum.map(store.entries, & &1.parent_id) == [
          nil | Enum.map(Enum.drop(store.entries, -1), & &1.id)
        ]

  defp segment(store, user) do
    store.entries
    |> Enum.drop_while(&(&1.id != user.id))
    |> Enum.drop(1)
    |> Enum.take_while(&(not is_struct(&1.message, User)))
  end

  defp terminals(store, user) do
    segment(store, user)
    |> Enum.filter(fn entry ->
      match?(%Assistant{tool_calls: []}, entry.message) and
        (entry.message.interrupted or is_binary(entry.message.text))
    end)
  end

  defp outcome(nil, nil, _users, _terminals, _attrs), do: :missing

  defp outcome(_store, %{state: :failed, error: error}, _users, _terminals, _attrs)
       when is_binary(error) and error != "", do: :failed

  defp outcome(_store, %{state: :cancelled}, [], _terminals, _attrs), do: :cancelled

  defp outcome(
         store,
         %{state: :consumed, error: nil} = receipt,
         [{owner, user}],
         [terminal],
         attrs
       ) do
    cond do
      store.active_input_id == receipt.id ->
        :incomplete

      not settled_segment?(owner, user, terminal) ->
        :incomplete

      terminal.message.interrupted ->
        :interrupted

      Map.get(attrs, :terminal_text, terminal.message.text) != terminal.message.text ->
        :incomplete

      true ->
        :completed
    end
  end

  defp outcome(%{inputs_paused: true}, %{state: state}, [], [], _attrs)
       when state in [:accepted, :queued], do: :paused

  defp outcome(_store, _receipt, _users, _terminals, _attrs), do: :incomplete

  defp settled_segment?(store, user, terminal) do
    entries = segment(store, user) |> Enum.take_while(&(terminal == nil or &1.id != terminal.id))

    calls =
      for entry <- entries,
          is_struct(entry.message, Assistant),
          call <- entry.message.tool_calls,
          do: call

    results = for entry <- entries, is_struct(entry.message, ToolResult), do: entry.message

    length(calls) == length(results) and
      Enum.all?(calls, fn call ->
        Enum.count(results, &(&1.call_id == call.id and &1.name == call.name)) == 1
      end)
  end

  defp interrupted_event?(session, user, events) do
    own = Enum.filter(events, &(&1.session == session))
    start = {:message_appended, user}

    endings =
      own
      |> Enum.drop_while(&(&1.event != start))
      |> Enum.drop(1)
      |> Enum.take_while(&(not match?({:message_appended, %User{}}, &1.event)))
      |> Enum.filter(
        &(match?({:turn_ended, _}, &1.event) or match?({:turn_ended, _, _}, &1.event))
      )
      |> Enum.map(& &1.event)

    Enum.count(own, &(&1.event == start)) == 1 and endings == [{:turn_ended, :interrupted}]
  end

  defp calls_valid?(entries) do
    calls =
      for {store, entry} <- entries,
          is_struct(entry.message, Assistant),
          call <- entry.message.tool_calls,
          do: {store.id, entry.id, call}

    results =
      for {store, entry} <- entries,
          is_struct(entry.message, ToolResult),
          do: {store.id, entry.id, entry.message}

    ids = Enum.map(calls, fn {_store, _entry, call} -> call.id end)

    unique?(ids) and Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
      unique?(Enum.map(results, fn {_store, _entry, result} -> result.call_id end)) and
      Enum.all?(results, fn {owner, result_id, result} ->
        case Enum.find(calls, fn {session, _entry, call} ->
               session == owner and call.id == result.call_id and call.name == result.name
             end) do
          {_, call_id, _} ->
            owner_entries = Enum.filter(entries, fn {store, _entry} -> store.id == owner end)

            index = fn id ->
              Enum.find_index(owner_entries, fn {_store, entry} -> entry.id == id end)
            end

            call_index = index.(call_id)
            result_index = index.(result_id)

            input = fn index ->
              owner_entries
              |> Enum.take(index + 1)
              |> Enum.filter(fn {_store, entry} ->
                is_struct(entry.message, User)
              end)
              |> List.last()
            end

            call_index < result_index and input.(call_index) != nil and
              input.(call_index) == input.(result_index)

          nil ->
            false
        end
      end)
  end

  defp unique?(ids), do: length(ids) == length(Enum.uniq(ids))
end
