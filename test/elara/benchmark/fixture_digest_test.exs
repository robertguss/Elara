defmodule Elara.Benchmark.FixtureDigestTest do
  use ExUnit.Case, async: false

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()

  test "every selected fixture has stable initial, expected, and content-address digests" do
    for task <- @manifest["tasks"] do
      fixture = task["fixture"]

      assert workspace_digest(fixture["initial_files"]) == fixture["initial_workspace_sha256"]

      assert workspace_digest(fixture["expected_no_fault_files"]) ==
               fixture["expected_no_fault_workspace_sha256"]

      digest_input = %{
        "task_id" => task["id"],
        "initial_files" => fixture["initial_files"],
        "expected_no_fault_files" => fixture["expected_no_fault_files"],
        "plan" => task["plan"]
      }

      assert digest_input |> canonical_json() |> sha256() == fixture["fixture_sha256"]
      assert normalized_unique_paths?(fixture["initial_files"])
      assert normalized_unique_paths?(fixture["expected_no_fault_files"])
    end
  end

  test "write, patch, and shell declarations match their immutable fixture bytes" do
    for task <- @manifest["tasks"] do
      step = hd(task["plan"]["steps"])
      args = step["arguments"]
      expected_files = Map.new(task["fixture"]["expected_no_fault_files"], &{&1["path"], &1})

      case step["operation_kind"] do
        "write" ->
          declarations = step["frozen_declarations"]
          assert sha256(declarations["desired_postimage_content"]) == args["desired"]["sha256"]

          assert expected_files[args["path"]]["content"] ==
                   declarations["desired_postimage_content"]

          case args["expected"]["state"] do
            "absent" ->
              assert declarations["expected_preimage_state"] == "absent"

            "regular" ->
              assert sha256(declarations["expected_preimage_content"]) ==
                       args["expected"]["sha256"]
          end

        "patch" ->
          declarations = step["frozen_declarations"]
          preimage = declarations["preimage_content"]
          postimage = declarations["postimage_content"]

          assert sha256(preimage) == args["preimage_sha256"]
          assert sha256(postimage) == args["postimage_sha256"]
          assert count_occurrences(preimage, args["old_text"]) == 1

          assert String.replace(preimage, args["old_text"], args["new_text"], global: false) ==
                   postimage

          if step["expected_no_fault_outcome"] == "ok" do
            assert expected_files[args["path"]]["content"] == postimage
          else
            refute expected_files[args["path"]]["content"] in [preimage, postimage]
          end

        "shell" ->
          refute String.contains?(args["command"], "curl ")
          refute String.contains?(args["command"], "wget ")

          if args["postcondition"] do
            for declared <- args["postcondition"]["files"] do
              assert sha256(expected_files[declared["path"]]["content"]) == declared["sha256"]
            end
          else
            assert task["id"] == "S04"
            assert step["expected_undeclared_artifacts"] == ["_build/"]
          end
      end
    end
  end

  test "every expected no-fault workspace materializes as an offline passing Mix project" do
    root =
      Path.join(System.tmp_dir!(), "elara-exp003-fixtures-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for task <- @manifest["tasks"] do
      cwd = Path.join(root, String.downcase(task["id"]))
      materialize!(cwd, task["fixture"]["expected_no_fault_files"])

      {output, status} =
        System.cmd("mix", ["test"],
          cd: cwd,
          env: [{"HEX_OFFLINE", "1"}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, "#{task["id"]} expected fixture failed offline:\n#{output}"
      assert output =~ "Result: 1 passed"
    end
  end

  defp materialize!(cwd, files) do
    for %{"path" => path, "mode" => mode, "content" => content} <- files do
      target = Path.join(cwd, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
      File.chmod!(target, mode |> String.to_integer(8))
    end
  end

  defp workspace_digest(files) do
    body =
      files
      |> Enum.sort_by(& &1["path"])
      |> Enum.map(fn file ->
        content = file["content"]

        [
          file["path"],
          <<0>>,
          file["mode"],
          <<0>>,
          Integer.to_string(byte_size(content)),
          <<0>>,
          content,
          <<0>>
        ]
      end)

    ["elara.workspace.v1", <<0>>, body]
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp normalized_unique_paths?(files) do
    paths = Enum.map(files, & &1["path"])

    Enum.uniq(paths) == paths and
      Enum.all?(paths, fn path ->
        path == Path.relative_to(path, ".") and
          path != "." and
          not String.starts_with?(path, "/") and
          not String.contains?(path, ["../", <<0>>])
      end)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> canonical_json(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: JSON.encode!(value)

  defp count_occurrences(content, needle) do
    content
    |> :binary.matches(needle)
    |> length()
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
