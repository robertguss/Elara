defmodule Elara.WorkspaceSearchTest do
  use ExUnit.Case, async: true

  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Elara.Tools.Search

  @moduletag :requires_app
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    dir = Path.join(root, "work space")

    for path <- [
          "lib/nested dir",
          "_build/lib",
          "node_modules/pkg",
          ".git/objects",
          "ignored_dir"
        ],
        do: File.mkdir_p!(Path.join(dir, path))

    File.write!(Path.join(dir, ".gitignore"), "*.log\nignored_dir/\n")
    File.write!(Path.join(dir, "lib/alpha.ex"), "defmodule Alpha do\n  @needle true\nend\n")
    File.write!(Path.join(dir, "lib/nested dir/beta file.ex"), "# needle in a spaced path\n")
    File.write!(Path.join(dir, "notes.md"), "no match here\n")
    File.write!(Path.join(dir, "skipped.log"), "needle in an ignored file\n")
    File.write!(Path.join(dir, "ignored_dir/inside.ex"), "needle in an ignored directory\n")
    File.write!(Path.join(dir, "_build/lib/stale.ex"), "needle in build output\n")
    File.write!(Path.join(dir, "node_modules/pkg/index.js"), "needle in dependencies\n")
    File.write!(Path.join(dir, ".git/objects/blob"), "needle in version control\n")
    File.write!(Path.join(dir, "payload.bin"), <<"needle", 0, 0, 0, "tail">>)

    %{ctx: %Ctx{cwd: dir}, dir: dir}
  end

  defp lines({:ok, output}), do: String.split(output, "\n")

  @matches [
    "lib/alpha.ex:2:  @needle true",
    "lib/nested dir/beta file.ex:1:# needle in a spaced path"
  ]

  test "grep returns deterministic path:line:text for matches, including spaced paths", %{
    ctx: ctx
  } do
    result = Search.grep(%{"pattern" => "needle"}, ctx)

    assert lines(result) == @matches
    assert Search.grep(%{"pattern" => "needle"}, ctx) == result
  end

  test "grep reports no matches without inventing output", %{ctx: ctx} do
    assert Search.grep(%{"pattern" => "absent-token"}, ctx) == {:ok, "no matches"}
  end

  test "grep skips ignored paths, VCS metadata, build output and binary files", %{
    ctx: ctx,
    dir: dir
  } do
    # An unframed binary diagnostic must not become the next match's filename.
    File.write!(Path.join(dir, "a.bin"), <<"needle", 0, "tail">>)
    File.write!(Path.join(dir, "odd:name\nnotes.md"), "needle unusual filename\n")

    {:ok, output} = Search.grep(%{"pattern" => "needle"}, ctx)

    assert output ==
             Enum.join(@matches ++ ["odd:name\nnotes.md:1:needle unusual filename"], "\n")

    for excluded <- [
          "a.bin",
          "skipped.log",
          "ignored_dir",
          "_build",
          "node_modules",
          ".git/",
          "payload.bin"
        ],
        do: refute(output =~ excluded, "#{excluded} leaked into results")
  end

  test "grep cannot attribute a binary diagnostic to a similarly named text file", %{dir: dir} do
    scope = Path.join(dir, "ambiguous")
    File.mkdir_p!(scope)
    File.write!(Path.join(scope, "a.bin"), <<"needle", 0, "tail">>)
    File.write!(Path.join(scope, "notes.md"), "needle real\n")

    File.write!(
      Path.join(
        scope,
        "a.bin: binary file matches (found \"\\0\" byte around offset 6)\nnotes.md"
      ),
      "absent\n"
    )

    assert Search.grep(%{"pattern" => "needle"}, %Ctx{cwd: scope}) ==
             {:ok, "notes.md:1:needle real"}
  end

  test "non-UTF-8 filenames refuse without crashing the command runner", %{ctx: ctx, dir: dir} do
    path = Path.join(dir, "bad" <> <<255>> <> ".txt")
    File.write!(path, "needle\n")
    File.ln_s!(path, Path.join(dir, "bad-alias.txt"))
    error = {:error, "search requires UTF-8 filenames; narrow the path"}

    assert Search.grep(%{"pattern" => "needle"}, ctx) == error
    assert Search.glob(%{"pattern" => "**/*"}, ctx) == error

    for tool <- [&Search.grep/2, &Search.glob/2] do
      assert {:error, _} = tool.(%{"pattern" => "needle", "path" => "bad-alias.txt"}, ctx)
    end

    assert Search.grep(%{"pattern" => "needle", "path" => "lib"}, ctx) |> lines() == @matches
  end

  test "grep never dumps bytes from a binary-only workspace", %{ctx: ctx, dir: dir} do
    for path <- ["lib", "notes.md", "skipped.log"], do: File.rm_rf!(Path.join(dir, path))

    assert Search.grep(%{"pattern" => "needle"}, ctx) == {:ok, "no matches"}
  end

  test "grep honours the glob filter, case folding and a scoping path", %{ctx: ctx} do
    assert Search.grep(%{"pattern" => "needle", "glob" => "**/*.md"}, ctx) == {:ok, "no matches"}

    assert Search.grep(
             %{"pattern" => "NEEDLE", "case_insensitive" => true, "glob" => "*.ex"},
             ctx
           )
           |> lines() == @matches

    assert Search.grep(%{"pattern" => "needle", "path" => "lib/nested dir"}, ctx) ==
             {:ok, "lib/nested dir/beta file.ex:1:# needle in a spaced path"}

    assert Search.grep(%{"pattern" => "needle", "path" => "lib/"}, ctx) |> lines() == @matches
    assert Search.grep(%{"pattern" => "needle", "path" => "."}, ctx) |> lines() == @matches
  end

  test "grep caps the number of matches and says so", %{ctx: ctx, dir: dir} do
    File.write!(Path.join(dir, "lib/many.ex"), String.duplicate("needle\n", 40))

    {:ok, output} = Search.grep(%{"pattern" => "needle", "limit" => 3}, ctx)
    shown = String.split(output, "\n")

    assert length(shown) == 4
    assert List.last(shown) == "[truncated at the 3-matches cap; narrow the pattern or path]"
    assert Enum.all?(Enum.take(shown, 3), &(&1 =~ "needle"))
  end

  test "grep bounds output at the session byte cap without a partial last line", %{
    ctx: ctx,
    dir: dir
  } do
    File.write!(Path.join(dir, "lib/wide.ex"), String.duplicate("needle padding\n", 400))
    complete = lines(Search.grep(%{"pattern" => "needle", "limit" => 1_000}, ctx))

    {:ok, output} =
      Search.grep(
        %{"pattern" => "needle", "limit" => 1_000},
        %Ctx{cwd: dir, max_output_bytes: 1_024}
      )

    {notice, shown} = output |> String.split("\n") |> List.pop_at(-1)

    assert notice == "[truncated at the output byte cap; narrow the pattern or path]"
    assert byte_size(output) < 2_048
    assert length(shown) > 1
    assert length(shown) < length(complete)
    # A byte cap kills ripgrep mid-write, so prove every retained line is whole.
    assert shown == Enum.take(complete, length(shown))

    File.write!(Path.join(dir, "lib/wide.ex"), "needle" <> String.duplicate("x", 500) <> "\n")

    assert Search.grep(%{"pattern" => "needle", "path" => "lib/wide.ex"}, ctx) ==
             {:ok,
              "lib/wide.ex:1:needle" <>
                String.duplicate("x", 394) <> " [... omitted end of long line]"}
  end

  test "an unusable pattern reports ripgrep's diagnosis as an error", %{ctx: ctx} do
    assert {:error, message} = Search.grep(%{"pattern" => "needle("}, ctx)
    assert message =~ "search failed (exit 2)"
    assert message =~ "regex parse error"

    File.mkdir_p!(Path.join(ctx.cwd, "empty"))

    assert {:error, empty_message} =
             Search.grep(%{"pattern" => "needle(", "path" => "empty"}, ctx)

    assert empty_message =~ "regex parse error"

    assert {:error, glob_message} = Search.glob(%{"pattern" => "lib/["}, ctx)
    assert glob_message =~ "search failed (exit 2)"
    assert glob_message =~ "error parsing glob"
  end

  test "paths escaping the workspace are rejected before any search runs", %{ctx: ctx, dir: dir} do
    outside = Path.join(Path.dirname(dir), "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.ex"), "needle outside the workspace\n")

    for path <- ["..", "../outside", "../", outside, "/etc", "lib/../../outside", "/"] do
      assert {:error, message} = Search.grep(%{"pattern" => "needle", "path" => path}, ctx)
      assert message == "file access refused: path_outside_workspace", "accepted #{inspect(path)}"
      assert {:error, _} = Search.glob(%{"pattern" => "**/*.ex", "path" => path}, ctx)
    end

    assert {:error, message} = Search.glob(%{"pattern" => "**/*.ex", "path" => "missing"}, ctx)
    assert message =~ "does not exist in the workspace"
  end

  test "glob lists matching workspace paths in sorted order", %{ctx: ctx} do
    assert Search.glob(%{"pattern" => "**/*.ex"}, ctx) |> lines() == [
             "lib/alpha.ex",
             "lib/nested dir/beta file.ex"
           ]

    assert Search.glob(%{"pattern" => "*.md"}, ctx) == {:ok, "notes.md"}
    assert Search.glob(%{"pattern" => "*.nope"}, ctx) == {:ok, "no files"}

    assert Search.glob(%{"pattern" => "**/*", "path" => "lib/nested dir"}, ctx) ==
             {:ok, "lib/nested dir/beta file.ex"}

    for path <- ["-", "--follow"] do
      File.write!(Path.join(ctx.cwd, path), "operand_marker\n")

      assert Search.grep(%{"pattern" => "operand_marker", "path" => path}, ctx) ==
               {:ok, "#{path}:1:operand_marker"}

      assert Search.glob(%{"pattern" => "**/*", "path" => path}, ctx) == {:ok, path}
    end
  end

  test "ripgrep's documented glob precedence over ignore files stays deliberate", %{ctx: ctx} do
    # A pattern naming an ignored file reaches it; an ignored directory stays
    # pruned unless the pattern matches the directory path itself.
    assert Search.glob(%{"pattern" => "**/*.log"}, ctx) == {:ok, "skipped.log"}
    assert Search.glob(%{"pattern" => "ignored_dir/**"}, ctx) == {:ok, "no files"}

    assert Search.glob(%{"pattern" => "**/*"}, ctx) |> lines() |> Enum.member?("skipped.log")

    # Built-in directory exclusions are listed last, so they always win.
    for pattern <- ["**/*", "_build/**", "node_modules/**", ".git/**"] do
      refute Search.glob(%{"pattern" => pattern}, ctx) |> lines() |> Enum.any?(&(&1 =~ "_build"))
    end
  end

  test "glob caps the listing and says so", %{ctx: ctx, dir: dir} do
    for index <- 1..10, do: File.write!(Path.join(dir, "lib/gen#{index}.ex"), "\n")

    {:ok, output} = Search.glob(%{"pattern" => "**/*.ex", "limit" => 2}, ctx)
    shown = String.split(output, "\n")

    assert length(shown) == 3
    assert List.last(shown) == "[truncated at the 2-files cap; narrow the pattern or path]"
  end

  test "grep preserves ordering and one output budget across many files", %{ctx: ctx, dir: dir} do
    File.mkdir_p!(Path.join(dir, "many"))

    paths =
      for index <- 0..128, do: "many/#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"

    for path <- paths, do: File.write!(Path.join(dir, path), "absent\n")
    File.write!(Path.join(dir, hd(paths)), "unique_marker first\n")
    File.write!(Path.join(dir, List.last(paths)), String.duplicate("unique_marker last\n", 100))

    expected =
      ["many/000.ex:1:unique_marker first"] ++
        for line <- 1..100, do: "many/128.ex:#{line}:unique_marker last"

    assert lines(Search.grep(%{"pattern" => "unique_marker", "limit" => 200}, ctx)) == expected

    {:ok, output} =
      Search.grep(%{"pattern" => "unique_marker", "limit" => 200}, %{ctx | max_output_bytes: 1024})

    {notice, shown} = output |> String.split("\n") |> List.pop_at(-1)
    assert notice == "[truncated at the output byte cap; narrow the pattern or path]"
    assert byte_size(Enum.join(shown, "\n")) <= 1024
    assert length(shown) > 1
    assert shown == Enum.take(expected, length(shown))
  end

  test "argument validation rejects malformed calls", %{ctx: ctx} do
    assert Search.grep(%{}, ctx) == {:error, "grep requires pattern"}
    assert Search.glob(%{}, ctx) == {:error, "glob requires pattern"}
    assert Search.grep(%{"pattern" => 7}, ctx) == {:error, "grep requires pattern"}
    assert Search.grep(%{"pattern" => ""}, ctx) == {:error, "search pattern must not be empty"}
    assert Search.glob(%{"pattern" => ""}, ctx) == {:error, "search pattern must not be empty"}

    for value <- [0, -1, 1.0, "3", nil, 1_001] do
      assert {:error, message} = Search.grep(%{"pattern" => "needle", "limit" => value}, ctx)
      assert message =~ "limit must be an integer from 1 to 1000"
      assert {:error, _} = Search.glob(%{"pattern" => "*", "limit" => value}, ctx)
    end

    assert {:error, message} = Search.grep(%{"pattern" => "n", "case_insensitive" => "yes"}, ctx)
    assert message =~ "case_insensitive must be a boolean"
    assert {:error, _} = Search.grep(%{"pattern" => "n", "glob" => ""}, ctx)
    assert {:error, _} = Search.grep(%{"pattern" => "n", "path" => 7}, ctx)
  end

  test "both tools are advertised read-only with search schemas" do
    for name <- ["grep", "glob"] do
      tool = Enum.find(Tool.builtins(), &(&1.name == name))

      assert tool.capabilities == ["filesystem:read"]
      refute tool.mutating
      assert tool.parameters["required"] == ["pattern"]
      assert tool.parameters["properties"]["limit"]["maximum"] == 1_000
      assert tool.description =~ ".gitignore"
      assert tool.description =~ "ripgrep"
    end

    assert Enum.find(Tool.builtins(), &(&1.name == "grep")).run == {Search, :grep}
    assert Enum.find(Tool.builtins(), &(&1.name == "glob")).run == {Search, :glob}
  end
end
