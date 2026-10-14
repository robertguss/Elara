defmodule Elara.VerificationHarnessTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("../..", __DIR__)
  @bin Path.join(@root, ".cursor/skills/verify-elara/bin")

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "verification")
    home = Path.join(root, "home")
    user = Path.join(tmp, "user home")
    workspace = Path.join(root, "workspace")
    worktree = Path.join(root, "worktree")

    for dir <- [Path.join(home, ".elara"), user, workspace, worktree, Path.join(root, "_build")],
        do: File.mkdir_p!(dir)

    File.write!(Path.join(home, ".elara/verify-marker"), "isolated\n")
    File.write!(Path.join(worktree, "mix.exs"), "# fixture\n")
    state = Path.join(root, "state.env")

    File.write!(
      state,
      Enum.map_join(
        [
          {"RUN_ID", "test"},
          {"VERIFY_ROOT", root},
          {"REPO_ROOT", root},
          {"WORKSPACE", workspace},
          {"WORKTREE", worktree},
          {"HOME", home},
          {"ELARA_USER_HOME", user},
          {"ELARA_SERVER_PORT", "0"},
          {"ELARA_TUI_STATE_DIR", Path.join(root, "tui")},
          {"EVIDENCE_ROOT", Path.join(root, "evidence")},
          {"PIDS", ""}
        ],
        "\n",
        fn {key, value} -> key <> "=" <> inspect(value) end
      )
    )

    %{state: state, home: home, user: user}
  end

  test "loading an isolated state preserves the Rustup cache and an explicit override", ctx do
    for {override, expected} <- [
          {nil, Path.join(ctx.user, ".rustup")},
          {Path.join(ctx.user, "custom rustup"), Path.join(ctx.user, "custom rustup")}
        ] do
      assert {output, 0} =
               System.cmd(
                 "bash",
                 [
                   "-c",
                   ~S"""
                   source "$1/common.sh"
                   load_state "$2"
                   printf '%s\n%s\n' "$HOME" "${RUSTUP_HOME:-}"
                   """,
                   "verify",
                   @bin,
                   ctx.state
                 ],
                 env: [{"RUSTUP_HOME", override}],
                 stderr_to_stdout: true
               )

      assert output == ctx.home <> "\n" <> expected <> "\n"
    end
  end

  test "doctor rejects a failed cargo probe, including in the loaded HOME", ctx do
    bin = Path.join(ctx.user, "bin")
    File.mkdir_p!(bin)
    cargo = Path.join(bin, "cargo")

    File.write!(cargo, ~S"""
    #!/bin/sh
    if [ "${FAIL_CARGO:-}" = yes ] || [ "$HOME" = "$FAIL_CARGO_HOME" ]; then
      echo 'intentional cargo failure' >&2
      exit 23
    fi
    echo 'cargo 1.98.1 (test)'
    """)

    File.chmod!(cargo, 0o755)
    env = [{"PATH", bin <> ":" <> System.fetch_env!("PATH")}, {"HOME", ctx.user}]

    for {args, extra} <- [
          {["--toolchain-only"], [{"FAIL_CARGO", "yes"}, {"FAIL_CARGO_HOME", ""}]},
          {[ctx.state], [{"FAIL_CARGO", "no"}, {"FAIL_CARGO_HOME", ctx.home}]}
        ] do
      {output, status} =
        System.cmd(Path.join(@bin, "doctor"), args, env: env ++ extra, stderr_to_stdout: true)

      assert status == 1, output
      assert output =~ "cargo version probe failed"
      refute output =~ "OK    cargo"
      refute output =~ "instance is safe to drive"
    end

    assert {output, 0} =
             System.cmd(Path.join(@bin, "doctor"), [ctx.state],
               env: env ++ [{"FAIL_CARGO", "no"}, {"FAIL_CARGO_HOME", ""}],
               stderr_to_stdout: true
             )

    assert output =~ "OK    cargo 1.98.1"
    assert output =~ "instance is safe to drive"
  end

  test "scripted chat waits for completed replies before the next command", ctx do
    cwd = Path.join(System.tmp_dir!(), "verify-chat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    script = Path.join(@root, ".cursor/skills/verify-elara/scripts/scripted_chat.exs")
    paths = :code.get_path() |> Enum.reject(&(&1 == ~c"."))

    for {lines, reply, replies, status, texts} <- [
          {"/help,hello,/why,/quit", "single 日本 reply", "", 0, ["single 日本 reply"]},
          {"first,/why,second,/quit", "", "first reply||second reply", 0,
           ["first reply", "second reply"]},
          {"hello", "implicit quit reply", "", 0, ["implicit quit reply"]},
          {"/help,/quit", "unused reply", "", 1, []}
        ] do
      out = Path.join(cwd, "transcript.txt")

      {output, code} =
        System.cmd(
          "elixir",
          Enum.flat_map(paths, &["-pa", List.to_string(&1)]) ++
            [
              "-e",
              "Application.put_env(:elara, :model_catalog_online, false); " <>
                "{:ok, _} = Application.ensure_all_started(:elara); " <>
                "Code.require_file(hd(System.argv()))",
              "--",
              script
            ],
          env: [
            {"HOME", ctx.home},
            {"ELARA_VERIFY_SESSION_CWD", cwd},
            {"ELARA_VERIFY_OUT", out},
            {"ELARA_VERIFY_LINES", lines},
            {"ELARA_VERIFY_REPLY", reply},
            {"ELARA_VERIFY_REPLIES", replies},
            {"ELARA_VERIFY_PERSIST", "0"},
            {"ELARA_VERIFY_CONTINUE", "0"},
            {"ELARA_VERIFY_NAME", ""}
          ],
          stderr_to_stdout: true
        )

      assert code == status, output
      body = File.read!(out)
      for text <- texts, do: assert(body =~ text)
      refute body =~ "in a turn. /interrupt to cancel."
      refute body =~ "    interrupted\n"
      if status == 1, do: assert(output =~ "expected scripted replies were not completed")
    end
  end
end
