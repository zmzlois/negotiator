defmodule Negotiator.Telephony.MediaSocket do
  @moduledoc """
  websocket handler for telnyx media streaming.
  """

  @behaviour WebSock

  alias Negotiator.{CallEvent, CallSession, CallSupervisor}
  alias Negotiator.Telephony.Telnyx.MediaStream

  require Logger

  @impl true
  def init(%{call_control_id: call_id, participant: participant}) do
    participant = MediaStream.normalize_participant(participant)
    Logger.info("media socket initialized", call_id: call_id, participant: participant)
    {:ok, call_session} = CallSupervisor.start_or_get_call(call_id: call_id)

    CallSession.handle_event(
      call_session,
      CallEvent.register_media_socket(self(), %{participant: participant})
    )

    {:ok, initial_state(call_id, call_session, participant)}
  end

  def init(%{call_control_id: call_id}) do
    Logger.info("media socket initialized", call_id: call_id)
    {:ok, call_session} = CallSupervisor.start_or_get_call(call_id: call_id)
    participant = :founder

    CallSession.handle_event(
      call_session,
      CallEvent.register_media_socket(self(), %{participant: participant})
    )

    {:ok, initial_state(call_id, call_session, participant)}
  end

  def init(%{}) do
    Logger.info("media socket initialized without call id")

    {:ok, initial_state(nil, nil, :founder)}
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    case MediaStream.decode_text(payload) do
      {:ok, event} ->
        handle_event(event, state)

      {:error, reason} ->
        Logger.warning("media socket received invalid json",
          call_id: state.call_id,
          reason: inspect(reason),
          bytes: byte_size(payload)
        )

        {:ok, state}
    end
  end

  def handle_in(_message, state), do: {:ok, state}

  @fade_buffer_bytes 2_400
  @rtp_frame_bytes 640
  @frame_duration_ms 80
  @ulaw_silence 0xFF

  @impl true
  def handle_info({:outbound_audio, bytes, _format}, state) when is_binary(bytes) do
    Logger.info("media socket sending outbound audio",
      call_id: state.call_id,
      stream_id: state.stream_id,
      bytes: byte_size(bytes)
    )

    tail = trim_outbound_tail(state.outbound_tail <> bytes)
    {:push, {:text, MediaStream.encode_media(bytes)}, %{state | outbound_tail: tail}}
  end

  def handle_info({:clear_audio_with_fade, reason}, state) do
    Logger.info("media socket sending clear with fade",
      call_id: state.call_id,
      reason: reason,
      fade_bytes: byte_size(state.outbound_tail)
    )

    faded = Negotiator.Voice.Ulaw.fade_out(state.outbound_tail)
    state = %{state | outbound_tail: <<>>, outbound_frame_queue: [], pending_mark: nil}

    if byte_size(faded) > 0 do
      send(self(), {:clear_audio, reason})
      {:push, {:text, MediaStream.encode_media(faded)}, state}
    else
      {:push, {:text, MediaStream.encode_clear()}, state}
    end
  end

  def handle_info({:clear_audio, reason}, state) do
    Logger.info("media socket sending clear", call_id: state.call_id, reason: reason)
    {:push, {:text, MediaStream.encode_clear()},
     %{state | outbound_tail: <<>>, outbound_frame_queue: [], pending_mark: nil}}
  end

  def handle_info({:mark_audio, name}, state) do
    Logger.info("media socket sending mark",
      call_id: state.call_id,
      stream_id: state.stream_id,
      mark: name
    )

    {:push, {:text, MediaStream.encode_mark(name)}, state}
  end

  def handle_info({:play_audio, bytes, mark_name}, state) when is_binary(bytes) do
    Logger.info("media socket sending outbound audio",
      call_id: state.call_id,
      stream_id: state.stream_id,
      bytes: byte_size(bytes),
      mark: mark_name
    )

    ref = make_ref()
    frames = chunk_rtp_frames(bytes)
    state = %{state | outbound_frame_queue: frames, pending_mark: mark_name, frame_dispatch_ref: ref}
    dispatch_next_frame(state, ref)
  end

  def handle_info({:dispatch_next_frame, ref}, %{frame_dispatch_ref: ref} = state) do
    dispatch_next_frame(state, ref)
  end

  def handle_info({:dispatch_next_frame, _stale_ref}, state) do
    {:ok, state}
  end

  def handle_info(message, state) do
    Logger.debug("media socket ignored info: #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("media socket terminating", call_id: state.call_id)

    if state.call_session && Process.alive?(state.call_session) do
      CallSession.handle_event(
        state.call_session,
        CallEvent.provider(:media_socket, :media_socket_closed, %{
          call_id: state.call_id,
          participant: state.participant,
          pid: inspect(self())
        })
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp handle_event(%{"event" => "connected"}, state) do
    Logger.info("media socket connected", call_id: state.call_id)

    if state.call_session do
      CallSession.handle_event(
        state.call_session,
        CallEvent.provider(:media_socket, :media_socket_connected, %{call_id: state.call_id})
      )
    end

    {:ok, state}
  end

  defp handle_event(%{"event" => "start", "start" => start} = event, state) do
    call_id = start["call_control_id"] || state.call_id
    stream_id = MediaStream.stream_id(event, state.stream_id)

    Logger.info("media stream started",
      call_id: call_id,
      stream_id: stream_id,
      media_format: inspect(start["media_format"])
    )

    {:ok, call_session} = CallSupervisor.start_or_get_call(call_id: call_id)

    CallSession.handle_event(
      call_session,
      CallEvent.register_media_socket(self(), %{participant: state.participant})
    )

    CallSession.handle_event(
      call_session,
      CallEvent.provider(:media_socket, :media_stream_started, start)
    )

    {:ok,
     %{
       state
       | call_id: call_id,
         stream_id: stream_id,
         call_session_id: start["call_session_id"],
         media_format: start["media_format"],
         call_session: call_session
     }}
  end

  defp handle_event(%{"event" => "media", "media" => %{"payload" => payload} = media}, state)
       when is_binary(payload) do
    case MediaStream.decode_media(%{"event" => "media", "media" => media}) do
      {:ok, bytes, metadata} ->
        track = metadata.track

        unless state.first_media_logged? do
          Logger.info("media socket received first media frame",
            call_id: state.call_id,
            track: track,
            raw_track: metadata.raw_track,
            bytes: byte_size(bytes),
            timestamp: metadata.timestamp
          )
        end

        if track == :inbound and state.call_session do
          CallSession.handle_event(
            state.call_session,
            CallEvent.media_frame(bytes, Map.put(metadata, :participant, state.participant))
          )
        end

        {:ok, %{state | first_media_logged?: true}}

      {:error, reason} ->
        Logger.warning("media socket dropped media frame",
          call_id: state.call_id,
          reason: reason
        )

        if state.call_session do
          CallSession.handle_event(
            state.call_session,
            CallEvent.provider(:media_socket, :media_frame_dropped, %{reason: reason})
          )
        end

        {:ok, state}
    end
  end

  defp handle_event(%{"event" => "dtmf", "dtmf" => %{"digit" => digit}}, state) do
    Logger.info("media socket received dtmf", call_id: state.call_id, digit: digit)

    if state.call_session do
      CallSession.handle_event(state.call_session, CallEvent.dtmf(digit))
    end

    {:ok, state}
  end

  defp handle_event(%{"event" => "mark", "mark" => %{"name" => name} = mark} = event, state) do
    Logger.info("media socket received mark", call_id: state.call_id, mark: name)

    if state.call_session do
      metadata =
        mark
        |> Map.put("stream_id", event["stream_id"])
        |> Map.put("sequence_number", event["sequence_number"])

      CallSession.handle_event(state.call_session, CallEvent.media_mark(name, metadata))
    end

    {:ok, state}
  end

  defp handle_event(%{"event" => "stop"} = event, state) do
    Logger.info("media stream stopped", call_id: state.call_id)

    if state.call_session do
      CallSession.handle_event(
        state.call_session,
        CallEvent.provider(:media_socket, :media_stream_stopped, event)
      )

      CallSession.handle_event(state.call_session, CallEvent.end_call(:media_stream_stopped))
    end

    {:stop, :normal, state}
  end

  defp handle_event(%{"event" => "error"} = event, state) do
    Logger.warning("media stream error", call_id: state.call_id, event: inspect(event, limit: 8))

    if state.call_session,
      do:
        CallSession.handle_event(
          state.call_session,
          CallEvent.provider(:media_socket, :media_stream_error, event)
        )

    {:ok, state}
  end

  defp handle_event(event, state) do
    Logger.debug("media socket ignored event",
      call_id: state.call_id,
      event: inspect(event, limit: 8, printable_limit: 240)
    )

    if state.call_session do
      CallSession.handle_event(
        state.call_session,
        CallEvent.provider(:media_socket, :media_stream_event_ignored, event)
      )
    end

    {:ok, state}
  end

  defp initial_state(call_id, call_session, participant) do
    %{
      call_id: call_id,
      stream_id: nil,
      call_session_id: nil,
      media_format: nil,
      call_session: call_session,
      participant: participant,
      first_media_logged?: false,
      inbound_drops: %{},
      outbound_tail: <<>>,
      outbound_frame_queue: [],
      pending_mark: nil,
      frame_dispatch_ref: nil
    }
  end

  defp dispatch_next_frame(%{outbound_frame_queue: []} = state, _ref) do
    if state.pending_mark do
      Logger.info("media socket sending mark",
        call_id: state.call_id,
        stream_id: state.stream_id,
        mark: state.pending_mark
      )

      {:push, {:text, MediaStream.encode_mark(state.pending_mark)}, %{state | pending_mark: nil}}
    else
      {:ok, state}
    end
  end

  defp dispatch_next_frame(%{outbound_frame_queue: [frame | rest]} = state, ref) do
    if rest != [] do
      Process.send_after(self(), {:dispatch_next_frame, ref}, @frame_duration_ms)
    else
      send(self(), {:dispatch_next_frame, ref})
    end

    tail = trim_outbound_tail(state.outbound_tail <> frame)
    {:push, {:text, MediaStream.encode_media(frame)}, %{state | outbound_frame_queue: rest, outbound_tail: tail}}
  end

  defp chunk_rtp_frames(<<>>), do: []

  defp chunk_rtp_frames(bytes) do
    full_frames = for <<frame::binary-size(@rtp_frame_bytes) <- bytes>>, do: frame
    remainder_size = rem(byte_size(bytes), @rtp_frame_bytes)

    if remainder_size > 0 do
      last = binary_part(bytes, byte_size(bytes) - remainder_size, remainder_size)
      padding = :binary.copy(<<@ulaw_silence>>, @rtp_frame_bytes - remainder_size)
      full_frames ++ [last <> padding]
    else
      full_frames
    end
  end

  defp trim_outbound_tail(buffer) when byte_size(buffer) > @fade_buffer_bytes do
    skip = byte_size(buffer) - @fade_buffer_bytes
    binary_part(buffer, skip, @fade_buffer_bytes)
  end

  defp trim_outbound_tail(buffer), do: buffer
end
