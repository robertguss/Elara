defmodule Elara.FlightRecorder do
  @moduledoc "Versioned deterministic recordings of facts passed through the session core."

  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider
  alias Elara.Session.Core
  alias Elara.Tool
  alias Elara.Tool.PluginRef

  @magic "ELARA-FLIGHT\0"
  @version 1
  @max_frame_bytes 64 * 1024 * 1024

  defmodule Recording do
    @moduledoc "Portable recording loaded from a live session or a flight file."
    @type t :: %__MODULE__{}
    defstruct [:header, segments: [], transitions: [], incomplete: [], event_causes: %{}]
  end

  defmodule Report do
    @moduledoc "Offline replay result."
    @type t :: %__MODULE__{}
    defstruct [:status, :final_state, :divergence, transitions: 0, observations: []]
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :header,
      :path,
      :file,
      sequence: 0,
      segment: 0,
      segments: [],
      transitions: [],
      causes: %{},
      event_causes: %{}
    ]
  end

  defmodule ReplayTool do
    @moduledoc false
    def run(_arguments, _context), do: {:error, "recorded tools cannot execute during replay"}
  end

  @spec new(Core.State.t(), String.t(), String.t(), String.t() | nil) :: State.t()
  def new(core, session_id, incarnation, session_path) do
    recording_id = random_id()

    header = %{
      type: :header,
      format_version: @version,
      recording_id: recording_id,
      session_id: session_id,
      incarnation: incarnation,
      producer: %{
        elara_version: Application.spec(:elara, :vsn) |> to_string(),
        otp_release: System.otp_release()
      }
    }

    path = recording_path(session_path, incarnation)
    file = open_file(path)
    state = %State{header: header, path: path, file: file}
    state |> write_frame(header) |> segment(core, :init)
  end

  @spec close(State.t()) :: :ok
  def close(%State{file: nil}), do: :ok
  def close(%State{file: file}), do: File.close(file)

  @spec segment(State.t(), Core.State.t(), atom()) :: State.t()
  def segment(%State{} = recorder, core, reason) do
    number = if recorder.segments == [], do: 0, else: recorder.segment + 1
    seed = normalize_state(core)

    entry = %{
      type: :segment,
      segment: number,
      reason: reason,
      seed: seed,
      seed_fingerprint: fingerprint(seed)
    }

    recorder
    |> write_frame(entry)
    |> Map.put(:segment, number)
    |> Map.update!(:segments, &(&1 ++ [entry]))
  end

  @spec begin_transition(State.t(), Core.State.t(), Core.fact()) :: {State.t(), map()}
  def begin_transition(%State{} = recorder, core, fact) do
    sequence = recorder.sequence + 1
    id = %{recording_id: recorder.header.recording_id, sequence: sequence}
    normalized_fact = normalize_fact(fact)

    entry = %{
      type: :transition_begin,
      id: id,
      segment: recorder.segment,
      caused_by: cause(recorder, fact),
      fact: normalized_fact,
      fact_fingerprint: fingerprint(normalized_fact),
      pre: projection(core)
    }

    recorder = recorder |> write_frame(entry) |> Map.put(:sequence, sequence)
    {recorder, entry}
  end

  @spec complete_transition(State.t(), map(), Core.State.t(), [Core.effect()]) ::
          {State.t(), map()}
  def complete_transition(%State{} = recorder, begin, core, effects) do
    descriptors = tool_descriptors(core)

    normalized_effects =
      effects
      |> Enum.with_index()
      |> Enum.map(fn {effect, index} ->
        %{index: index, value: normalize_effect(effect, descriptors)}
      end)

    ending = %{
      type: :transition_end,
      id: begin.id,
      post: projection(core),
      effects: normalized_effects,
      effects_fingerprint: fingerprint(normalized_effects)
    }

    transition =
      begin
      |> Map.drop([:type])
      |> Map.merge(Map.drop(ending, [:type, :id]))

    recorder =
      recorder
      |> write_frame(ending)
      |> sync()
      |> remember_causes(effects, begin.id)
      |> Map.update!(:transitions, &(&1 ++ [transition]))

    {recorder, transition}
  end

  @spec link_event(State.t(), non_neg_integer(), map()) :: State.t()
  def link_event(%State{} = recorder, event_sequence, effect_id) do
    entry = %{type: :event_link, event_sequence: event_sequence, effect: effect_id}

    recorder
    |> write_frame(entry)
    |> Map.update!(:event_causes, &Map.put(&1, event_sequence, effect_id))
  end

  @spec snapshot(State.t()) :: Recording.t()
  def snapshot(%State{} = recorder) do
    %Recording{
      header: recorder.header,
      segments: recorder.segments,
      transitions: recorder.transitions,
      event_causes: recorder.event_causes
    }
  end

  @spec path(State.t()) :: String.t() | nil
  def path(%State{path: path}), do: path

  @spec load(String.t()) :: {:ok, Recording.t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, frames} <- decode_file(binary) do
      assemble(frames)
    end
  end

  @spec replay(Recording.t() | String.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def replay(recording, opts \\ [])

  def replay(path, opts) when is_binary(path) do
    with {:ok, recording} <- load(path), do: replay(recording, opts)
  end

  def replay(%Recording{} = recording, opts) do
    step = Keyword.get(opts, :step, &Core.step/2)
    injection = Keyword.get(opts, :inject)

    with :ok <- validate_recording(recording),
         {:ok, state, observations, compared, divergence} <-
           replay_segments(recording, step, injection) do
      status =
        cond do
          divergence -> :diverged
          injection -> :injected
          true -> :match
        end

      {:ok,
       %Report{
         status: status,
         final_state: state,
         transitions: compared,
         observations: observations,
         divergence: divergence
       }}
    end
  end

  @spec why(State.t() | Recording.t(), :latest | pos_integer() | {:transition, pos_integer()}) ::
          {:ok, map()} | {:error, :not_found}
  def why(%State{} = recorder, selector) do
    effect_id =
      case selector do
        :latest ->
          recorder.event_causes |> Enum.max_by(&elem(&1, 0), fn -> nil end) |> value()

        sequence when is_integer(sequence) ->
          Map.get(recorder.event_causes, sequence)

        {:transition, sequence} ->
          %{recording_id: recorder.header.recording_id, sequence: sequence}
      end

    explain(recorder, effect_id)
  end

  def why(%Recording{header: header} = recording, {:transition, sequence}) do
    explain(recording, %{recording_id: header.recording_id, sequence: sequence})
  end

  def why(%Recording{} = recording, selector) do
    effect_id =
      case selector do
        :latest ->
          recording.event_causes |> Enum.max_by(&elem(&1, 0), fn -> nil end) |> value()

        sequence when is_integer(sequence) ->
          Map.get(recording.event_causes, sequence)
      end

    explain(recording, effect_id)
  end

  defp explain(_recorder, nil), do: {:error, :not_found}

  defp explain(recorder, effect_id) do
    transition_id = Map.take(effect_id, [:recording_id, :sequence])

    case Enum.find(recorder.transitions, &(&1.id == transition_id)) do
      nil ->
        {:error, :not_found}

      transition ->
        chain = causal_chain(recorder.transitions, transition, [])

        {:ok,
         %{
           transition_id: transition.id,
           effect_index: Map.get(effect_id, :effect_index),
           fact: transition.fact,
           pre: transition.pre,
           post: transition.post,
           chain: chain
         }}
    end
  end

  defp causal_chain(transitions, transition, acc) do
    row = %{transition_id: transition.id, fact: transition.fact, caused_by: transition.caused_by}

    case transition.caused_by do
      :external ->
        [row | acc]

      %{transition: id} ->
        case Enum.find(transitions, &(&1.id == id)) do
          nil -> [row | acc]
          parent -> causal_chain(transitions, parent, [row | acc])
        end
    end
  end

  defp replay_segments(recording, step, injection) do
    Enum.reduce_while(recording.segments, {:ok, nil, [], 0, nil}, fn segment, acc ->
      {:ok, _prior, observations, compared, divergence} = acc
      state = denormalize_state(segment.seed)
      descriptors = Map.new(segment.seed.config.tools, &{&1.name, &1})
      transitions = Enum.filter(recording.transitions, &(&1.segment == segment.segment))

      case replay_transitions(
             state,
             transitions,
             descriptors,
             step,
             injection,
             observations,
             compared,
             divergence
           ) do
        {:ok, _, _, _, _} = next ->
          {:cont, next}

        error ->
          {:halt, error}
      end
    end)
  end

  defp replay_transitions(
         state,
         [],
         _descriptors,
         _step,
         _injection,
         observations,
         compared,
         divergence
       ),
       do: {:ok, state, observations, compared, divergence}

  defp replay_transitions(
         state,
         [transition | rest],
         descriptors,
         step,
         injection,
         observations,
         compared,
         divergence
       ) do
    operation = injection_for(injection, transition.id.sequence)
    fact = denormalize_fact(transition.fact)

    {state, injected_observations} = apply_injection(state, operation, fact, step, transition.id)

    {next, effects} =
      if operation == :drop, do: {state, []}, else: step.(state, fact_for(operation, fact))

    observation = %{
      id: transition.id,
      post: projection(next, descriptors),
      effects:
        effects
        |> Enum.with_index()
        |> Enum.map(fn {effect, index} ->
          %{index: index, value: normalize_effect(effect, descriptors)}
        end)
    }

    divergence =
      if is_nil(injection) and is_nil(divergence) do
        compare_transition(transition, state, observation, descriptors)
      else
        divergence
      end

    replay_transitions(
      next,
      rest,
      descriptors,
      step,
      injection,
      observations ++ injected_observations ++ [observation],
      compared + 1,
      divergence
    )
  rescue
    error -> {:error, {:replay_failed, transition.id, error}}
  end

  defp apply_injection(state, {:insert, injected}, _fact, step, id) do
    {next, effects} = step.(state, injected)
    observation = %{id: id, injected: :insert, fact: normalize_fact(injected), effects: effects}
    {next, [observation]}
  end

  defp apply_injection(state, _operation, _fact, _step, _id), do: {state, []}

  defp fact_for({:replace, fact}, _baseline), do: fact
  defp fact_for(_operation, baseline), do: baseline

  defp injection_for(nil, _sequence), do: nil
  defp injection_for(%{} = injections, sequence), do: Map.get(injections, sequence)
  defp injection_for({sequence, operation}, sequence), do: operation
  defp injection_for(_injection, _sequence), do: nil

  defp compare_transition(transition, pre_state, observation, descriptors) do
    cond do
      projection(pre_state, descriptors) != transition.pre ->
        %{
          id: transition.id,
          field: :pre,
          expected: transition.pre,
          actual: projection(pre_state, descriptors)
        }

      observation.post != transition.post ->
        %{id: transition.id, field: :post, expected: transition.post, actual: observation.post}

      observation.effects != transition.effects ->
        %{
          id: transition.id,
          field: :effects,
          expected: transition.effects,
          actual: observation.effects
        }

      true ->
        nil
    end
  end

  defp validate_recording(%Recording{header: %{format_version: @version}, incomplete: []}),
    do: :ok

  defp validate_recording(%Recording{header: %{format_version: @version}, incomplete: entries}) do
    {:error, {:incomplete_recording, Enum.map(entries, & &1.id)}}
  end

  defp validate_recording(%Recording{header: %{format_version: version}}),
    do: {:error, {:unsupported_format, version}}

  defp validate_recording(_), do: {:error, :invalid_recording}

  defp remember_causes(recorder, effects, transition_id) do
    effects
    |> Enum.with_index()
    |> Enum.reduce(recorder, fn
      {{:call_provider, ref, _}, index}, state ->
        put_cause(state, {:provider, ref}, transition_id, index)

      {{:run_tool, ref, _, _}, index}, state ->
        put_cause(state, {:tool, ref}, transition_id, index)

      _, state ->
        state
    end)
  end

  defp put_cause(recorder, key, transition_id, effect_index) do
    effect = %{transition: transition_id, effect_index: effect_index}
    %{recorder | causes: Map.put(recorder.causes, key, effect)}
  end

  defp cause(recorder, {:provider_result, ref, _}),
    do: Map.get(recorder.causes, {:provider, ref}, :external)

  defp cause(recorder, {:provider_delta, ref, _}),
    do: Map.get(recorder.causes, {:provider, ref}, :external)

  defp cause(recorder, {:tool_result, ref, _}),
    do: Map.get(recorder.causes, {:tool, ref}, :external)

  defp cause(recorder, {:tool_deferred, ref, _}),
    do: Map.get(recorder.causes, {:tool, ref}, :external)

  defp cause(recorder, {:tool_crashed, ref, _}),
    do: Map.get(recorder.causes, {:tool, ref}, :external)

  defp cause(recorder, {:tool_timeout, ref}),
    do: Map.get(recorder.causes, {:tool, ref}, :external)

  defp cause(_recorder, _fact), do: :external

  defp projection(core, descriptors \\ nil) do
    normalized = normalize_state(core, descriptors)

    %{
      fingerprint: fingerprint(normalized),
      phase: normalized.phase,
      next_ref: normalized.next_ref,
      history_length: length(normalized.history),
      history_fingerprint: fingerprint(normalized.history),
      config_fingerprint: fingerprint(normalized.config)
    }
  end

  defp normalize_state(%Core.State{} = state, descriptors \\ nil) do
    tools =
      state.config.tools
      |> Map.values()
      |> Enum.map(fn tool ->
        if descriptors, do: Map.fetch!(descriptors, tool.name), else: normalize_tool(tool)
      end)
      |> Enum.sort_by(& &1.name)

    normalized = %{
      config: %{
        system: state.config.system,
        tools: tools,
        max_iterations: state.config.max_iterations,
        max_tool_output_bytes: state.config.max_tool_output_bytes,
        provider_settings: Map.get(state.config, :provider_settings)
      },
      history: Enum.map(state.history, &normalize_message/1),
      phase: normalize_phase(state.phase),
      next_ref: state.next_ref
    }

    normalized =
      if state.deferred_calls == [],
        do: normalized,
        else: Map.put(normalized, :deferred_calls, state.deferred_calls)

    case state.streaming do
      nil -> normalized
      %{text: "", public_content: []} -> normalized
      streaming -> Map.put(normalized, :streaming, streaming)
    end
  end

  defp denormalize_state(state) do
    tools = state.config.tools |> Enum.map(&denormalize_tool/1) |> Tool.table()

    %Core.State{
      config: %Core.Config{
        system: state.config.system,
        tools: tools,
        max_iterations: state.config.max_iterations,
        max_tool_output_bytes: state.config.max_tool_output_bytes,
        provider_settings: Map.get(state.config, :provider_settings)
      },
      history: Enum.map(state.history, &denormalize_message/1),
      phase: denormalize_phase(state.phase),
      streaming: Map.get(state, :streaming),
      deferred_calls: Map.get(state, :deferred_calls, []),
      next_ref: state.next_ref
    }
  end

  defp normalize_fact({:provider_settings, settings}),
    do: %{kind: :provider_settings, settings: settings}

  defp normalize_fact({:ask_input, user}), do: %{kind: :ask_input, user: normalize_message(user)}

  defp normalize_fact({:ask, prompt}), do: %{kind: :ask, prompt: prompt}

  defp normalize_fact({:provider_delta, ref, text}),
    do: %{kind: :provider_delta, ref: ref, text: text}

  defp normalize_fact({:provider_result, ref, {:ok, message}}),
    do: %{kind: :provider_result, ref: ref, outcome: :ok, message: normalize_message(message)}

  defp normalize_fact({:provider_result, ref, {:error, error}}),
    do: %{kind: :provider_result, ref: ref, outcome: :error, error: normalize_error(error)}

  defp normalize_fact({:tool_result, ref, outcome}),
    do: %{kind: :tool_result, ref: ref, outcome: normalize_outcome(outcome)}

  defp normalize_fact({:tool_deferred, ref, system}),
    do: %{kind: :tool_deferred, ref: ref, system: system}

  defp normalize_fact({:instruction_context, system}),
    do: %{kind: :instruction_context, system: system}

  defp normalize_fact({:tool_crashed, ref, reason}),
    do: %{kind: :tool_crashed, ref: ref, reason: reason}

  defp normalize_fact({:tool_timeout, ref}), do: %{kind: :tool_timeout, ref: ref}
  defp normalize_fact(:interrupt), do: %{kind: :interrupt}

  defp denormalize_fact(%{kind: :provider_settings, settings: settings}),
    do: {:provider_settings, settings}

  defp denormalize_fact(%{kind: :ask_input, user: user}),
    do: {:ask_input, denormalize_message(user)}

  defp denormalize_fact(%{kind: :ask, prompt: prompt}), do: {:ask, prompt}

  defp denormalize_fact(%{kind: :provider_delta, ref: ref, text: text}),
    do: {:provider_delta, ref, text}

  defp denormalize_fact(%{kind: :provider_result, ref: ref, outcome: :ok, message: message}),
    do: {:provider_result, ref, {:ok, denormalize_message(message)}}

  defp denormalize_fact(%{kind: :provider_result, ref: ref, outcome: :error, error: error}),
    do: {:provider_result, ref, {:error, denormalize_error(error)}}

  defp denormalize_fact(%{kind: :tool_result, ref: ref, outcome: outcome}),
    do: {:tool_result, ref, denormalize_outcome(outcome)}

  defp denormalize_fact(%{kind: :tool_deferred, ref: ref, system: system}),
    do: {:tool_deferred, ref, system}

  defp denormalize_fact(%{kind: :instruction_context, system: system}),
    do: {:instruction_context, system}

  defp denormalize_fact(%{kind: :tool_crashed, ref: ref, reason: reason}),
    do: {:tool_crashed, ref, reason}

  defp denormalize_fact(%{kind: :tool_timeout, ref: ref}), do: {:tool_timeout, ref}
  defp denormalize_fact(%{kind: :interrupt}), do: :interrupt

  defp normalize_effect({:emit, event}, _tools), do: %{kind: :emit, event: normalize_event(event)}

  defp normalize_effect({:call_provider, ref, request}, tools) do
    %{
      kind: :call_provider,
      ref: ref,
      request: %{
        system: request.system,
        messages: Enum.map(request.messages, &normalize_message/1),
        tools:
          request.tools
          |> Enum.map(&Map.fetch!(tools, &1.name))
          |> Enum.sort_by(& &1.name)
      }
    }
  end

  defp normalize_effect({:run_tool, ref, call, tool}, tools) do
    %{kind: :run_tool, ref: ref, call: normalize_call(call), tool: Map.fetch!(tools, tool.name)}
  end

  defp normalize_phase(:idle), do: :idle

  defp normalize_phase({:calling_provider, ref, iteration}),
    do: %{kind: :calling_provider, ref: ref, iteration: iteration}

  defp normalize_phase({:running_tool, ref, call, rest, iteration}) do
    %{
      kind: :running_tool,
      ref: ref,
      call: normalize_call(call),
      remaining: Enum.map(rest, &normalize_call/1),
      iteration: iteration
    }
  end

  defp denormalize_phase(:idle), do: :idle

  defp denormalize_phase(%{kind: :calling_provider, ref: ref, iteration: iteration}),
    do: {:calling_provider, ref, iteration}

  defp denormalize_phase(%{kind: :running_tool} = phase) do
    {:running_tool, phase.ref, denormalize_call(phase.call),
     Enum.map(phase.remaining, &denormalize_call/1), phase.iteration}
  end

  defp normalize_message(%User{text: text, attachments: []}), do: %{kind: :user, text: text}

  defp normalize_message(%User{text: text, attachments: attachments}),
    do: %{
      kind: :user,
      text: text,
      attachments: Enum.map(attachments, &Elara.Attachment.metadata/1)
    }

  defp normalize_message(%Assistant{} = message) do
    %{
      kind: :assistant,
      text: message.text,
      tool_calls: Enum.map(message.tool_calls, &normalize_call/1),
      public_content: message.public_content,
      usage: message.usage,
      response_model: message.response_model,
      request_settings: message.request_settings,
      interrupted: message.interrupted
    }
  end

  defp normalize_message(%ToolResult{} = result) do
    %{
      kind: :tool_result,
      call_id: result.call_id,
      name: result.name,
      outcome: normalize_outcome(result.outcome)
    }
  end

  defp denormalize_message(%{kind: :user, text: text, attachments: attachments}),
    do: %User{text: text, attachments: attachments}

  defp denormalize_message(%{kind: :user, text: text}), do: %User{text: text}

  defp denormalize_message(%{kind: :assistant, text: text, tool_calls: calls} = message),
    do: %Assistant{
      text: text,
      tool_calls: Enum.map(calls, &denormalize_call/1),
      provider_state: Map.get(message, :provider_state),
      public_content: Map.get(message, :public_content, []),
      usage: Map.get(message, :usage),
      response_model: Map.get(message, :response_model),
      request_settings: Map.get(message, :request_settings),
      interrupted: Map.get(message, :interrupted, false)
    }

  defp denormalize_message(%{kind: :tool_result} = result),
    do: %ToolResult{
      call_id: result.call_id,
      name: result.name,
      outcome: denormalize_outcome(result.outcome)
    }

  defp normalize_call(%ToolCall{id: id, name: name, args: args} = call),
    do: %{id: id, name: name, args: normalize_args(args), output_index: call.output_index}

  defp denormalize_call(call),
    do: %ToolCall{
      id: call.id,
      name: call.name,
      args: denormalize_args(call.args),
      output_index: Map.get(call, :output_index)
    }

  defp normalize_args({:ok, arguments}), do: %{status: :ok, arguments: arguments}
  defp normalize_args({:malformed, raw}), do: %{status: :malformed, raw: raw}
  defp denormalize_args(%{status: :ok, arguments: arguments}), do: {:ok, arguments}
  defp denormalize_args(%{status: :malformed, raw: raw}), do: {:malformed, raw}

  defp normalize_outcome({status, text}) when status in [:ok, :error, :indeterminate],
    do: %{status: status, text: text}

  defp denormalize_outcome(%{status: status, text: text}), do: {status, text}

  defp normalize_error(%Provider.Error{} = error),
    do: %{kind: error.kind, message: error.message, status: error.status}

  defp denormalize_error(error),
    do: %Provider.Error{kind: error.kind, message: error.message, status: error.status}

  defp normalize_event(:provider_view_changed), do: %{kind: :provider_view_changed}

  defp normalize_event({:turn_started, prompt}), do: %{kind: :turn_started, prompt: prompt}

  defp normalize_event({:message_appended, message}),
    do: %{kind: :message_appended, message: normalize_message(message)}

  defp normalize_event({:message_appended, message, :streamed}),
    do: %{kind: :message_appended, message: normalize_message(message), streamed: true}

  defp normalize_event({:content_delta, id, text}),
    do: %{kind: :content_delta, message_id: id, text: text}

  defp normalize_event({:tool_started, call}),
    do: %{kind: :tool_started, call: normalize_call(call)}

  defp normalize_event({:turn_ended, outcome}),
    do: %{kind: :turn_ended, outcome: normalize_turn_outcome(outcome)}

  defp normalize_event({:turn_ended, outcome, :streamed}),
    do: %{kind: :turn_ended, outcome: normalize_turn_outcome(outcome), streamed: true}

  defp normalize_turn_outcome({:completed, text}), do: %{status: :completed, text: text}

  defp normalize_turn_outcome({:provider_error, error}),
    do: %{status: :provider_error, error: normalize_error(error)}

  defp normalize_turn_outcome(outcome) when outcome in [:turn_limit, :interrupted],
    do: %{status: outcome}

  defp normalize_tool(%Tool{} = tool) do
    %{
      name: tool.name,
      version: tool.version,
      description: tool.description,
      parameters: tool.parameters,
      capabilities: tool.capabilities,
      placement: tool.placement,
      mutating: tool.mutating,
      implementation: normalize_implementation(tool)
    }
  end

  defp normalize_implementation(%Tool{plugin: %PluginRef{} = plugin}) do
    %{kind: :plugin, id: plugin.id, version: plugin.version, generation: plugin.generation}
  end

  defp normalize_implementation(%Tool{run: {module, function}}) do
    %{kind: :mfa, module: Atom.to_string(module), function: Atom.to_string(function)}
  end

  defp denormalize_tool(tool) do
    %Tool{
      name: tool.name,
      version: tool.version,
      description: tool.description,
      parameters: tool.parameters,
      capabilities: tool.capabilities,
      placement: tool.placement,
      mutating: tool.mutating,
      run: {ReplayTool, :run}
    }
  end

  defp tool_descriptors(%Core.State{} = core) do
    Map.new(core.config.tools, fn {name, tool} -> {name, normalize_tool(tool)} end)
  end

  defp fingerprint(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({:elara_flight, @version, term}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp recording_path(nil, _incarnation), do: nil
  defp recording_path(path, incarnation), do: Path.rootname(path) <> "-#{incarnation}.flight"

  defp open_file(nil), do: nil

  defp open_file(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, file} = File.open(path, [:write, :binary])
    :ok = File.chmod(path, 0o600)
    :ok = IO.binwrite(file, @magic <> <<@version::unsigned-big-32>>)
    file
  end

  defp write_frame(%State{file: nil} = state, _frame), do: state

  defp write_frame(%State{file: file} = state, frame) do
    binary = :erlang.term_to_binary(frame, [:deterministic])
    :ok = IO.binwrite(file, <<byte_size(binary)::unsigned-big-32>> <> binary)
    state
  end

  defp sync(%State{file: nil} = state), do: state

  defp sync(%State{file: file} = state) do
    :ok = :file.sync(file)
    state
  end

  defp decode_file(<<@magic, @version::unsigned-big-32, rest::binary>>),
    do: decode_frames(rest, [])

  defp decode_file(<<@magic, version::unsigned-big-32, _::binary>>),
    do: {:error, {:unsupported_format, version}}

  defp decode_file(_), do: {:error, :invalid_recording}

  defp decode_frames(<<>>, frames), do: {:ok, Enum.reverse(frames)}
  defp decode_frames(binary, frames) when byte_size(binary) < 4, do: {:ok, Enum.reverse(frames)}

  defp decode_frames(<<size::unsigned-big-32, rest::binary>>, frames)
       when size <= @max_frame_bytes do
    if byte_size(rest) < size do
      {:ok, Enum.reverse(frames)}
    else
      <<frame::binary-size(^size), tail::binary>> = rest

      try do
        decode_frames(tail, [:erlang.binary_to_term(frame, [:safe]) | frames])
      rescue
        ArgumentError -> {:error, :invalid_frame}
      end
    end
  end

  defp decode_frames(_binary, _frames), do: {:error, :frame_too_large}

  defp assemble([%{type: :header} = header | frames]) do
    {segments, begins, transitions, incomplete, event_causes} =
      Enum.reduce(frames, {[], %{}, [], [], %{}}, fn
        %{type: :segment} = segment, {segments, begins, transitions, incomplete, events} ->
          {segments ++ [segment], begins, transitions, incomplete, events}

        %{type: :transition_begin, id: id} = begin,
        {segments, begins, transitions, incomplete, events} ->
          {segments, Map.put(begins, id, begin), transitions, incomplete, events}

        %{type: :transition_end, id: id} = ending,
        {segments, begins, transitions, incomplete, events} ->
          case Map.pop(begins, id) do
            {nil, begins} ->
              {segments, begins, transitions, [ending | incomplete], events}

            {begin, begins} ->
              transition = begin |> Map.drop([:type]) |> Map.merge(Map.drop(ending, [:type, :id]))
              {segments, begins, transitions ++ [transition], incomplete, events}
          end

        %{type: :event_link, event_sequence: sequence, effect: effect},
        {segments, begins, transitions, incomplete, events} ->
          {segments, begins, transitions, incomplete, Map.put(events, sequence, effect)}

        _frame, acc ->
          acc
      end)

    {:ok,
     %Recording{
       header: header,
       segments: segments,
       transitions: transitions,
       incomplete: incomplete ++ Map.values(begins),
       event_causes: event_causes
     }}
  end

  defp assemble(_), do: {:error, :invalid_recording}

  defp value(nil), do: nil
  defp value({_key, value}), do: value

  defp random_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
