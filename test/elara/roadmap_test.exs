defmodule Elara.RoadmapTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @hub "https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1"
  @retired "https://linear.app/robert-guss/project/elara-7ee4b27c1215"

  test "current planning guidance points to the Notion hub, not Linear" do
    for path <- [
          "ROADMAP.md",
          "HANDOFF.md",
          "AGENTS.md",
          "CLAUDE.md",
          "README.md",
          "MANUAL_TEST_CHECKLIST.md"
        ] do
      contents = File.read!(Path.join(@root, path))
      assert contents =~ @hub, "#{path} must link the Elara Notion hub"
      refute contents =~ @retired, "#{path} must not send readers to the retired Linear project"
      refute contents =~ "linear.app", "#{path} must not link Linear, which is retired"
      refute contents =~ "`ROADMAP.md` is the sole"
      refute contents =~ "`ROADMAP.md` is the **sole**"
    end
  end

  test "legacy entry points are pointers, not a second queue or handoff" do
    roadmap = File.read!(Path.join(@root, "ROADMAP.md"))
    handoff = File.read!(Path.join(@root, "HANDOFF.md"))

    refute roadmap =~ "## Execution queue"
    refute roadmap =~ "## LAB-"
    refute handoff =~ "## 6. Remaining work"
    assert roadmap =~ "docs/lab/"
    assert roadmap =~ "lab/results/"
    assert roadmap =~ "docs/archive/linear/"
  end

  test "the Linear archive is in the repository" do
    index = File.read!(Path.join(@root, "docs/archive/linear/README.md"))

    for folder <- ["2026-10-elara", "2026-08-elara-er-1"] do
      assert index =~ folder
      assert File.regular?(Path.join([@root, "docs/archive/linear", folder, "project.md"]))
    end

    assert File.regular?(Path.join(@root, "docs/archive/linear/2026-10-elara/issues/ROB-1083.md"))
  end

  test "repository guidance supports work in the current session" do
    claude = File.read!(Path.join(@root, "CLAUDE.md"))
    agents = File.read!(Path.join(@root, "AGENTS.md"))

    assert claude =~ "Notion: Dev Hub → Projects → Elara"
    assert agents =~ "The active agent owns planning"
    assert agents =~ "current session"

    for path <- ["AGENTS.md", "CLAUDE.md", "HANDOFF.md"] do
      contents = File.read!(Path.join(@root, path))

      refute contents =~ "amp-workflow", "#{path} must not mention amp-workflow"
      refute contents =~ "Amp review", "#{path} must not mention Amp review"
      refute contents =~ "`crew`", "#{path} must not require the retired skill"
      refute contents =~ "## Crew", "#{path} must not configure the retired workflow"
    end
  end
end
