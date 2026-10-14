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
end
