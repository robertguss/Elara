defmodule Elara.Exec.Environment do
  @moduledoc "Command environment policy; operator-named project values never grant Elara credentials."

  @build_names ~w(PATH HOME USER LOGNAME SHELL LANG TERM COLORTERM NO_COLOR SSH_AUTH_SOCK
    TMPDIR TMP TEMP TZ MIX_ENV MIX_TARGET MIX_HOME HEX_HOME MIX_ARCHIVES MIX_PATH
    MIX_BUILD_PATH MIX_DEPS_PATH ERL_LIBS ERL_FLAGS ERL_AFLAGS ELIXIR_ERL_OPTIONS
    CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN RUSTFLAGS CARGO_TARGET_DIR CARGO_BUILD_TARGET
    CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
    PKG_CONFIG_SYSROOT_DIR RIPGREP_CONFIG_PATH)
  @build_prefixes ~w(LC_ MISE_ ASDF_ HOMEBREW_ MIX_ HEX_ ERL_ ELIXIR_)
  @credential_shapes ~w(TOKEN API_KEY KEY PASSWORD SECRET AUTH CREDENTIAL)
  @credential_prefixes ~w(ELARA_ XAI_ EXA_ OPENAI_ CODEX_ GROK_ ANTHROPIC_)
  @credentials ~w(CLAUDE_CODE_OAUTH_TOKEN)

  def command(overrides) do
    environment = System.get_env()

    with {:ok, names} <- allowed_names(environment, Map.keys(overrides)) do
      forbidden = Map.keys(overrides) -- names

      if forbidden == [] do
        {:ok, Map.merge(Map.take(environment, names), overrides)}
      else
        {:error,
         "command environment overrides are not allowed: #{inspect(Enum.sort(forbidden))}"}
      end
    end
  end

  def names do
    environment = System.get_env()

    with {:ok, allowed} <- allowed_names(environment) do
      {forwarded, withheld} = Enum.split_with(Map.keys(environment), &(&1 in allowed))
      {:ok, %{forwarded: Enum.sort(forwarded), withheld: Enum.sort(withheld)}}
    end
  end

  defp allowed_names(environment, candidates \\ []) do
    extras =
      Map.get(environment, "ELARA_COMMAND_ENV", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    if Enum.all?(extras, &Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, &1)) do
      defaults =
        Enum.filter(Map.keys(environment) ++ candidates, fn name ->
          Enum.any?(@build_prefixes, &String.starts_with?(name, &1)) and
            not Enum.any?(@credential_shapes, &String.contains?(String.upcase(name), &1))
        end)

      {:ok,
       (@build_names ++ defaults ++ extras)
       |> Enum.uniq()
       |> Enum.reject(&credential?/1)}
    else
      {:error, "ELARA_COMMAND_ENV must be a comma-separated list of environment variable names"}
    end
  end

  defp credential?(name),
    do: name in @credentials or Enum.any?(@credential_prefixes, &String.starts_with?(name, &1))
end
