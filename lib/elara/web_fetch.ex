defmodule Elara.WebFetch do
  @moduledoc "Public GETs pinned to vetted addresses; fetched text never grants authority."

  import Bitwise
  alias Elara.{Output, Tool}

  @deadline_ms 15_000
  @body_bytes 1_048_576
  @redirects 5
  @private4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]

  @spec run(map(), Tool.Ctx.t()) :: Tool.outcome()
  def run(%{"url" => url} = args, %Tool.Ctx{} = ctx)
      when is_binary(url) and map_size(args) == 1 do
    timeout = min(ctx.timeout_ms || @deadline_ms, @deadline_ms)

    task =
      Task.Supervisor.async(Elara.TaskSup, fn ->
        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          with {:ok, uri} <- parse(url),
               {:ok, body, headers, final_uri} <- fetch(uri, deadline, @redirects),
               {:ok, markdown} <- markdown(body, headers, final_uri),
               true <- remaining(deadline) > 0 do
            Output.capture(ctx, {:content, :ok, [markdown]}, :web)
          else
            false -> {:error, "web_fetch refused: deadline exceeded"}
            {:error, reason} -> {:error, "web_fetch refused: #{reason}"}
          end
        rescue
          _ -> {:error, "web_fetch failed without a complete page"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, _} -> {:error, "web_fetch failed without a complete page"}
      nil -> {:error, "web_fetch refused: deadline exceeded"}
    end
  end

  def run(_, _), do: {:error, "web_fetch requires only an absolute http(s) url"}

  defp parse(raw) do
    uri = URI.parse(raw)

    if byte_size(raw) in 1..4096 and String.valid?(raw) and
         not Regex.match?(~r/[\x00-\x20\x7f\\]/, raw) and
         uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.userinfo == nil and uri.port in 1..65535 and
         Regex.match?(~r/\A[A-Za-z0-9.:-]+\z/, uri.host) do
      {:ok, %{uri | fragment: nil}}
    else
      {:error, "invalid or credential-bearing URL"}
    end
  rescue
    ArgumentError -> {:error, "invalid URL"}
  end

  defp fetch(uri, deadline, redirects) do
    with {:ok, address} <- address(uri.host),
         {:ok, status, headers, body} <- get(uri, address, deadline) do
      cond do
        status in [301, 302, 303, 307, 308] ->
          case values(headers, "location") do
            [location] when redirects > 0 ->
              with {:ok, next} <- parse(URI.merge(uri, location) |> URI.to_string()),
                   do: fetch(next, deadline, redirects - 1)

            _ ->
              {:error, "invalid redirect or redirect limit exceeded"}
          end

        status in 200..299 ->
          {:ok, body, headers, uri}

        true ->
          {:error, "HTTP #{status}"}
      end
    end
  end

  defp address(host) do
    answers =
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, address} -> {:ok, [address]}
        {:error, _} -> resolve(host)
      end

    with {:ok, addresses} <- answers,
         true <- addresses != [] and length(addresses) <= 32 and Enum.all?(addresses, &public?/1) do
      {:ok, hd(addresses)}
    else
      false -> {:error, "destination is not exclusively public"}
      {:error, _} -> {:error, "could not resolve a public destination"}
    end
  end

  defp resolve(host) do
    # These trusted boundary replacements are for offline tests, never tool arguments.
    resolver = Application.get_env(:elara, :web_fetch_resolver, :inet)

    Enum.reduce_while([:inet, :inet6], {:ok, []}, fn family, {:ok, addresses} ->
      case resolver.getaddrs(String.to_charlist(host), family) do
        {:ok, more} -> {:cont, {:ok, addresses ++ more}}
        {:error, :nxdomain} -> {:cont, {:ok, addresses}}
        error -> {:halt, error}
      end
    end)
  end

  defp public?(address) when tuple_size(address) == 4 do
    value = ip_integer(address, 8)

    not Enum.any?(@private4, fn {base, bits} ->
      value >>> (32 - bits) == ip_integer(base, 8) >>> (32 - bits)
    end)
  end

  defp public?({a, b, c, d, e, f, g, h}) do
    value = ip_integer({a, b, c, d, e, f, g, h}, 16)

    # Only global unicast; exclude special-use, documentation and tunnel space.
    value >>> 125 == 1 and
      not (a == 0x2001 and b < 0x200) and
      not (a == 0x2001 and b == 0xDB8) and a != 0x2002 and
      not (a == 0x3FFF and b < 0x1000)
  end

  defp ip_integer(address, bits),
    do: address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< bits) + part end)

  defp get(uri, address, deadline) do
    http = Application.get_env(:elara, :web_fetch_http, Mint.HTTP)
    scheme = if uri.scheme == "https", do: :https, else: :http

    transport = [
      timeout: remaining(deadline),
      send_timeout: remaining(deadline),
      send_timeout_close: true,
      inet4: tuple_size(address) == 4,
      inet6: tuple_size(address) == 8
    ]

    transport =
      if scheme == :https,
        do: transport ++ [verify: :verify_peer, cacerts: :public_key.cacerts_get()],
        else: transport

    opts = [
      hostname: uri.host,
      protocols: [:http1],
      mode: :passive,
      max_header_list_size: 32_768,
      transport_opts: transport
    ]

    with true <- remaining(deadline) > 0,
         {:ok, conn} <- http.connect(scheme, address, uri.port, opts) do
      host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
      host = if uri.port == URI.default_port(uri.scheme), do: host, else: "#{host}:#{uri.port}"
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      target = path <> if(uri.query, do: "?" <> uri.query, else: "")

      headers = [
        {"host", host},
        {"accept", "text/html, text/plain"},
        {"accept-encoding", "identity"}
      ]

      case http.request(conn, "GET", target, headers, nil) do
        {:ok, conn, ref} ->
          receive_page(http, conn, ref, deadline, %{
            status: nil,
            headers: [],
            chunks: [],
            bytes: 0
          })

        {:error, conn, _} ->
          http.close(conn)
          {:error, "request failed"}
      end
    else
      _ -> {:error, "connection failed or deadline exceeded"}
    end
  end

  defp receive_page(http, conn, ref, deadline, page) do
    case http.recv(conn, 0, remaining(deadline)) do
      {:ok, conn, events} ->
        case Enum.reduce_while(events, {:more, page}, &event(&1, &2, ref)) do
          {:more, page} ->
            receive_page(http, conn, ref, deadline, page)

          {:done, page} ->
            http.close(conn)

            {:ok, page.status, page.headers,
             page.chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          {:error, reason} ->
            http.close(conn)
            {:error, reason}
        end

      {:error, conn, _, _events} ->
        http.close(conn)
        {:error, "incomplete response or deadline exceeded"}
    end
  end

  defp event({:status, ref, 101}, {:more, _}, ref),
    do: {:halt, {:error, "protocol upgrades are not supported"}}

  defp event({:status, ref, status}, {:more, page}, ref),
    do: {:cont, {:more, %{page | status: status, headers: []}}}

  defp event({:headers, ref, _}, {:more, %{status: status} = page}, ref)
       when status in 100..199,
       do: {:cont, {:more, page}}

  defp event({:headers, ref, headers}, {:more, page}, ref) do
    headers = page.headers ++ headers

    if Enum.all?(values(headers, "content-encoding"), &(&1 in ["", "identity"])) do
      {:cont, {:more, %{page | headers: headers}}}
    else
      {:halt, {:error, "compressed responses are not supported"}}
    end
  end

  defp event({:data, ref, chunk}, {:more, page}, ref) do
    if page.bytes + byte_size(chunk) <= @body_bytes,
      do:
        {:cont,
         {:more, %{page | chunks: [chunk | page.chunks], bytes: page.bytes + byte_size(chunk)}}},
      else: {:halt, {:error, "page exceeds the 1 MiB body limit"}}
  end

  defp event({:done, ref}, {:more, %{status: status} = page}, ref) when is_integer(status),
    do: {:halt, {:done, page}}

  defp event(_, _, _), do: {:halt, {:error, "invalid response"}}

  defp values(headers, name),
    do: for({^name, value} <- headers, do: value)

  defp markdown(body, headers, uri) do
    type = values(headers, "content-type") |> List.first()
    type = if type, do: String.downcase(type), else: ""

    cond do
      not String.valid?(body) ->
        {:error, "page is not UTF-8 text"}

      String.contains?(type, "charset=") and not Regex.match?(~r/charset=["']?utf-8/i, type) ->
        {:error, "page charset is not UTF-8"}

      String.starts_with?(type, "text/html") ->
        with {:ok, nodes} <- Floki.parse_document(body) do
          source = "Source: #{URI.to_string(uri)}\n\n"
          {content, _} = render(nodes, uri, 0, 2 * @body_bytes - byte_size(source) - 1)
          {:ok, source <> (content |> IO.iodata_to_binary() |> String.trim()) <> "\n"}
        end

      String.starts_with?(type, "text/plain") or String.starts_with?(type, "text/markdown") ->
        {:ok, "Source: #{URI.to_string(uri)}\n\n" <> body}

      true ->
        {:error, "unsupported page content type"}
    end
  catch
    :converted_page_limit -> {:error, "converted page exceeds the 2 MiB limit"}
  end

  defp render(_nodes, _uri, depth, _) when depth > 128,
    do: raise(ArgumentError, "HTML nesting too deep")

  defp render(nodes, uri, depth, budget) when is_list(nodes),
    do: Enum.map_reduce(nodes, budget, &render(&1, uri, depth, &2))

  defp render(text, _uri, _depth, budget) when is_binary(text),
    do: emit(String.replace(text, ~r/\s+/u, " "), budget)

  defp render({:comment, _}, _, _, budget), do: {"", budget}

  defp render({tag, _, _}, _, _, budget)
       when tag in ~w(script style noscript template iframe form head svg), do: {"", budget}

  defp render({"pre", _, children}, _, _, budget),
    do: emit("\n\n````\n" <> Floki.text(children, sep: "", deep: true) <> "\n````\n\n", budget)

  defp render({tag, attrs, children}, uri, depth, budget) do
    {prefix, suffix} =
      cond do
        tag in ~w(h1 h2 h3 h4 h5 h6) ->
          {"\n\n" <> String.duplicate("#", String.to_integer(String.slice(tag, 1, 1))) <> " ",
           "\n\n"}

        tag == "a" ->
          link(attrs, uri)

        tag == "code" ->
          {"`", "`"}

        tag in ~w(strong b) ->
          {"**", "**"}

        tag in ~w(em i) ->
          {"*", "*"}

        tag == "li" ->
          {"\n- ", ""}

        tag == "br" ->
          {"\n", ""}

        tag == "hr" ->
          {"\n\n---\n\n", ""}

        tag in ~w(p div section article main ul ol blockquote table tr) ->
          {"\n\n", "\n\n"}

        tag in ~w(td th) ->
          {"", " | "}

        true ->
          {"", ""}
      end

    {_, budget} = emit(prefix <> suffix, budget)
    {inner, budget} = render(children, uri, depth + 1, budget)
    {[prefix, inner, suffix], budget}
  end

  defp emit(text, budget) do
    if byte_size(text) <= budget,
      do: {text, budget - byte_size(text)},
      else: throw(:converted_page_limit)
  end

  defp link(attrs, uri) do
    case List.keyfind(attrs, "href", 0) do
      {_, href} ->
        case parse(URI.merge(uri, href) |> URI.to_string()) do
          {:ok, target} -> {"[", "](" <> URI.to_string(target) <> ")"}
          _ -> {"", ""}
        end

      nil ->
        {"", ""}
    end
  rescue
    ArgumentError -> {"", ""}
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
