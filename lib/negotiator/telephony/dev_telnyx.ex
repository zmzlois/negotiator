defmodule Negotiator.Telephony.DevTelnyx do
  @moduledoc """
  local telnyx adapter that records call-control commands instead of calling telnyx.
  """

  @behaviour Negotiator.Telephony

  @impl true
  def required_env, do: []

  @impl true
  def setup_plan,
    do: [
      "enable NEGOTIATOR_DEV_CONTROLS_ENABLED=1 and post telnyx payloads to /dev/telnyx/webhook"
    ]

  @impl true
  def answer(call_control_id) do
    record(call_control_id, :answer, %{})
    :ok
  end

  @impl true
  def start_streaming(call_control_id, opts \\ []) do
    record(call_control_id, :streaming_start, %{
      participant: Keyword.get(opts, :participant, :founder),
      stream_url:
        Keyword.get_lazy(opts, :stream_url, fn ->
          Negotiator.Env.media_stream_url(
            call_control_id,
            Keyword.get(opts, :participant, :founder)
          )
        end),
      stream_track: "both_tracks",
      stream_codec: "PCMU",
      stream_bidirectional_mode: "rtp",
      stream_bidirectional_codec: "PCMU",
      stream_bidirectional_target_legs: "self",
      stream_bidirectional_sampling_rate: 8_000,
      client_state: Keyword.get(opts, :client_state),
      command_id: Keyword.get(opts, :command_id)
    })

    :ok
  end

  @impl true
  def start_transcription(call_control_id, opts \\ []) do
    engine = Negotiator.Env.get("TELNYX_TRANSCRIPTION_ENGINE", "Telnyx")
    language = Negotiator.Env.get("TELNYX_TRANSCRIPTION_LANGUAGE", "en")

    record(call_control_id, :transcription_start, %{
      transcription_tracks:
        Keyword.get(
          opts,
          :transcription_tracks,
          Negotiator.Env.get("TELNYX_TRANSCRIPTION_TRACKS", "inbound")
        ),
      transcription_engine: engine,
      client_state: Keyword.get(opts, :client_state),
      command_id: Keyword.get(opts, :command_id),
      transcription_engine_config: %{
        transcription_engine: engine,
        language: language,
        interim_results:
          Negotiator.Env.get("TELNYX_TRANSCRIPTION_INTERIM_RESULTS", "true") in [
            "1",
            "true",
            "TRUE",
            "yes",
            "YES"
          ]
      }
    })

    :ok
  end

  @impl true
  def dial_investor(parent_call_control_id, investor_identity) do
    call_control_id = "dev-investor-#{System.unique_integer([:positive])}"

    record(parent_call_control_id, :dial_investor, %{
      to: investor_identity.number,
      from: Negotiator.Env.get("TELNYX_PHONE_NUMBER", "+15550000000"),
      connection_id: Negotiator.Env.get("TELNYX_CONNECTION_ID", "dev-connection"),
      investor_identity: investor_identity,
      outbound_call_control_id: call_control_id
    })

    {:ok, %{data: %{"call_control_id" => call_control_id}}}
  end

  @impl true
  def bridge(call_control_id, call_control_id_to_bridge_with) do
    record(call_control_id, :bridge, %{
      call_control_id: call_control_id_to_bridge_with,
      prevent_double_bridge: true
    })

    :ok
  end

  @doc """
  returns recorded command intents for a call.
  """
  def commands(call_control_id) do
    ensure_agent()
    Agent.get(__MODULE__, &Map.get(&1, call_control_id, []))
  end

  @doc """
  clears recorded command intents for a call.
  """
  def clear(call_control_id) do
    ensure_agent()
    Agent.update(__MODULE__, &Map.delete(&1, call_control_id))
    :ok
  end

  defp record(call_control_id, command, payload) do
    ensure_agent()

    entry = %{
      command: command,
      payload: payload,
      occurred_at: DateTime.utc_now()
    }

    Agent.update(__MODULE__, fn commands ->
      Map.update(commands, call_control_id, [entry], &(&1 ++ [entry]))
    end)
  end

  defp ensure_agent do
    case Agent.start_link(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
