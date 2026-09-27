defmodule Elara.Lab.CallCountsTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.CallCounts

  setup do
    session =
      :trace.session_create(:"call_counts_#{System.unique_integer([:positive])}", self(), [])

    on_exit(fn -> :trace.session_destroy(session) end)
    %{session: session}
  end

  # A module compiled to a .beam on the code path but not loaded.
  defp unloaded_fixture do
    mod = :"elara_call_counts_fixture_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "#{mod}")
    File.mkdir_p!(dir)

    forms = [
      {:attribute, 1, :module, mod},
      {:attribute, 1, :export, [ping: 0]},
      {:function, 1, :ping, 0, [{:clause, 1, [], [], [{:atom, 1, :pong}]}]}
    ]

    {:ok, ^mod, beam} = :compile.forms(forms, [:binary])
    File.write!(Path.join(dir, "#{mod}.beam"), beam)
    true = :code.add_patha(String.to_charlist(dir))

    on_exit(fn ->
      :code.del_path(String.to_charlist(dir))
      :code.purge(mod)
      :code.delete(mod)
      File.rm_rf!(dir)
    end)

    mod
  end

  test "a module not yet loaded is loaded first, so its calls are counted", %{session: session} do
    mod = unloaded_fixture()
    assert :code.is_loaded(mod) == false

    assert CallCounts.install!(session, {mod, :ping, 0}) == :ok
    assert mod.ping() == :pong and mod.ping() == :pong
    assert :trace.info(session, {mod, :ping, 0}, :call_count) == {:call_count, 2}
  end

  test "a pattern that matches no function is refused, not counted as zero", %{session: session} do
    assert_raise ArgumentError, ~r/:lists.no_such_function\/0/, fn ->
      CallCounts.install!(session, {:lists, :no_such_function, 0})
    end

    assert_raise ArgumentError, ~r/:lists.reverse\/7/, fn ->
      CallCounts.install!(session, {:lists, :reverse, 7})
    end
  end

  test "a module that cannot be loaded is refused", %{session: session} do
    assert_raise ArgumentError, fn ->
      CallCounts.install!(session, {:elara_call_counts_no_such_module, :f, 0})
    end
  end
end
