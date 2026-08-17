defmodule Mix.Tasks.Harness.ChatTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Harness.Chat

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  test "parse_args separates --continue from seed arguments" do
    assert {:ok, ["explain", "this"], [continue: true, name: nil]} =
             Chat.parse_args(["--continue", "explain", "this"])

    assert {:ok, ["explain", "this"], [continue: false, name: nil]} =
             Chat.parse_args(["explain", "this"])

    assert {:ok, [], [continue: false, name: "investigation"]} =
             Chat.parse_args(["--name", "investigation"])
  end

  test "unknown options print an error and exit 1" do
    assert {:error, "unknown option: --resume"} = Chat.parse_args(["--resume", "session"])
    assert catch_exit(Chat.run(["--unknown"])) == {:shutdown, 1}
    assert_receive {:mix_shell, :error, ["unknown option: --unknown"]}
  end

  test "missing continuation has a clear startup error" do
    assert Harness.Chat.startup_error(:no_session) ==
             "No saved session for this directory."

    assert Harness.Chat.startup_error(:locked) == "Session is already open."

    assert Harness.Chat.startup_error(:lock_unavailable) ==
             "Session locking requires the `flock` command."

    assert Harness.Chat.startup_error(:no_home) == "HOME is not set."
  end
end
