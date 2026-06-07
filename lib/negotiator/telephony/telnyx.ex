defmodule Negotiator.Telephony.Telnyx do
  @moduledoc """
  telnyx call control and media streaming adapter.
  """

  @behaviour Negotiator.Telephony

  alias Negotiator.Env

  require Logger

  @base_url "https://api.telnyx.com/v2"

  @impl true
  def required_env, do: Env.required(:telnyx)

  @impl true
  def setup_plan do
    [
      "configure the telnyx number #{env_or_placeholder("TELNYX_PHONE_NUMBER")} to use call control",
      "set the telnyx call control webhook to #{env_or_placeholder("PUBLIC_BASE_URL")}/telnyx/webhook",
      "copy the telnyx public key into TELNYX_PUBLIC_KEY so signed webhooks verify",
      "start this app with NEGOTIATOR_HTTP_ENABLED=1 mix run --no-halt",
      "on call.initiated, the app answers; on call.answered, it starts bidirectional PCMU media streaming and telnyx in-call transcription",
      "on call.dtmf.received digit 3, 4, or 5, the app changes room state and queues the right voice agent work"
    ]
  end

  @doc """
  answers an inbound call.
  """
  @impl true
  def answer(call_control_id, opts \\ []) do
    post_command(call_control_id, "answer", %{}, opts)
  end

  @doc """
  starts bidirectional media streaming for a call.
  """
  @impl true
  def start_streaming(call_control_id, opts \\ []) do
    participant =
      Keyword.get(opts, :participant, Env.get("NEGOTIATOR_PHONE_PARTICIPANT", "founder"))

    body =
      %{
        stream_url:
          Keyword.get_lazy(opts, :stream_url, fn ->
            Env.media_stream_url(call_control_id, participant)
          end),
        stream_track:
          Keyword.get(opts, :stream_track, Env.get("TELNYX_STREAM_TRACK", "both_tracks")),
        stream_codec: Keyword.get(opts, :stream_codec, Env.get("TELNYX_STREAM_CODEC", "PCMU")),
        stream_bidirectional_mode:
          Keyword.get(
            opts,
            :stream_bidirectional_mode,
            Env.get("TELNYX_STREAM_BIDIRECTIONAL_MODE", "rtp")
          ),
        stream_bidirectional_codec:
          Keyword.get(
            opts,
            :stream_bidirectional_codec,
            Env.get("TELNYX_STREAM_BIDIRECTIONAL_CODEC", "PCMU")
          ),
        stream_bidirectional_target_legs:
          Keyword.get(
            opts,
            :stream_bidirectional_target_legs,
            Env.get("TELNYX_STREAM_BIDIRECTIONAL_TARGET_LEGS", "self")
          ),
        stream_bidirectional_sampling_rate:
          Keyword.get(
            opts,
            :stream_bidirectional_sampling_rate,
            integer_env("TELNYX_STREAM_BIDIRECTIONAL_SAMPLING_RATE", 8_000)
          )
      }
      |> put_if_present(:client_state, Keyword.get(opts, :client_state))
      |> put_if_present(:command_id, Keyword.get(opts, :command_id))

    post_command(call_control_id, "streaming_start", body, opts)
  end

  @doc """
  starts telnyx in-call transcription for a call.
  """
  @impl true
  def start_transcription(call_control_id, opts \\ []) do
    if transcription_enabled?(opts) do
      engine =
        Keyword.get(
          opts,
          :transcription_engine,
          Env.get("TELNYX_TRANSCRIPTION_ENGINE", "Telnyx")
        )

      language = Keyword.get(opts, :language, Env.get("TELNYX_TRANSCRIPTION_LANGUAGE", "en"))
      model = Keyword.get(opts, :transcription_model, Env.get("TELNYX_TRANSCRIPTION_MODEL"))

      body =
        %{
          language: language,
          transcription_engine: engine,
          transcription_engine_config:
            Keyword.get_lazy(opts, :transcription_engine_config, fn ->
              transcription_engine_config(engine, language, model, opts)
            end),
          transcription_tracks:
            Keyword.get(
              opts,
              :transcription_tracks,
              Env.get("TELNYX_TRANSCRIPTION_TRACKS", "inbound")
            )
        }
        |> put_if_present(
          :transcription_model,
          model
        )
        |> put_if_present(
          :client_state,
          Keyword.get(opts, :client_state, Env.get("TELNYX_TRANSCRIPTION_CLIENT_STATE"))
        )
        |> put_if_present(:command_id, Keyword.get(opts, :command_id))

      post_command(call_control_id, "transcription_start", body, opts)
    else
      Logger.info("telnyx transcription disabled", call_id: call_control_id)
      :disabled
    end
  end

  @doc """
  places the outbound investor leg that will later be bridged to the founder.
  """
  @impl true
  def dial_investor(parent_call_control_id, investor_identity) do
    investor_identity = Negotiator.InvestorIdentity.normalize(investor_identity)

    body = %{
      to: investor_identity.number,
      from: Env.fetch!("TELNYX_PHONE_NUMBER"),
      connection_id: Env.fetch!("TELNYX_CONNECTION_ID"),
      command_id: command_id("investor-dial", parent_call_control_id),
      client_state: investor_client_state(parent_call_control_id, investor_identity)
    }

    post_call(body)
  end

  @doc """
  bridges two call-control legs.
  """
  @impl true
  def bridge(call_control_id, call_control_id_to_bridge_with) do
    body = %{
      call_control_id: call_control_id_to_bridge_with,
      command_id: command_id("investor-bridge", call_control_id),
      prevent_double_bridge: true,
      client_state:
        call_control_id
        |> bridge_client_state(call_control_id_to_bridge_with)
    }

    post_command(call_control_id, "bridge", body, [])
  end

  defp post_command(call_control_id, command, body, opts) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> Env.fetch!("TELNYX_API_KEY") end)
    url = "#{@base_url}/calls/#{call_control_id}/actions/#{command}"
    started_at = System.monotonic_time(:millisecond)

    Logger.info("telnyx command started",
      call_id: call_control_id,
      command: command,
      body: safe_body(body)
    )

    http_post = Keyword.get(opts, :http_post, &Negotiator.Tools.http_post/2)

    result =
      http_post.(url,
        auth: {:bearer, api_key},
        json: body,
        receive_timeout: 15_000
      )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    log_result(result, call_control_id, command, duration_ms)
    result
  end

  defp post_call(body) do
    api_key = Env.fetch!("TELNYX_API_KEY")
    url = "#{@base_url}/calls"
    started_at = System.monotonic_time(:millisecond)

    Logger.info("telnyx outbound call started",
      to: body.to,
      from: body.from,
      connection_id: body.connection_id
    )

    result =
      Negotiator.Tools.http_post(url,
        auth: {:bearer, api_key},
        json: body,
        receive_timeout: 15_000
      )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    log_result(result, "outbound", "calls.create", duration_ms)
    result
  end

  defp env_or_placeholder(name), do: Env.get(name, "<#{name}>")

  defp transcription_engine_config(engine, language, model, opts) do
    %{
      transcription_engine: engine,
      language: language,
      interim_results:
        Keyword.get(
          opts,
          :interim_results,
          enabled_env?("TELNYX_TRANSCRIPTION_INTERIM_RESULTS", true)
        )
    }
    |> put_if_present(:transcription_model, model)
  end

  defp integer_env(name, default) do
    case Integer.parse(Env.get(name, "")) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp transcription_enabled?(opts) do
    Keyword.get(opts, :transcription_enabled?, Env.get("TELNYX_TRANSCRIPTION_ENABLED", "1")) in [
      true,
      "1",
      "true",
      "TRUE",
      "yes",
      "YES"
    ]
  end

  defp enabled_env?(name, default) do
    case Env.get(name) do
      nil -> default
      "" -> default
      value -> value in [true, "1", "true", "TRUE", "yes", "YES"]
    end
  end

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp investor_client_state(parent_call_control_id, investor_identity) do
    %{
      kind: :investor_outbound,
      parent_call_control_id: parent_call_control_id,
      investor_identity: Negotiator.InvestorIdentity.metadata(investor_identity)
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp bridge_client_state(call_control_id, call_control_id_to_bridge_with) do
    %{
      kind: :investor_bridge,
      call_control_id: call_control_id,
      call_control_id_to_bridge_with: call_control_id_to_bridge_with
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp command_id(prefix, call_control_id) do
    "#{prefix}-#{System.unique_integer([:positive])}-#{:erlang.phash2(call_control_id)}"
  end

  defp log_result({:ok, %{status: status}}, call_id, command, duration_ms)
       when status in 200..299 do
    Logger.info("telnyx command finished",
      call_id: call_id,
      command: command,
      status: status,
      duration_ms: duration_ms
    )
  end

  defp log_result({:ok, %{status: status, body: body}}, call_id, command, duration_ms) do
    Logger.warning("telnyx command http error",
      call_id: call_id,
      command: command,
      status: status,
      duration_ms: duration_ms,
      body: inspect(body, limit: 8, printable_limit: 240)
    )
  end

  defp log_result({:error, reason}, call_id, command, duration_ms) do
    Logger.warning("telnyx command failed",
      call_id: call_id,
      command: command,
      duration_ms: duration_ms,
      reason: inspect(reason)
    )
  end

  defp safe_body(body), do: inspect(body, limit: 8, printable_limit: 240)
end
