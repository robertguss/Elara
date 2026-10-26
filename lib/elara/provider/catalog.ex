defmodule Elara.Provider.Catalog do
  @moduledoc "Account-scoped public model metadata and offline cache; never imports provider instructions."

  alias Elara.Provider.{Grok, OpenAI, OpenAICodex, Visibility}

  @ttl 300
  @date "2026-10-13"
  @type t :: %{String.t() => term()}

  def offline(provider) do
    case identity(provider) do
      nil ->
        nil

      {kind, scope} ->
        case File.read(cache_path(scope)) do
          {:ok, bytes} when byte_size(bytes) <= 2_097_152 ->
            with {:ok, %{"version" => 1, "kind" => ^kind, "models" => models} = cache} <-
                   JSON.decode(bytes),
                 ^scope <- cache["scope"],
                 true <- valid_models?(models) do
              cache
              |> Map.take(["version", "kind", "scope", "fetched_at"])
              |> Map.put("source", "cached")
              |> Map.put(
                "models",
                Enum.map(
                  models,
                  &Map.take(
                    &1,
                    ~w(model efforts default_effort context_window provenance tested_efforts source date)
                  )
                )
              )
            else
              _ -> Map.put(builtin(kind), "scope", scope)
            end

          _ ->
            Map.put(builtin(kind), "scope", scope)
        end
    end
  end

  defp builtin("codex"),
    do: %{
      "version" => 1,
      "kind" => "codex",
      "source" => "builtin",
      "models" => Visibility.catalog()
    }

  defp builtin("grok") do
    models =
      Enum.map(["grok-4", "grok-4.6", "grok-4.7"], fn model ->
        %{
          "model" => model,
          "efforts" => [],
          "context_window" => if(model == "grok-4", do: nil, else: 500_000),
          "provenance" => "documented",
          "source" => if(model != "grok-4", do: "https://docs.x.ai/developers/models/#{model}"),
          "date" => if(model != "grok-4", do: @date)
        }
      end)

    %{"version" => 1, "kind" => "grok", "source" => "documented", "models" => models}
  end

  def refresh(provider, previous, request_options \\ []) do
    case identity(provider) do
      nil ->
        previous

      {kind, scope} ->
        previous =
          if previous["scope"] in [nil, scope],
            do: previous,
            else: Map.put(builtin(kind), "scope", scope)

        age =
          if is_integer(previous["fetched_at"]),
            do: System.system_time(:second) - previous["fetched_at"]

        if previous["scope"] == scope and age in 0..(@ttl - 1) do
          previous
        else
          result =
            try do
              fetch(provider, request_options)
            rescue
              _ -> {:error, "Invalid or unavailable model catalog; using offline catalog"}
            end

          case result do
            {:ok, models} ->
              snapshot = %{
                "version" => 1,
                "kind" => kind,
                "scope" => scope,
                "source" => "live",
                "fetched_at" => System.system_time(:second),
                "models" => models
              }

              save(scope, snapshot)
              snapshot

            {:error, reason} ->
              Map.put(previous, "error", reason)
          end
        end
    end
  end

  defp fetch({OpenAICodex, config}, opts) do
    url = String.trim_trailing(config.base_url, "/") <> "/codex/models"

    with {:ok, tokens} <- Elara.Auth.OpenAICodex.refresh_if_needed(config.tokens),
         true <- tokens.account_id == config.tokens.account_id,
         headers = [
           {"authorization", "Bearer #{tokens.access_token}"},
           {"chatgpt-account-id", tokens.account_id},
           {"originator", config.originator},
           {"user-agent", "elara/#{Application.spec(:elara, :vsn)}"}
         ],
         {:ok, %{"models" => models}} <-
           get(url, headers, [params: [client_version: "0.153.2"]] ++ opts),
         {:ok, rows} <- codex_models(models) do
      {:ok, rows}
    else
      false ->
        {:error, "Model listing account changed; reopen the session to refresh capabilities"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "Model listing authentication unavailable; using offline catalog"}

      _ ->
        {:error, "Invalid Codex model catalog"}
    end
  end

  defp fetch({OpenAI, config}, opts) do
    base = String.trim_trailing(config.base_url, "/")
    headers = [{"authorization", "Bearer #{config.api_key}"}]

    with {:ok, %{"models" => language}} <- get(base <> "/language-models", headers, opts),
         {:ok, %{"data" => all}} <- get(base <> "/models", headers, opts),
         {:ok, rows} <- grok_models(language, all) do
      {:ok, rows}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid xAI model catalog"}
    end
  end

  defp fetch({Grok, _}, _),
    do: {:error, "OAuth model listing is unverified; using documented models"}

  defp get(url, headers, opts) do
    options = [
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]

    case Req.get(url, Keyword.merge(options, opts)) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Model listing HTTP #{status}; using offline catalog"}
      {:error, _} -> {:error, "Model listing unavailable; using offline catalog"}
    end
  end

  # All persisted keys are constructed here. Base instructions, prices and
  # arbitrary remote fields never survive the boundary.
  defp codex_models(models) when is_list(models) and length(models) <= 1_000 do
    rows =
      models
      |> Enum.filter(&(is_map(&1) and &1["visibility"] == "list"))
      |> Enum.sort_by(&{&1["priority"] || 0, &1["slug"] || ""})
      |> Enum.map(fn model ->
        efforts =
          (model["supported_reasoning_levels"] || [])
          |> Enum.flat_map(fn
            %{"effort" => effort} -> if valid_id?(effort), do: [effort], else: []
            _ -> []
          end)
          |> Enum.uniq()

        %{
          "model" => model["slug"],
          "efforts" => efforts,
          "default_effort" =>
            if(model["default_reasoning_level"] in efforts,
              do: model["default_reasoning_level"],
              else: List.first(efforts)
            ),
          "context_window" => positive_window(model["context_window"]),
          "provenance" => "live"
        }
      end)

    validated_rows(rows)
  end

  defp codex_models(_), do: {:error, "Invalid Codex model catalog"}

  defp grok_models(language, all)
       when is_list(language) and is_list(all) and length(language) <= 1_000 and
              length(all) <= 1_000 do
    rows =
      language
      |> Enum.filter(&(is_map(&1) and "text" in (&1["output_modalities"] || [])))
      |> Enum.flat_map(fn model ->
        Enum.map([model["id"] | model["aliases"] || []], fn id ->
          metadata =
            Enum.find(all, &(is_map(&1) and (id == &1["id"] or id in (&1["aliases"] || [])))) ||
              %{}

          documented = Enum.find(builtin("grok")["models"], &(&1["model"] == id)) || %{}
          live_window = positive_window(metadata["context_length"])

          row = %{
            "model" => id,
            "efforts" => [],
            "context_window" => live_window || documented["context_window"],
            "provenance" => "live"
          }

          if live_window == nil and documented["context_window"],
            do:
              Map.merge(row, Map.take(documented, ["source", "date"]))
              |> Map.put("provenance", "live; documented window"),
            else: row
        end)
      end)

    validated_rows(rows)
  end

  defp grok_models(_, _), do: {:error, "Invalid xAI model catalog"}

  defp validated_rows(rows) do
    rows = Enum.uniq_by(rows, & &1["model"])
    if valid_models?(rows), do: {:ok, rows}, else: {:error, "Invalid or empty model catalog"}
  end

  defp valid_models?(models) when is_list(models) and models != [] and length(models) <= 1_000 do
    Enum.all?(models, fn
      %{"model" => model, "efforts" => efforts, "context_window" => window} ->
        valid_id?(model) and is_list(efforts) and length(efforts) <= 32 and
          Enum.all?(efforts, &valid_id?/1) and
          (is_nil(window) or positive_window(window) == window)

      _ ->
        false
    end)
  end

  defp valid_models?(_), do: false

  def valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9._:\/-]+\z/, id)

  defp positive_window(n) when is_integer(n) and n > 0, do: n
  defp positive_window(_), do: nil

  defp identity({OpenAICodex, config}),
    do: scope("codex", {config.base_url, config.tokens.account_id || config.tokens.access_token})

  defp identity({Grok, config}), do: scope("grok", {config.base_url, config.tokens.access_token})

  defp identity({OpenAI, config}) do
    if URI.parse(config.base_url).host == "api.x.ai",
      do: scope("grok", {config.base_url, config.api_key}),
      else: nil
  end

  defp identity(_), do: nil

  defp scope(kind, identity),
    do:
      {kind,
       :crypto.hash(:sha256, :erlang.term_to_binary({kind, identity}))
       |> Base.encode16(case: :lower)}

  defp cache_path(scope) do
    {:ok, root} = Elara.Session.Store.root()
    Path.join([root, "_model_catalogs", scope <> ".json"])
  end

  defp save(scope, snapshot) do
    path = cache_path(scope)
    staged = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(staged, JSON.encode!(snapshot), [:exclusive]),
         :ok <- File.chmod(staged, 0o600) do
      # Independent refreshers use separate staging paths; the last complete
      # snapshot wins, never a partially written cache.
      File.rename(staged, path)
    end
  end
end
