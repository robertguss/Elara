defmodule Elara.SkillsTest do
  use ExUnit.Case, async: true

  alias Elara.Skills

  setup do
    root = Path.join(System.tmp_dir!(), "elara-skills-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "repo/work/nested")
    home = Path.join(root, "home")
    File.mkdir_p!(cwd)
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(root, "repo/.git"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, repo: Path.join(root, "repo"), cwd: cwd, home: home}
  end

  test "parses genuine quoted and folded YAML without retaining the body", ctx do
    container = Path.join(ctx.root, "skills")

    path =
      skill(
        container,
        "reviewing-code",
        """
        description: >-
          Reviews code: safely and consistently.
          Use when reviewing changes.
        license: "Apache-2.0"
        compatibility: "Requires git >= 2"
        metadata:
          author: "example-org"
          version: "1.0"
        """,
        "SECRET INSTRUCTION BODY"
      )

    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [container])
    entry = catalog.skills["reviewing-code"]

    assert entry.description ==
             "Reviews code: safely and consistently. Use when reviewing changes."

    assert entry.compatibility == "Requires git >= 2"
    assert entry.metadata == %{"author" => "example-org", "version" => "1.0"}
    assert entry.path == Path.expand(path)
    refute inspect(catalog) =~ "SECRET INSTRUCTION BODY"

    summary = Skills.summary(catalog)
    assert summary =~ "metadata only"
    assert summary =~ "check these dependencies"
    assert summary =~ entry.source
    refute summary =~ "SECRET INSTRUCTION BODY"
  end

  test "loads the selected file afresh and provides safe resource guidance", ctx do
    container = Path.join(ctx.root, "skills")
    path = skill(container, "using-fixtures", "description: Uses fixtures when testing.", "FIRST")
    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [container])

    File.write!(
      path,
      valid("using-fixtures", "description: Uses fixtures when testing.", "SECOND")
    )

    assert {:ok, loaded} = Skills.load(catalog, "using-fixtures")
    assert loaded =~ "SECOND"
    refute loaded =~ "FIRST"
    assert loaded =~ "Resource base path: #{Path.dirname(path)}"
    assert loaded =~ "read tool"
    assert loaded =~ "ordinary bash tool"
    assert loaded =~ "does not execute anything independently or change capabilities"

    assert {:error, error} = Skills.load(catalog, "missing")
    assert error =~ "unknown skill"
    File.rm!(path)
    assert {:error, error} = Skills.load(catalog, "using-fixtures")
    assert error =~ "cannot load skill"
  end

  test "reports malformed metadata, unsupported fields, ignored allowed-tools, and explicit paths",
       ctx do
    container = Path.join(ctx.root, "skills")
    bad_dir = Path.join(container, "broken-skill")
    File.mkdir_p!(bad_dir)
    File.write!(Path.join(bad_dir, "SKILL.md"), "---\nname: [broken\n---\nbody")

    skill(
      container,
      "vendor-skill",
      """
      description: Uses a vendor integration when requested.
      allowed-tools: Bash(git:*) Read
      vendor-feature: enabled
      """,
      "body"
    )

    missing = Path.join(ctx.root, "does-not-exist")
    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [container, missing])

    refute Map.has_key?(catalog.skills, "broken-skill")
    assert Enum.any?(catalog.diagnostics, &String.contains?(&1, "malformed YAML"))
    assert Enum.any?(catalog.diagnostics, &String.contains?(&1, "unsupported frontmatter field"))
    assert Enum.any?(catalog.diagnostics, &String.contains?(&1, "allowed-tools is ignored"))
    assert Enum.any?(catalog.diagnostics, &String.contains?(&1, missing))
    assert catalog.skills["vendor-skill"].warnings != []
  end

  test "honors explicit, nearest project, farther project, and user priority with sorted children",
       ctx do
    explicit = Path.join(ctx.root, "explicit")
    link_container = Path.join(ctx.root, "linked")
    nearest = Path.join(ctx.cwd, ".agents/skills")
    project = Path.join(ctx.repo, ".agents/skills")
    user = Path.join(ctx.home, ".config/agents/skills")
    legacy = Path.join(ctx.home, ".agents/skills")

    explicit_path = skill(explicit, "same-skill", "description: Explicit copy.", "explicit")
    skill(nearest, "same-skill", "description: Nearest copy.", "nearest")
    skill(project, "same-skill", "description: Project copy.", "project")
    skill(user, "same-skill", "description: User copy.", "user")
    skill(legacy, "same-skill", "description: Legacy copy.", "legacy")
    File.mkdir_p!(link_container)
    File.ln_s!(Path.dirname(explicit_path), Path.join(link_container, "same-skill"))

    catalog =
      Skills.discover(ctx.cwd,
        home: ctx.home,
        skill_paths: [explicit, link_container]
      )

    assert catalog.skills["same-skill"].path == explicit_path
    duplicate = Enum.filter(catalog.diagnostics, &String.contains?(&1, "duplicate skill"))
    assert length(duplicate) == 5

    assert Enum.all?(
             duplicate,
             &(&1 =~ "selected explicit:#{explicit_path}" and &1 =~ "shadowed")
           )
  end

  test "accepts an explicit skill directory and exposes the exact tool contract", ctx do
    path = skill(ctx.root, "direct-skill", "description: Direct skill for testing.", "body")
    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [Path.dirname(path)])
    assert Map.has_key?(catalog.skills, "direct-skill")

    tool = Skills.tool()
    assert tool.name == "skill"
    assert tool.run == {Elara.Skills, :load}
    assert tool.capabilities == ["filesystem:read"]
    assert tool.placement == :local
    assert tool.parameters["required"] == ["name"]
  end

  test "validates portable field constraints and refuses a changed malformed file", ctx do
    for {field, value} <- [
          {"name", "Wrong-Name"},
          {"name", "bad--name"},
          {"name", String.duplicate("a", 65)},
          {"description", "''"},
          {"description", String.duplicate("a", 1025)},
          {"compatibility", "[]"},
          {"license", "[]"},
          {"metadata", "{version: 1}"}
        ] do
      directory = Path.join(ctx.root, "valid-name")
      File.mkdir_p!(directory)
      fields = %{"name" => "valid-name", "description" => "Checks fixtures when testing."}
      yaml = fields |> Map.put(field, value) |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)
      File.write!(Path.join(directory, "SKILL.md"), "---\n#{yaml}\n---\nbody")
      catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [directory])
      assert catalog.skills == %{}, "accepted invalid #{field}: #{value}"
      assert Enum.any?(catalog.diagnostics, &String.contains?(&1, field))
    end

    path = skill(ctx.root, "loading-safely", "description: Loads fixtures when testing.", "body")
    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [Path.dirname(path)])
    File.write!(path, "not frontmatter")
    assert {:error, message} = Skills.load(catalog, "loading-safely")
    assert message =~ "frontmatter"
    File.rm!(path)
    File.mkdir!(path)
    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [Path.dirname(path)])
    assert catalog.skills == %{}
    assert Enum.any?(catalog.diagnostics, &String.contains?(&1, "cannot read"))
  end

  test "nearest project wins without an explicit override and linked resources stay addressable",
       ctx do
    path =
      skill(
        Path.join(ctx.cwd, ".agents/skills"),
        "using-fixtures",
        "description: Nearest.",
        "nearest"
      )

    skill(Path.join(ctx.repo, ".agents/skills"), "using-fixtures", "description: Root.", "root")

    skill(
      Path.join(ctx.home, ".config/agents/skills"),
      "using-fixtures",
      "description: User.",
      "user"
    )

    catalog = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [])
    assert catalog.skills["using-fixtures"].path == path

    link = Path.join(ctx.root, "linked/using-fixtures")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(Path.dirname(path), link)
    File.write!(Path.join(Path.dirname(path), "resource.txt"), "resource")
    linked = Skills.discover(ctx.cwd, home: ctx.home, skill_paths: [link])
    assert {:ok, text} = Skills.load(linked, "using-fixtures")
    assert text =~ "Resource base path: #{link}"

    assert File.read!(Path.join(linked.skills["using-fixtures"].directory, "resource.txt")) ==
             "resource"
  end

  defp skill(container, name, metadata, body) do
    directory = Path.join(container, name)
    path = Path.join(directory, "SKILL.md")
    File.mkdir_p!(directory)
    File.write!(path, valid(name, metadata, body))
    Path.expand(path)
  end

  defp valid(name, metadata, body) do
    "---\nname: #{name}\n#{String.trim(metadata)}\n---\n#{body}\n"
  end
end
