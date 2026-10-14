defmodule Elara.WebSearch do
  @moduledoc "Fixed-endpoint Exa searches; untrusted excerpts never grant authority."

  alias Elara.{Output, Tool}
  alias Elara.Auth.Exa

  @endpoint "https://api.exa.ai/search"
  @timeout 15_000
  @body_limit 1_048_576

  def run(%{"query" => query} = args, %Tool.Ctx{} = ctx)
      when is_binary(query) and byte_size(query) in 1..4096 and map_size(args) == 1 do
    if String.valid?(query) and String.trim(query) != "" do
      timeout = min(ctx.timeout_ms || @timeout, @timeout)

      task =
        Task.Supervisor.async(Elara.TaskSup, fn ->
          case Exa.load_key() do
            {:ok, key} ->
              case search(query, key, timeout) do
                {:ok, response} ->
                  receipt(redact(response, key), redact(query, key))

                {:error, reason, response} ->
                  receipt(redact(response, key), redact(query, key), reason)
              end

            {:error, :not_logged_in} ->
              receipt(%{}, query, "Exa is not logged in; run mix elara.login exa")
          end
        end)

      {kind, receipt} =
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, outcome} -> outcome
          _ -> receipt(%{}, query, "deadline exceeded; search may have been billed")
        end

      Output.capture(ctx, {:content, kind, [JSON.encode!(receipt)]}, :web)
    else
      {:error, "web_search requires a non-empty UTF-8 query (at most 4096 bytes)"}
    end
  end

  def run(_, _), do: {:error, "web_search requires only a query (at most 4096 bytes)"}

  defp search(query, key, timeout) do
    http = Application.get_env(:elara, :exa_http, &Req.post/2)

    result =
      http.(@endpoint,
        headers: [{"x-api-key", key}],
        json: %{
          "query" => query,
          "type" => "auto",
          "numResults" => 5,
          "contents" => %{"highlights" => true}
        },
        raw: true,
        redirect: false,
        retry: false,
        receive_timeout: timeout,
        connect_options: [timeout: min(timeout, 5000)],
        into: &collect/2
      )

    case result do
      {:ok, %Req.Response{body: :too_large}} ->
        {:error, "response exceeds 1 MiB; search may have been billed", %{}}

      {:ok, %Req.Response{status: 200, body: %{chunks: chunks}}} ->
        case JSON.decode(chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
          {:ok, response} -> {:ok, response}
          _ -> {:error, "invalid response; search may have been billed", %{}}
        end

      {:ok, %Req.Response{status: status, body: %{chunks: chunks}}} ->
        response =
          case JSON.decode(chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
            {:ok, response} -> response
            _ -> %{}
          end

        {:error, "HTTP #{status}; search may have been billed; no automatic retry", response}

      _ ->
        {:error, "connection failed; search may have been billed; no automatic retry", %{}}
    end
  rescue
    _ -> {:error, "connection failed; search may have been billed; no automatic retry", %{}}
  end

  defp collect({:data, bytes}, {request, response}) do
    body = if is_map(response.body), do: response.body, else: %{chunks: [], size: 0}
    size = body.size + byte_size(bytes)

    if size > @body_limit do
      {:halt, {request, %{response | body: :too_large}}}
    else
      {:cont, {request, %{response | body: %{chunks: [bytes | body.chunks], size: size}}}}
    end
  end

  defp receipt(response, query, error \\ nil) do
    request_id =
      case response do
        %{"requestId" => id} when is_binary(id) -> id
        _ -> nil
      end

    cost =
      case response do
        %{"costDollars" => %{"total" => cost}} when is_number(cost) and cost >= 0 -> cost
        _ -> nil
      end

    accounting = %{"query" => query, "request_id" => request_id, "reported_cost_usd" => cost}

    evidence =
      case {error, response} do
        {nil, %{"results" => results}} when is_list(results) -> rows(Enum.take(results, 5))
        {nil, _} -> {:error, "invalid response; search may have been billed"}
        {reason, _} -> {:error, reason}
      end

    case evidence do
      {:ok, rows} -> {:ok, Map.put(accounting, "results", rows)}
      {:error, reason} -> {:error, Map.put(accounting, "error", "web_search failed: #{reason}")}
    end
  end

  defp redact(value, key) when is_binary(value),
    do: String.replace(value, key, "[Exa credential removed]")

  defp redact(value, key) when is_list(value), do: Enum.map(value, &redact(&1, key))

  defp redact(value, key) when is_map(value),
    do: Map.new(value, fn {name, item} -> {name, redact(item, key)} end)

  defp redact(value, _key), do: value

  defp rows(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      %{"url" => url} = row, {:ok, rows} when is_binary(url) and byte_size(url) <= 4096 ->
        with {:ok, uri} <- URI.new(url),
             true <-
               uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil do
          highlights = row["highlights"] || []

          text =
            if is_list(highlights),
              do:
                highlights
                |> Enum.filter(&is_binary/1)
                |> Enum.take(3)
                |> Enum.map_join("\n", &excerpt(&1, 800)),
              else: ""

          {:cont,
           {:ok,
            rows ++
              [
                %{
                  "title" => excerpt(row["title"], 240),
                  "url" => url,
                  "excerpt" => excerpt(text, 800)
                }
              ]}}
        else
          _ -> {:halt, {:error, "invalid result URL"}}
        end

      _, _ ->
        {:halt, {:error, "invalid result"}}
    end)
  end

  defp excerpt(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp excerpt(_, _), do: ""
end
