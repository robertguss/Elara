defmodule Elara.TestJobs do
  @moduledoc "Owns local focused test jobs and delivers retained completion evidence; never calls a model."

  alias Elara.Tool

  def start_link(opts \\ []), do: Elara.Jobs.start_link(opts)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def tool do
    %Tool{
      name: "test_job",
      description:
        "Start, inspect or cancel one local focused Mix test job. Use a stable job_id; start requires target test/*_test.exs[:line]. After starting, end this turn: completion arrives through the inbox without polling. Interrupt pauses delivery; cancel requests termination. Inspect status before treating earlier results as current.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["start", "status", "cancel"]},
          "job_id" => %{"type" => "string"},
          "target" => %{"type" => "string"}
        },
        "required" => ["action", "job_id"],
        "additionalProperties" => false
      },
      run: {__MODULE__, :run},
      placement: :local,
      mutating: true,
      capabilities: ["shell", "filesystem:read"]
    }
  end

  def run(%{"action" => action, "job_id" => id} = args, %Tool.Ctx{} = ctx)
      when action in ["start", "status", "cancel"] and is_binary(id) and byte_size(id) in 1..128 and
             is_binary(ctx.session_id) do
    case GenServer.call(__MODULE__, {action, id, args["target"], ctx}, :infinity) do
      {:ok, record} -> {:ok, JSON.encode!(record)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def run(_, _), do: {:error, "invalid test_job arguments"}

  @doc "Release an indeterminate reservation only after the operator confirms its command has stopped."
  def acknowledge_stopped(session, id) when is_binary(session) and is_binary(id),
    do: Elara.Jobs.acknowledge_stopped(session, id)
end
