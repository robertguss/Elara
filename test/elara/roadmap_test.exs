defmodule Elara.RoadmapTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @project "https://linear.app/robert-guss/project/elara-7ee4b27c1215"
  @handoff "https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd"

  test "current planning guidance points to the same Linear project" do
    for path <- [
          "ROADMAP.md",
          "AGENTS.md",
          "CLAUDE.md",
          "README.md",
          "MANUAL_TEST_CHECKLIST.md"
        ] do
      contents = File.read!(Path.join(@root, path))
      assert contents =~ @project, "#{path} must link the Elara Linear project"
      refute contents =~ "`ROADMAP.md` is the sole"
      refute contents =~ "`ROADMAP.md` is the **sole**"
    end
  end

  test "legacy entry points are pointers, not a second queue or handoff" do
    roadmap = File.read!(Path.join(@root, "ROADMAP.md"))
    handoff = File.read!(Path.join(@root, "HANDOFF.md"))

    assert handoff =~ @handoff
    refute roadmap =~ "## Execution queue"
    refute roadmap =~ "## LAB-"
    refute handoff =~ "## 6. Remaining work"
    assert roadmap =~ "docs/lab/"
    assert roadmap =~ "lab/results/"
  end

  test "repository guidance uses the crew loop" do
    claude = File.read!(Path.join(@root, "CLAUDE.md"))

    assert claude =~ "## Crew", "CLAUDE.md must configure the crew skill"
    assert claude =~ "Linear: team ROB, project Elara"

    for path <- ["AGENTS.md", "CLAUDE.md", "HANDOFF.md"] do
      contents = File.read!(Path.join(@root, path))

      refute contents =~ "amp-workflow", "#{path} must not mention amp-workflow"
      refute contents =~ "Amp review", "#{path} must not mention Amp review"
    end
  end
end
