defmodule Elara.RoadmapTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @roadmap Path.join(@root, "docs/roadmap.md")
  @history Path.join(@root, "docs/roadmap-history.md")

  test "the migrated archive preserves 81 explicit issue statuses" do
    history = File.read!(@history)

    linked_ids =
      ~r{https://linear\.app/robert-guss/issue/(ROB-\d+)}
      |> Regex.scan(history, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    status_rows =
      ~r/^\| \[(ROB-\d+)\]\([^\n]+\)\s*\|\s*(Done|Canceled)\s*\|/m
      |> Regex.scan(history, capture: :all_but_first)

    assert length(linked_ids) == 81
    assert length(status_rows) == 81
    assert status_rows |> Enum.map(&hd/1) |> Enum.uniq() |> length() == 81
  end

  test "the roadmap preserves closed V8 and has at most one executable item" do
    rows =
      @roadmap
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/^\| (?:PROD|ER3-V8)-\d+ /, &1))
      |> Enum.map(fn row ->
        [id, status | _rest] =
          row
          |> String.split("|", trim: true)
          |> Enum.map(&String.trim/1)

        {id, status}
      end)

    assert Enum.count(rows, fn {_id, status} -> status == "IN PROGRESS" end) <= 1
    assert Enum.count(rows, fn {_id, status} -> status == "TODO" end) <= 1

    assert Enum.count(rows, fn {_id, status} -> status in ["IN PROGRESS", "TODO"] end) <=
             1

    assert Enum.filter(rows, fn {id, _status} -> String.starts_with?(id, "PROD-") end) ==
             [{"PROD-1", "TODO"}]

    assert rows
           |> Enum.filter(fn {id, _status} -> String.starts_with?(id, "ER3-V8-") end)
           |> Enum.map(fn {_id, status} -> status end) ==
             ["DONE", "DONE", "DONE", "INVALID", "CANCELED", "CANCELED", "CANCELED"]
  end

  test "repository documentation points to the repository roadmap" do
    readme = File.read!(Path.join(@root, "README.md"))
    agents = File.read!(Path.join(@root, "AGENTS.md"))
    retired = File.read!(Path.join(@root, "design/beam-runtime-roadmap.md"))

    assert readme =~ "[Elara roadmap](docs/roadmap.md)"
    assert agents =~ "`docs/roadmap.md` is the sole current roadmap"
    assert retired =~ "[canonical Elara roadmap](../docs/roadmap.md)"
  end
end
