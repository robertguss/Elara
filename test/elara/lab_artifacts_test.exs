defmodule Elara.Lab.ArtifactsTest do
  use ExUnit.Case, async: false
  alias Elara.Lab.Artifacts

  test "frozen source/build/native bytes and loaded BEAM code match their independent manifest" do
    repo = Path.expand("../..", __DIR__)
    snapshot = Artifacts.snapshot(repo) |> JSON.encode!() |> JSON.decode!()
    assert snapshot["schema"] == 1
    assert snapshot["files"][Application.app_dir(:elara, "priv/native/exec-stub")] != nil
    assert Artifacts.verify(snapshot).verified

    file = Application.app_dir(:elara, "priv/native/exec-stub")
    changed = put_in(snapshot, ["files", file], "wrong-native-hash")
    refute Artifacts.verify(changed).verified
    assert Artifacts.verify(changed).changed_files == [file]
    refute Artifacts.verify(put_in(snapshot, ["files", file], nil)).verified
    refute Artifacts.verify(Map.put(snapshot, "schema", 2)).verified

    [first | rest] = snapshot["modules"]
    changed = Map.put(snapshot, "modules", [Map.put(first, "md5", "stale-beam") | rest])
    refute Artifacts.verify(changed).verified
    assert Artifacts.verify(changed).changed_modules == [first["module"]]

    changed = put_in(snapshot, ["source", "commit"], "other-source")
    refute Artifacts.verify(changed).source_matches
  end

  test "a Git excludes file cannot hide an untracked runtime source from the fingerprint" do
    root = Path.join(System.tmp_dir!(), "elara-artifacts-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(repo, "fixture.ex"), "defmodule Fixture do end\n")
    assert {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    assert {_, 0} = System.cmd("git", ["add", "fixture.ex"], cd: repo)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "commit.gpgsign=false",
                 "-c",
                 "user.name=Fixture",
                 "-c",
                 "user.email=fixture@example.invalid",
                 "commit",
                 "-qm",
                 "fixture"
               ],
               cd: repo
             )

    assert Artifacts.snapshot(repo).source.dirty == false
    excludes = Path.join(root, "excludes")
    File.write!(excludes, "untracked-runtime.ex\n")
    File.write!(Path.join(repo, "untracked-runtime.ex"), "defmodule UntrackedRuntime do end\n")
    assert {_, 0} = System.cmd("git", ["config", "core.excludesFile", excludes], cd: repo)
    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: repo)
    assert Artifacts.snapshot(repo).source.dirty == true
  end
end
