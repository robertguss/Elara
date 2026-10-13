defmodule Elara.Provider.CatalogTest do
  use ExUnit.Case, async: false

  alias Elara.Provider.{Catalog, Grok, OpenAI, OpenAICodex, Visibility}
  alias Elara.Session.{Context, Core, Store}

  defmodule FixtureAdapter do
    def run(request) do
      fixture = Req.Request.get_private(request, :catalog_fixture)
      body = if is_function(fixture, 1), do: fixture.(request), else: fixture

      {request,
       Req.Response.new(status: Req.Request.get_private(request, :catalog_status), body: body)}
    end
  end

  @tag :tmp_dir
  test "authenticated Codex catalog controls windows and choices without importing instructions",
       %{tmp_dir: tmp} do
    provider = codex("account-a")

    body = %{
      "models" => [
        %{"slug" => "hidden", "visibility" => "hide", "context_window" => 999_999},
        %{
          "slug" => "small",
          "visibility" => "list",
          "priority" => 2,
          "supported_reasoning_levels" => [%{"effort" => "low"}],
          "context_window" => 32_768
        },
        %{
          "slug" => "new-model",
          "visibility" => "list",
          "priority" => 1,
          "supported_in_api" => false,
          "context_window" => 543_210,
          "max_context_window" => 1_000_000,
          "supported_reasoning_levels" => [
            %{"effort" => "medium"},
            %{"effort" => "future-effort"}
          ],
          "default_reasoning_level" => "future-effort",
          "base_instructions" => "PRIVATE-INSTRUCTIONS"
        }
      ]
    }

    live =
      Catalog.refresh(
        provider,
        Catalog.offline(provider),
        adapter(fn request ->
          assert request.method == :get
          assert request.url.path == "/backend-api/codex/models"
          assert URI.decode_query(request.url.query)["client_version"] == "0.153.2"
          body
        end)
      )

    assert live["source"] == "live"
    assert Enum.map(live["models"], & &1["model"]) == ["new-model", "small"]
    assert {:ok, 543_210} = Visibility.context_window({%{"model" => "new-model"}, live})

    assert Visibility.normalize(%{"model" => "new-model"}, live) == %{
             "model" => "new-model",
             "effort" => "future-effort"
           }

    assert :ok = Visibility.validate(%{"model" => "new-model", "effort" => "future-effort"}, live)
    refute JSON.encode!(live) =~ "PRIVATE-INSTRUCTIONS"

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: tmp,
        tools: [],
        plugins: [],
        system: "test",
        name: "catalog-reopen"
      )

    on_exit(fn -> stop(session) end)
    assert :ok = Elara.set_provider_settings(session, %{"model" => "new-model"})
    assert Elara.snapshot(session).snapshot["inbox"]["context"]["advertised_limit"] == 543_210

    assert {OpenAICodex, %{model: "new-model", effort: "future-effort"}} =
             Elara.child_config(session).provider

    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
    {:ok, store} = Store.newest(tmp)
    stop(session)

    {:ok, resumed} =
      Elara.start_session(
        provider: provider,
        cwd: tmp,
        resume: store.path,
        tools: [],
        plugins: [],
        system: "test"
      )

    on_exit(fn -> stop(resumed) end)

    assert Elara.materialized_view(resumed)["provider_view"]["next_request"]["model"] ==
             "new-model"

    cached = Catalog.offline(provider)
    assert cached["source"] == "cached"
    assert cached["models"] == live["models"]
    assert Catalog.offline(codex("account-b"))["source"] == "builtin"

    assert Catalog.offline(codex("account-a", "https://different.invalid/backend-api"))["source"] ==
             "builtin"

    unchanged =
      Catalog.refresh(provider, cached, adapter(fn _ -> flunk("fresh cache must avoid HTTP") end))

    assert unchanged == cached

    failed =
      Catalog.refresh(provider, Map.put(cached, "fetched_at", 0), adapter(%{}, 403))

    assert failed["models"] == live["models"]
    assert failed["error"] =~ "HTTP 403"

    different_account =
      Catalog.refresh(
        codex("account-b"),
        live,
        adapter(%{"models" => [%{"visibility" => "list", "supported_reasoning_levels" => false}]})
      )

    assert different_account["source"] == "builtin"
    refute Enum.any?(different_account["models"], &(&1["model"] == "new-model"))
  end

  @tag :tmp_dir
  test "Grok selects documented and arbitrary model IDs; unknown windows stay conservative", %{
    tmp_dir: tmp
  } do
    provider =
      {Grok, Grok.new(%Elara.Auth{access_token: "catalog-fixture", expires_at: 4_000_000_000})}

    {:ok, session} =
      Elara.start_session(provider: provider, cwd: tmp, tools: [], plugins: [], system: "test")

    on_exit(fn -> stop(session) end)
    assert :ok = Elara.set_provider_settings(session, %{"model" => "grok-4.7"})
    view = Elara.snapshot(session).snapshot
    assert view["inbox"]["context"]["advertised_limit"] == 500_000
    row = Enum.find(view["provider_view"]["catalog"], &(&1["model"] == "grok-4.7"))
    assert row["provenance"] == "documented"
    assert row["source"] == "https://docs.x.ai/developers/models/grok-4.7"
    assert row["date"] == "2026-10-13"
    assert :ok = Elara.set_provider_settings(session, %{"model" => "grok-next-operator-id"})
    view = Elara.snapshot(session).snapshot
    assert view["inbox"]["context"]["advertised_limit"] == nil
    assert view["inbox"]["context"]["limit"] == 128_000
    assert List.last(view["provider_view"]["catalog"])["provenance"] == "unverified"
    assert {Grok, %{model: "grok-next-operator-id"}} = Elara.child_config(session).provider

    assert {:error, :unsupported_provider_settings} =
             Elara.set_provider_settings(session, %{"model" => "grok-4.7", "effort" => "high"})

    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  test "live API-key Grok listing joins language aliases and never treats image models as chat" do
    provider =
      {OpenAI,
       %OpenAI{api_key: "catalog-api-fixture", base_url: "https://api.x.ai/v1", model: "grok-4"}}

    language = %{
      "models" => [
        %{"id" => "grok-listed", "aliases" => ["grok-alias"], "output_modalities" => ["text"]},
        %{"id" => "grok-4.7", "output_modalities" => ["text"]}
      ]
    }

    all = %{
      "data" => [
        %{"id" => "image-model", "context_length" => 2_000_000},
        %{"id" => "grok-listed", "aliases" => ["grok-alias"], "context_length" => 654_321}
      ]
    }

    snapshot =
      Catalog.refresh(
        provider,
        Catalog.offline(provider),
        adapter(fn request ->
          if String.ends_with?(request.url.path, "/language-models"), do: language, else: all
        end)
      )

    assert Enum.map(snapshot["models"], & &1["model"]) == [
             "grok-listed",
             "grok-alias",
             "grok-4.7"
           ]

    assert {:ok, 654_321} = Visibility.context_window({%{"model" => "grok-alias"}, snapshot})
    assert {:ok, 500_000} = Visibility.context_window({%{"model" => "grok-4.7"}, snapshot})
    assert List.last(snapshot["models"])["provenance"] == "live; documented window"
    refute JSON.encode!(snapshot) =~ "catalog-api-fixture"
    refute JSON.encode!(snapshot) =~ "image-model"
  end

  test "catalog updates change the current meter without changing an already captured request" do
    initial = Catalog.builtin("grok")

    core =
      Core.new(%Core.Config{
        system: "test",
        tools: %{},
        provider_settings: %{"model" => "grok-4.7"},
        provider_catalog: initial
      })

    {active, effects} = Core.step(core, {:ask, "go"})

    assert Enum.any?(effects, fn
             {:call_provider, _, %{settings: %{"model" => "grok-4.7"}}} -> true
             _ -> false
           end)

    {updated, _} = Core.step(active, {:provider_settings, %{"model" => "typed-unknown"}})
    assert updated.streaming.settings == %{"model" => "grok-4.7"}
    assert Context.budget(updated)["advertised_limit"] == nil
    assert Context.budget(updated)["limit"] == 128_000

    {updated, _} =
      Core.step(
        updated,
        {:provider_catalog,
         Map.put(initial, "models", [
           %{
             "model" => "typed-unknown",
             "efforts" => [],
             "context_window" => 333_333,
             "provenance" => "live"
           }
         ])}
      )

    assert Context.budget(updated)["advertised_limit"] == 333_333
    assert updated.streaming.settings == %{"model" => "grok-4.7"}
  end

  @tag :tmp_dir
  test "changing provider on reopen uses startup defaults with a visible notice", %{tmp_dir: tmp} do
    store = Store.new(tmp, "cross-provider")
    {:ok, store} = Store.set_provider_settings(store, %{"model" => "gpt-5.5", "effort" => "high"})

    provider =
      {Grok,
       Grok.new(%Elara.Auth{access_token: "cross-provider-fixture", expires_at: 4_000_000_000})}

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: tmp,
        resume: store.path,
        tools: [],
        plugins: [],
        system: "test"
      )

    on_exit(fn -> stop(session) end)
    view = Elara.materialized_view(session)["provider_view"]
    assert view["next_request"] == %{"model" => "grok-4"}

    assert view["settings_notice"] ==
             "saved Codex model gpt-5.5 not applied under Grok; using grok-4"

    {:ok, output} = StringIO.open("")
    chat = Task.async(fn -> Elara.Chat.run(session, output) end)
    send(chat.pid, {:stdin, "/model grok-4.7\n"})
    assert eventually(fn -> elem(StringIO.contents(output), 1) =~ "500000" end)
    send(chat.pid, {:stdin, "/quit\n"})
    assert Task.await(chat) == 0
    text = elem(StringIO.contents(output), 1)
    assert text =~ "saved Codex model gpt-5.5 not applied under Grok; using grok-4"
    assert text =~ "documented"

    assert Elara.materialized_view(session)["provider_view"]["next_request"] == %{
             "model" => "grok-4.7"
           }

    refute Enum.any?(Elara.transcript(session), &match?(%Elara.Message.System{}, &1))
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  @tag :tmp_dir
  test "a failed in-flight refresh cannot resurrect a cleared provider-switch notice", %{
    tmp_dir: tmp
  } do
    previous_options = Req.default_options()
    previous_online = Application.fetch_env!(:elara, :model_catalog_online)
    parent = self()

    Req.default_options(
      adapter(
        fn _request ->
          send(parent, {:catalog_waiting, self()})

          receive do
            :finish_catalog -> %{}
          end
        end,
        403
      )
    )

    Application.put_env(:elara, :model_catalog_online, true)

    on_exit(fn ->
      Req.default_options(previous_options)
      Application.put_env(:elara, :model_catalog_online, previous_online)
    end)

    store = Store.new(tmp, "saved-grok")
    {:ok, store} = Store.set_provider_settings(store, %{"model" => "grok-4.7"})
    provider = codex("notice-race-#{System.unique_integer([:positive])}")

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: tmp,
        resume: store.path,
        tools: [],
        plugins: [],
        system: "test"
      )

    on_exit(fn -> stop(session) end)

    assert_receive {:catalog_waiting, fetcher}, 2_000
    assert Elara.materialized_view(session)["provider_view"]["settings_notice"] =~ "saved Grok"

    assert :ok =
             Elara.set_provider_settings(session, %{"model" => "gpt-5.4-mini", "effort" => "low"})

    assert Elara.materialized_view(session)["provider_view"]["settings_notice"] == nil
    send(fetcher, :finish_catalog)

    assert eventually(fn ->
             Elara.materialized_view(session)["provider_view"]["catalog_error"] != nil
           end)

    view = Elara.materialized_view(session)["provider_view"]
    assert view["settings_notice"] == nil
    assert view["next_request"] == %{"model" => "gpt-5.4-mini", "effort" => "low"}
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, tries - 1)
    end
  end

  defp codex(account, base \\ "https://chatgpt.com/backend-api"),
    do:
      {OpenAICodex,
       OpenAICodex.new(
         %Elara.Auth.OpenAICodex{
           account_id: account,
           access_token: "catalog-token-fixture",
           expires_at: 4_000_000_000
         },
         base_url: base
       )}

  defp adapter(body, status \\ 200),
    do: [
      adapter: FixtureAdapter,
      plugins: [
        fn request ->
          request
          |> Req.Request.put_private(:catalog_fixture, body)
          |> Req.Request.put_private(:catalog_status, status)
        end
      ]
    ]

  defp stop(session) do
    case Elara.session_pid(session) do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end
  end
end
