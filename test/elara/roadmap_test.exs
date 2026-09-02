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

  test "the roadmap has at most one executable item in dependency order" do
    rows =
      @roadmap
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| ER3-V8-"))
      |> Enum.map(fn row ->
        row
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.at(2)
      end)

    assert length(rows) == 7
    assert Enum.count(rows, &(&1 == "IN PROGRESS")) <= 1
    assert Enum.count(rows, &(&1 == "TODO")) <= 1
    assert Enum.count(rows, &(&1 in ["IN PROGRESS", "TODO"])) <= 1

    first_unfinished = Enum.find_index(rows, &(&1 != "DONE")) || length(rows)
    assert Enum.all?(Enum.take(rows, first_unfinished), &(&1 == "DONE"))

    case Enum.find_index(rows, &(&1 in ["IN PROGRESS", "TODO"])) do
      nil ->
        case Enum.drop(rows, first_unfinished) do
          ["INVALID" | canceled] -> assert Enum.all?(canceled, &(&1 == "CANCELED"))
          blocked -> assert Enum.all?(blocked, &(&1 == "BLOCKED"))
        end

      active ->
        assert Enum.all?(Enum.drop(rows, active + 1), &(&1 == "BLOCKED"))
    end
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
