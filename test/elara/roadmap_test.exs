defmodule Elara.RoadmapTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @roadmap Path.join(@root, "ROADMAP.md")
  @statuses ["TODO", "IN PROGRESS", "BLOCKED", "DONE", "CANCELED", "INVALID", "DEFERRED"]
  @executable ["TODO", "IN PROGRESS"]

  test "the queue uses allowed statuses and has exactly one executable item" do
    rows = table("Execution queue")
    ids = Enum.map(rows, &hd/1)
    statuses = Enum.map(rows, &Enum.at(&1, 1))

    assert rows != []
    assert ids == Enum.uniq(ids)
    assert Enum.all?(statuses, &(&1 in @statuses))
    assert Enum.count(statuses, &(&1 == "IN PROGRESS")) <= 1

    open? = Enum.any?(statuses, &(&1 in ["TODO", "IN PROGRESS", "BLOCKED"]))
    assert Enum.count(statuses, &(&1 in @executable)) == if(open?, do: 1, else: 0)
  end

  test "every queued item has a section and depends on known items" do
    rows = table("Execution queue")
    ids = MapSet.new(rows, &hd/1)
    headings = roadmap_lines() |> Enum.filter(&String.starts_with?(&1, "## "))

    for [id, _status, _item, depends_on] <- rows do
      assert Enum.any?(headings, &String.starts_with?(&1, "## #{id} — ")),
             "#{id} has no \"## #{id} — …\" section"

      for dependency <- String.split(depends_on, ",", trim: true) do
        dependency = String.trim(dependency)

        assert dependency == "Lab pivot" or MapSet.member?(ids, dependency),
               "#{id} depends on unknown item #{dependency}"
      end
    end
  end

  test "history rows use allowed statuses" do
    rows = table("History")

    assert rows != []
    assert Enum.all?(rows, fn [_id, status | _rest] -> status in @statuses end)
    refute Enum.any?(rows, fn [_id, status | _rest] -> status in @executable end)
  end

  test "repository documentation points to the repository roadmap" do
    readme = File.read!(Path.join(@root, "README.md"))
    agents = File.read!(Path.join(@root, "AGENTS.md"))

    assert readme =~ "[Roadmap](ROADMAP.md)"
    assert agents =~ "`ROADMAP.md` is the sole current roadmap"
  end

  defp roadmap_lines, do: @roadmap |> File.read!() |> String.split("\n")

  defp table(section) do
    roadmap_lines()
    |> Enum.drop_while(&(&1 != "## #{section}"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(fn row -> row |> String.split("|", trim: true) |> Enum.map(&String.trim/1) end)
    |> Enum.reject(fn [first | _rest] -> first == "ID" or first =~ ~r/^-+$/ end)
  end
end
