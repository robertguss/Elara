defmodule Elara.MCP.Trust do
  @moduledoc "Separate exact-config and catalog approvals; remote annotations grant no read-only authority."

  alias Elara.MCP.Config

  def check_config(%Config{} = config) do
    if File.read(path(config, "config")) == {:ok, config.sha256},
      do: :ok,
      else: {:error, :mcp_config_approval_required}
  end

  def approve_config(%Config{} = config), do: save(path(config, "config"), config.sha256)

  def approve_catalog(%Config{} = config, tools, read_only) do
    names = Enum.map(tools, & &1["name"])

    if is_list(read_only) and Enum.all?(read_only, &(&1 in names)) do
      marks = Enum.sort(Enum.uniq(read_only))

      save(
        path(config, "catalog"),
        JSON.encode!(%{"digest" => digest(tools, marks), "read_only" => marks})
      )
    else
      {:error, :unknown_read_only_tool}
    end
  end

  def check_catalog(%Config{} = config, tools) do
    with {:ok, bytes} <- File.read(path(config, "catalog")),
         {:ok, %{"digest" => expected, "read_only" => marks}} <- JSON.decode(bytes),
         true <- is_list(marks) and Enum.all?(marks, &is_binary/1),
         true <- expected == digest(tools, marks) do
      {:ok, marks}
    else
      _ -> {:error, :mcp_catalog_approval_required}
    end
  end

  def digest(tools, marks) do
    canonical(%{
      "version" => 1,
      "tools" => Enum.sort_by(tools, & &1["name"]),
      "read_only" => Enum.sort(Enum.uniq(marks))
    })
    |> IO.iodata_to_binary()
    |> hash()
  end

  defp canonical(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", canonical(value)] end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp canonical(list) when is_list(list),
    do: ["[", Enum.intersperse(Enum.map(list, &canonical/1), ","), "]"]

  defp canonical(value), do: JSON.encode!(value)

  defp path(config, kind),
    do:
      Path.join(
        root(),
        hash(JSON.encode!([config.path, config.name, config.sha256])) <> "." <> kind
      )

  defp root,
    do:
      Application.get_env(
        :elara,
        :mcp_trust_root,
        Path.join(System.user_home!(), ".elara/mcp-trust")
      )

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp save(destination, bytes) do
    tmp = destination <> ".tmp.#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(root()),
           :ok <- File.chmod(root(), 0o700),
           :ok <- File.write(tmp, bytes),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, destination),
           do: :ok

    File.rm(tmp)
    result
  end
end
