defmodule Elara.TestJobs.Record do
  @moduledoc false
  alias Elara.Session.Store

  @statuses ~w(prepared running passed failed cancelled timed_out truncated not_started indeterminate)
  @terminal @statuses -- ~w(prepared running)

  def root do
    {:ok, root} = Store.root()
    Path.join(root, "_test_jobs")
  end

  def key(owner, id),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({owner, id})) |> Base.encode16(case: :lower)

  def load(key) do
    with {:ok, bytes} <- File.read(path(key)),
         {:ok, record} <- JSON.decode(bytes),
         true <- valid?(record, key) do
      {:ok, record}
    else
      {:error, :enoent} = error -> error
      _ -> {:error, :invalid_job_record}
    end
  end

  def scan do
    Enum.reduce(Path.wildcard(Path.join(root(), "*.json")), {[], []}, fn path,
                                                                         {records, invalid} ->
      key = Path.basename(path, ".json")

      case load(key) do
        {:ok, record} -> {[record | records], invalid}
        _ -> {records, [path | invalid]}
      end
    end)
  end

  def save(record) do
    if valid?(record, record["key"]) do
      path = path(record["key"])
      tmp = path <> ".tmp"

      with :ok <- File.mkdir_p(root()),
           :ok <- File.write(tmp, JSON.encode!(record), [:sync]),
           :ok <- File.chmod(tmp, 0o600),
           do: File.rename(tmp, path)
    else
      {:error, :invalid_job_record}
    end
  end

  def terminal?(record), do: record["status"] in @terminal
  defp path(key), do: Path.join(root(), key <> ".json")

  defp valid?(r, key) when is_map(r) do
    r["version"] in [1, 2] and is_binary(key) and Regex.match?(~r/\A[0-9a-f]{64}\z/, key) and
      r["key"] == key and text?(r["owner"], 128) and text?(r["job_id"], 128) and
      key(r["owner"], r["job_id"]) == key and text?(r["cwd"], 8192) and
      Path.type(r["cwd"]) == :absolute and declaration?(r, key) and
      r["status"] in @statuses and r["delivery"] in ["pending", "accepted"] and
      r["slot"] in ["held", "released"] and
      r["settlement"] in ["pending", "settled", "unknown", "operator_confirmed"] and
      is_boolean(r["cancel_requested"]) and sources?(r) and
      (not Map.has_key?(r, "source_changed") or r["source_changed"] in [true, false, "unknown"]) and
      (execution?(r["execution"]) and
         (not is_nil(r["execution"]) or r["status"] in ~w(prepared not_started))) and
      cancellation_wait?(r) and lifecycle?(r) and result?(r)
  end

  defp valid?(_, _), do: false

  defp declaration?(%{"version" => 1} = r, _key), do: text?(r["target"], 8192)

  defp declaration?(%{"version" => 2} = r, key) do
    text?(r["profile"], 128) and
      Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_]{0,127}\z/, r["profile"]) and
      json_arguments?(r["arguments"]) and is_list(r["argv"]) and r["argv"] != [] and
      Enum.all?(r["argv"], &argument?/1) and
      is_integer(r["timeout_ms"]) and r["timeout_ms"] > 0 and
      is_integer(r["max_bytes"]) and r["max_bytes"] > 0 and
      r["output_policy"] in ["truncate", "head_tail"] and is_boolean(r["fingerprint"]) and
      r["correlation_id"] == "job:" <> key and
      (r["profile"] != "mix_test" or
         (text?(r["target"], 8192) and r["arguments"] == %{"target" => r["target"]}))
  end

  defp sources?(%{"version" => 2, "fingerprint" => false} = r),
    do:
      Map.has_key?(r, "source_before") and is_nil(r["source_before"]) and
        is_nil(r["source_after"])

  defp sources?(r),
    do:
      source?(r["source_before"]) and
        (not Map.has_key?(r, "source_after") or source?(r["source_after"]))

  defp argument?(v),
    do: is_binary(v) and String.valid?(v) and not String.contains?(v, <<0>>)

  defp json_arguments?(arguments) when is_map(arguments) do
    JSON.decode!(JSON.encode!(arguments)) == arguments
  rescue
    _ -> false
  end

  defp json_arguments?(_), do: false

  defp text?(v, max), do: is_binary(v) and String.valid?(v) and byte_size(v) in 1..max

  def source?(%{"sha256" => sha, "files" => count, "scope" => scope}) do
    is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) and
      is_integer(count) and count >= 0 and text?(scope, 256)
  end

  def source?(%{"error" => error}), do: text?(error, 256)
  def source?(_), do: false

  defp execution?(nil), do: true

  defp execution?(%{
         "pid" => pid,
         "token" => %{"incarnation" => incarnation, "generation" => gen}
       }) do
    is_binary(pid) and Regex.match?(~r/\A<[0-9]+\.[0-9]+\.[0-9]+>\z/, pid) and
      valid_pid?(pid) and text?(incarnation, 128) and is_integer(gen) and gen > 0
  end

  defp execution?(_), do: false

  defp lifecycle?(%{"status" => status} = r) when status in ~w(prepared running) do
    r["slot"] == "held" and r["settlement"] == "pending" and r["delivery"] == "pending"
  end

  defp lifecycle?(%{"status" => "indeterminate"} = r) do
    (r["slot"] == "held" and r["settlement"] in ~w(pending unknown)) or
      (r["slot"] == "released" and r["settlement"] in ~w(settled operator_confirmed))
  end

  defp lifecycle?(r), do: r["slot"] == "released" and r["settlement"] == "settled"

  defp cancellation_wait?(r) do
    case Map.get(r, "cancellation_wait_expired", false) do
      false ->
        true

      true ->
        r["status"] == "indeterminate" and r["cancel_requested"] and
          (r["slot"] == "held" or r["settlement"] == "operator_confirmed")

      _ ->
        false
    end
  end

  defp valid_pid?(pid) do
    pid |> String.to_charlist() |> :erlang.list_to_pid() |> is_pid()
  rescue
    ArgumentError -> false
  end

  defp result?(%{"status" => status} = r) when status in @terminal do
    output? =
      is_binary(r["output"]) and String.valid?(r["output"]) and
        byte_size(r["output"]) <= output_limit(r)

    metadata? =
      Enum.all?(["bytes_total", "bytes_sent", "elapsed_ms"], fn field ->
        is_integer(r[field]) and r[field] >= 0
      end) and
        Enum.all?(["exit_code", "signal"], fn field ->
          Map.has_key?(r, field) and
            (is_nil(r[field]) or (is_integer(r[field]) and r[field] >= 0))
        end)

    accounting? =
      output? and metadata? and r["bytes_sent"] <= r["bytes_total"] and
        r["bytes_sent"] <= output_cap(r) and
        (r["output"] == "[non-UTF-8 output omitted]" or
           byte_size(r["output"] || "") == r["bytes_sent"]) and
        ((is_integer(r["exit_code"]) and is_nil(r["signal"])) or
           (is_nil(r["exit_code"]) and is_integer(r["signal"]) and r["signal"] > 0)) and
        output_accounting?(r)

    outcome? =
      case status do
        "passed" -> r["termination"] == "exited" and r["exit_code"] == 0
        "failed" -> r["termination"] == "exited" and r["exit_code"] != 0
        other -> r["termination"] == other
      end

    output? and (status in ~w(not_started indeterminate) or (accounting? and outcome?))
  end

  defp result?(%{"status" => "running", "execution" => %{} = execution}),
    do: execution?(execution)

  defp result?(%{"status" => "prepared", "execution" => nil}), do: true
  defp result?(_), do: false

  defp output_limit(%{"status" => status}) when status in ~w(not_started indeterminate),
    do: 20_000

  defp output_limit(%{"version" => 1}), do: 20_000
  defp output_limit(r), do: max(r["max_bytes"], byte_size("[non-UTF-8 output omitted]"))
  defp output_cap(%{"version" => 1}), do: 16_384
  defp output_cap(r), do: r["max_bytes"]

  defp output_accounting?(%{"version" => 2, "output_policy" => "head_tail"} = r) do
    r["termination"] != "truncated" and r["bytes_sent"] == min(r["bytes_total"], r["max_bytes"]) and
      is_boolean(r["output_capped"]) and r["output_capped"] == r["bytes_total"] > r["bytes_sent"]
  end

  defp output_accounting?(%{"version" => 2} = r) do
    is_boolean(r["output_capped"]) and
      r["output_capped"] == r["bytes_total"] > r["bytes_sent"] and truncation_accounting?(r)
  end

  defp output_accounting?(r), do: truncation_accounting?(r)

  defp truncation_accounting?(r) do
    if r["termination"] == "truncated",
      do: r["bytes_total"] > r["bytes_sent"] and r["bytes_sent"] == output_cap(r),
      else: r["bytes_total"] == r["bytes_sent"]
  end
end
