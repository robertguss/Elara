defmodule Elara.Jobs.Profile do
  @moduledoc """
  Trusted local job declarations. Configure additional profiles through
  `:elara, :job_profiles` or the manager's `profiles:` start option.

  `validate` and `argv` receive `(cwd, arguments)`; validation returns `:ok`
  or `{:error, reason}`. An optional `fingerprint` receives `cwd` and returns
  the same source evidence shape as the Mix profile. Declarations are trusted
  code, never supplied through a tool call. Limits and argv freeze at admission.
  """
  alias Elara.TestJobs.Workspace

  @enforce_keys [:name, :validate, :argv, :timeout_ms, :max_bytes, :output_policy]
  defstruct [:name, :validate, :argv, :timeout_ms, :max_bytes, :output_policy, :fingerprint]

  def catalog(additional) when is_list(additional) do
    Enum.reduce_while([mix_test() | additional], {:ok, %{}}, fn profile, {:ok, profiles} ->
      cond do
        not declaration?(profile) -> {:halt, {:error, :invalid_job_profile}}
        Map.has_key?(profiles, profile.name) -> {:halt, {:error, :duplicate_job_profile}}
        true -> {:cont, {:ok, Map.put(profiles, profile.name, profile)}}
      end
    end)
  end

  def catalog(_), do: {:error, :invalid_job_profiles}

  def prepare(profiles, name, cwd, arguments) when is_binary(name) and is_map(arguments) do
    with %__MODULE__{} = profile <- profiles[name],
         true <- json_arguments?(arguments),
         :ok <- profile.validate.(cwd, arguments),
         argv <- profile.argv.(cwd, arguments),
         true <- is_list(argv) and argv != [] and Enum.all?(argv, &argument?/1) do
      {:ok, profile, arguments, argv}
    else
      nil -> {:error, :unknown_job_profile}
      {:error, _} = error -> error
      _ -> {:error, :invalid_job_profile_arguments}
    end
  rescue
    _ -> {:error, :job_profile_callback_failed}
  catch
    _, _ -> {:error, :job_profile_callback_failed}
  end

  def prepare(_, _, _, _), do: {:error, :invalid_job_profile_arguments}

  def fingerprint(nil, _cwd), do: nil

  def fingerprint(callback, cwd) do
    evidence = callback.(cwd)

    if Elara.TestJobs.Record.source?(evidence),
      do: evidence,
      else: %{"error" => "invalid source evidence"}
  rescue
    _ -> %{"error" => "source unavailable"}
  catch
    _, _ -> %{"error" => "source unavailable"}
  end

  defp mix_test do
    %__MODULE__{
      name: "mix_test",
      validate: &validate_mix/2,
      argv: fn _, %{"target" => target} -> ["mix", "test", target] end,
      timeout_ms: 60_000,
      max_bytes: 16_384,
      output_policy: :head_tail,
      fingerprint: &Workspace.fingerprint/1
    }
  end

  defp validate_mix(cwd, %{"target" => target} = arguments) when map_size(arguments) == 1,
    do: Workspace.target(cwd, target)

  defp validate_mix(_, _), do: {:error, :invalid_test_target}

  defp declaration?(%__MODULE__{} = p) do
    is_binary(p.name) and Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_]{0,127}\z/, p.name) and
      is_function(p.validate, 2) and is_function(p.argv, 2) and
      is_integer(p.timeout_ms) and p.timeout_ms > 0 and is_integer(p.max_bytes) and
      p.max_bytes > 0 and p.output_policy in [:head_tail, :truncate] and
      (is_nil(p.fingerprint) or is_function(p.fingerprint, 1))
  end

  defp declaration?(_), do: false

  defp argument?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp json_arguments?(arguments), do: JSON.decode!(JSON.encode!(arguments)) == arguments
end
