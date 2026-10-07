defmodule Elara.ChatPasteTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "scripted chat through a real terminal keeps multiline paste atomic" do
    python = System.find_executable("python3") || flunk("python3 is required for PTY coverage")

    for mode <- ["echoctl", "noechoctl"] do
      assert {output, 0} =
               System.cmd(python, [Path.expand("../support/chat_paste_pty.py", __DIR__), mode],
                 stderr_to_stdout: true
               )

      assert output =~ "Chat PTY passed"
    end
  end
end
