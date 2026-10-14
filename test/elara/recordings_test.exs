defmodule Elara.RecordingsTest do
  use ExUnit.Case, async: false

  alias Elara.Recordings

  @tag :tmp_dir
  test "explicit age pruning previews, respects live locks, and leaves other evidence", %{
    tmp_dir: root
  } do
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, root)
    on_exit(fn -> Application.put_env(:elara, :sessions_root, previous) end)
    {:ok, provider} = Agent.start_link(fn -> [] end)

    new = fn ->
      {:ok, id} =
        Elara.start_session(
          provider: {Elara.Provider.Scripted, provider},
          tools: [],
          cwd: root,
          skill_paths: [],
          home: root
        )

      path = Elara.status(id).recording_path
      {:ok, pid} = Elara.session_pid(id)
      {path, pid}
    end

    {old, old_pid} = new.()
    {live, live_pid} = new.()
    {recent, recent_pid} = new.()
    on_exit(fn -> if Process.alive?(live_pid), do: GenServer.stop(live_pid) end)
    GenServer.stop(old_pid)
    GenServer.stop(recent_pid)
    now = System.system_time(:second)
    File.touch!(old, now - 31 * 86_400)
    File.touch!(live, now - 31 * 86_400)
    File.touch!(recent, now - 30 * 86_400)
    original = File.read!(old)
    live_bytes = File.read!(live)
    output = Path.join([root, "outputs", "owner", "retained.bytes"])
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, "retained output")
    expected_bytes = Enum.sum(Enum.map([old, live, recent], &File.stat!(&1).size))

    assert {:ok, %{recordings_bytes: ^expected_bytes, retained_output_bytes: 15}} =
             Recordings.diagnostics()

    # A different VM's OS lock is authoritative even without a Registry entry.
    {:ok, recording} = Elara.FlightRecorder.load(old)
    transcript = Path.join(Path.dirname(old), recording.header.session_id <> ".jsonl")

    lock =
      Port.open(
        {:spawn_executable, System.find_executable("flock")},
        [
          :binary,
          :exit_status,
          {:args, ["-n", transcript <> ".lock", "sh", "-c", "printf ready; read release"]}
        ]
      )

    assert_receive {^lock, {:data, "ready"}}
    assert {:ok, locked} = Recordings.prune(30, now: now, apply: true)
    assert Enum.find(locked, &(&1.path == old)).status == :live
    assert Enum.find(locked, &(&1.path == live)).status == :live
    Port.command(lock, "release\n")
    assert_receive {^lock, {:exit_status, 0}}

    assert {:ok, preview} = Recordings.prune(30, now: now)
    assert Enum.find(preview, &(&1.path == old)).status == :would_delete
    assert Enum.find(preview, &(&1.path == recent)).status == :kept
    assert File.read!(old) == original
    assert {:ok, applied} = Recordings.prune(30, now: now, apply: true)
    assert Enum.find(applied, &(&1.path == old)).status == :deleted
    refute File.exists?(old)
    assert File.read!(live) == live_bytes
    assert File.exists?(recent)
    assert File.exists?(transcript)
    assert File.read!(output) == "retained output"
  end
end
