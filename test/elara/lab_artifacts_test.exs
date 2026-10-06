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
end
