defmodule Elara.RoadmapTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @roadmap Path.join(@root, "ROADMAP.md")

  test "the roadmap has at most one executable item" do
    rows =
      @roadmap
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/^\| (?:PROD|SPLIT)-\d+ /, &1))
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

    assert Enum.map(rows, &elem(&1, 0)) ==
             ["PROD-1", "PROD-2", "SPLIT-1", "SPLIT-2", "SPLIT-3", "SPLIT-4", "SPLIT-5"]

    assert Enum.all?(rows, fn {_id, status} ->
             status in ["TODO", "IN PROGRESS", "BLOCKED", "DONE", "CANCELED", "INVALID"]
           end)
  end

  test "repository documentation points to the repository roadmap" do
    readme = File.read!(Path.join(@root, "README.md"))
    agents = File.read!(Path.join(@root, "AGENTS.md"))

    assert readme =~ "[Roadmap](ROADMAP.md)"
    assert agents =~ "`ROADMAP.md` is the sole current roadmap"
  end
end
