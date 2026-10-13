defmodule Elara.Lab.InputObserverTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.InputObserver
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "lab-input-observer-#{System.unique_integer([:positive])}")
    old = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(dir, "sessions"))

    on_exit(fn ->
      Application.put_env(:elara, :sessions_root, old)
      File.rm_rf!(dir)
    end)

    expected =
      Map.new(["A", "B"], fn label ->
        {label,
         %{
           id: "accepted-#{label}",
           sender_id: "lab",
           kind: :normal,
           user: %User{text: "input #{label}"},
           terminal_text: "done #{label}"
         }}
      end)

    %{dir: dir, expected: expected}
  end

  test "reads a finished successor without attaching and distinguishes interrupted source input",
       ctx do
    {source, successor} = fixture(ctx)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert Enum.all?(view.checks, fn {_name, value} -> value end)
    assert view.all_terminal
    refute view.all_completed
    assert view.inputs["A"].state == :interrupted
    assert view.inputs["B"].state == :completed
    assert view.inputs["B"].receipt_owner == successor.id
    assert length(view.inputs["B"].user_entries) == 1
  end

  test "a paused queued input and a consumed-only receipt are not completions", ctx do
    {source, successor} = fixture(ctx)

    successor = %{
      successor
      | entries: [],
        leaf: nil,
        inputs_paused: true,
        inbox: [receipt(successor.id, ctx.expected["B"], :queued)]
    }

    {:ok, successor} = Store.save(successor)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.inputs["B"].state == :paused
    refute view.all_terminal
    refute view.all_completed

    {:ok, _} =
      Store.save(%{
        successor
        | inputs_paused: false,
          inbox: [receipt(successor.id, ctx.expected["B"], :consumed)]
      })

    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.inputs["B"].state == :incomplete
  end

  test "rejects a stale terminal before the input and a wrong terminal in its segment", ctx do
    {source, successor} = fixture(ctx)

    stale =
      history(%{successor | entries: [], leaf: nil}, [
        %User{text: "older input"},
        %Assistant{text: "done B"},
        ctx.expected["B"].user
      ])

    {:ok, _} = Store.save(stale)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.inputs["B"].state == :incomplete

    wrong =
      history(%{successor | entries: [], leaf: nil}, [
        ctx.expected["B"].user,
        %Assistant{text: "done older input"}
      ])

    {:ok, _} = Store.save(wrong)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.inputs["B"].state == :incomplete
  end

  test "rejects duplicate consumption and forged receipt identities", ctx do
    {source, successor} = fixture(ctx)
    duplicate = history(successor, [ctx.expected["B"].user, %Assistant{text: "done B"}])
    {:ok, _} = Store.save(duplicate)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    refute view.checks.at_most_once_consumption
    refute view.all_terminal

    wrong = %{successor | inbox: [Map.put(hd(successor.inbox), :sender_id, "other")]}
    {:ok, _} = Store.save(wrong)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    refute view.checks.input_identities
    refute view.all_terminal
  end

  test "rejects history and receipts outside the declared fixture", ctx do
    {source, successor} = fixture(ctx)

    extra =
      history(successor, [%User{text: "unplanned input"}, %Assistant{text: "unplanned answer"}])

    {:ok, _} = Store.save(extra)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    refute view.checks.known_history_inputs
    refute view.all_terminal

    unexpected = receipt(successor.id, Map.put(ctx.expected["B"], :id, "unplanned-id"), :accepted)
    {:ok, _} = Store.save(%{successor | inbox: [unexpected | successor.inbox]})
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    refute view.checks.known_receipts
    refute view.all_terminal
  end

  test "a durable failed receipt is terminal but cannot be counted as success", ctx do
    {source, successor} = fixture(ctx)
    failed = receipt(successor.id, ctx.expected["B"], :failed) |> Map.put(:error, "provider died")
    {:ok, _} = Store.save(%{successor | inbox: [failed]})
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.all_terminal
    assert view.inputs["B"].state == :failed
    refute view.all_completed
  end

  test "only an interrupted event after its own observed input can establish interruption", ctx do
    {source, _successor} = fixture(ctx)
    source = history(%{source | entries: [], leaf: nil}, [ctx.expected["A"].user])
    {:ok, source} = Store.save(source)
    user = %{session: source.id, event: {:message_appended, ctx.expected["A"].user}}
    ended = %{session: source.id, event: {:turn_ended, :interrupted}}

    assert {:ok, view} = InputObserver.read(source.path, ctx.expected, [user, ended])
    assert view.inputs["A"].state == :interrupted
    assert view.inputs["A"].interrupted_event
    refute view.inputs["A"].completed

    for events <- [
          [ended, user],
          [ended],
          [user, Map.put(ended, :session, "other")],
          [user, ended, ended],
          [user, %{session: source.id, event: {:message_appended, ctx.expected["B"].user}}, ended]
        ] do
      assert {:ok, view} = InputObserver.read(source.path, ctx.expected, events)
      assert view.inputs["A"].state == :incomplete
    end

    call = %ToolCall{id: "A-call", name: "write", args: {:ok, %{}}}
    {:ok, _} = Store.save(history(source, [%Assistant{tool_calls: [call]}]))
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected, [user, ended])
    assert view.inputs["A"].state == :incomplete
  end

  test "rejects wrong handoff identity, parent, and cycles", ctx do
    {source, successor} = fixture(ctx)
    {:ok, _} = Store.save(put_in(source.context["handoff"]["id"], "wrong-id"))
    assert {:error, :handoff_identity_mismatch} = InputObserver.read(source.path, ctx.expected)
    {:ok, _} = Store.save(source)
    {:ok, _} = Store.save(%{successor | parent_session: "wrong-parent"})
    assert {:error, :invalid_handoff_parent} = InputObserver.read(source.path, ctx.expected)

    {:ok, _} = Store.save(%{successor | cwd: Path.join(ctx.dir, "another-workspace")})
    assert {:error, :invalid_handoff_parent} = InputObserver.read(source.path, ctx.expected)

    {:ok, _} =
      Store.save(%{
        successor
        | context:
            Map.put(successor.context, "handoff", %{
              "id" => source.id,
              "path" => source.path,
              "stage" => "started"
            })
      })

    assert {:error, :handoff_cycle} = InputObserver.read(source.path, ctx.expected)
  end

  test "terminal answers require settled tools in their own input segment", ctx do
    {source, successor} = fixture(ctx)
    call = %ToolCall{id: "B-call", name: "write", args: {:ok, %{"path" => "B"}}}
    base = %{successor | entries: [], leaf: nil}

    missing =
      history(base, [
        ctx.expected["B"].user,
        %Assistant{tool_calls: [call]},
        %Assistant{text: "done B"}
      ])

    {:ok, _} = Store.save(missing)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    assert view.inputs["B"].state == :incomplete

    misplaced =
      history(base, [
        ctx.expected["B"].user,
        %Assistant{tool_calls: [call]},
        %User{text: "other"},
        %ToolResult{call_id: call.id, name: "write", outcome: {:ok, "written"}},
        %Assistant{text: "done B"}
      ])

    {:ok, _} = Store.save(misplaced)
    assert {:ok, view} = InputObserver.read(source.path, ctx.expected)
    refute view.checks.call_result_identity
  end

  defp fixture(ctx) do
    source = Store.new(ctx.dir)

    successor = %{
      Store.new(ctx.dir)
      | parent_session: source.id,
        context: %{"source" => source.id}
    }

    source =
      history(source, [ctx.expected["A"].user, %Assistant{text: "interrupted", interrupted: true}])

    successor = history(successor, [ctx.expected["B"].user, %Assistant{text: "done B"}])

    source = %{
      source
      | inbox: [
          receipt(source.id, ctx.expected["A"], :consumed),
          receipt(source.id, ctx.expected["B"], :queued)
        ],
        context: %{
          "handoff" => %{
            "id" => successor.id,
            "path" => successor.path,
            "stage" => "started",
            "delivery_owner" => successor.id
          }
        }
    }

    successor = %{successor | inbox: [receipt(successor.id, ctx.expected["B"], :consumed)]}
    {:ok, source} = Store.save(source)
    {:ok, successor} = Store.save(successor)
    {source, successor}
  end

  defp receipt(owner, attrs, state) do
    attrs
    |> Map.drop([:terminal_text])
    |> Map.put(:session_id, owner)
    |> Map.put(:state, state)
    |> Map.put(:error, nil)
    |> Map.put(:created_at, 0)
  end

  defp history(store, messages),
    do:
      Enum.reduce(messages, store, fn message, store ->
        {:ok, store} = Store.append(store, message)
        store
      end)
end
