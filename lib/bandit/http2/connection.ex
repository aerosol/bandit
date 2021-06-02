defmodule Bandit.HTTP2.Connection do
  @moduledoc """
  Represents the state of an HTTP/2 connection
  """

  defstruct local_settings: %{},
            remote_settings: %{},
            send_header_state: HPack.Table.new(4096),
            recv_header_state: HPack.Table.new(4096),
            last_local_stream_id: 0,
            last_remote_stream_id: 0,
            streams: %{},
            plug: nil

  require Integer

  alias Bandit.HTTP2.{Constants, Frame, Stream}

  def init(socket, plug) do
    socket
    |> ThousandIsland.Socket.recv(24)
    |> case do
      {:ok, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"} ->
        connection = %__MODULE__{plug: plug}
        # Send SETTINGS frame per RFC7540§3.5
        %Frame.Settings{ack: false, settings: connection.local_settings}
        |> send_frame(socket)

        {:ok, connection}

      _ ->
        {:error, "Did not receive expected HTTP/2 connection preface (RFC7540§3.5)"}
    end
  end

  def handle_frame(%Frame.Headers{end_headers: true} = frame, socket, connection) do
    with {:ok, recv_header_state, headers} <-
           HPack.decode(frame.header_block_fragment, connection.recv_header_state),
         {:odd_stream_id, true} <- {:odd_stream_id, Integer.is_odd(frame.stream_id)},
         {:new_stream_id, true} <-
           {:new_stream_id, frame.stream_id > connection.last_remote_stream_id},
         stream_state <- if(frame.end_stream, do: :remote_closed, else: :open),
         %{address: peer} <- ThousandIsland.Socket.peer_info(socket),
         {:ok, pid} <- Stream.start_link(self(), frame.stream_id, peer, headers, connection.plug) do
      connection =
        connection
        |> Map.put(:recv_header_state, recv_header_state)
        |> Map.put(:last_remote_stream_id, frame.stream_id)
        |> Map.update!(:streams, &Map.put(&1, frame.stream_id, {stream_state, pid}))

      {:ok, :continue, connection}
    else
      {:error, :decode_error} -> close(Constants.compression_error(), socket, connection)
      # https://github.com/OleMchls/elixir-hpack/issues/16
      other when is_binary(other) -> close(Constants.compression_error(), socket, connection)
      {:odd_stream_id, false} -> close(Constants.protocol_error(), socket, connection)
      {:new_stream_id, false} -> close(Constants.protocol_error(), socket, connection)
    end
  end

  def handle_frame(%Frame.Settings{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Settings{ack: false} = frame, socket, connection) do
    %Frame.Settings{ack: true} |> send_frame(socket)
    {:ok, :continue, %{connection | remote_settings: frame.settings}}
  end

  def handle_frame(%Frame.Ping{ack: true}, _socket, connection) do
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Ping{ack: false} = frame, socket, connection) do
    %Frame.Ping{ack: true, payload: frame.payload} |> send_frame(socket)
    {:ok, :continue, connection}
  end

  def handle_frame(%Frame.Goaway{}, socket, connection) do
    close(Constants.no_error(), socket, connection)
  end

  def handle_error(0, error_code, _reason, socket, connection) do
    close(error_code, socket, connection)
  end

  def send_headers(stream_id, pid, headers, end_stream, socket, connection) do
    with {:stream, {stream_state, ^pid}} <- {:stream, Map.get(connection.streams, stream_id)},
         {:stream_state, true} <- {:stream_state, stream_state in [:open, :remote_closed]},
         {:ok, send_header_state, header_block} <-
           HPack.encode(headers, connection.send_header_state) do
      %Frame.Headers{
        stream_id: stream_id,
        end_headers: true,
        end_stream: end_stream,
        header_block_fragment: header_block
      }
      |> send_frame(socket)

      connection =
        connection
        |> Map.put(:send_header_state, send_header_state)
        |> Map.update!(:streams, &update_stream(&1, stream_id, stream_state, pid, end_stream))

      {:ok, connection}
    else
      {:stream, nil} ->
        {:error, :invalid_stream}

      {:stream, _} ->
        {:error, :not_owner}

      {:stream_state, false} ->
        {:error, :local_end_closed}

      {:error, :encode_error} ->
        # Not explcitily documented in RFC7540
        close(Constants.compression_error(), socket, connection)
        {:close, :encode_error}
    end
  end

  def send_data(stream_id, pid, data, end_stream, socket, connection) do
    with {:stream, {stream_state, ^pid}} <- {:stream, Map.get(connection.streams, stream_id)},
         {:stream_state, true} <- {:stream_state, stream_state in [:open, :remote_closed]} do
      %Frame.Data{stream_id: stream_id, end_stream: end_stream, data: data}
      |> send_frame(socket)

      connection =
        connection
        |> Map.update!(:streams, &update_stream(&1, stream_id, stream_state, pid, end_stream))

      {:ok, connection}
    else
      {:stream, nil} -> {:error, :invalid_stream}
      {:stream, _} -> {:error, :not_owner}
      {:stream_state, false} -> {:error, :local_end_closed}
    end
  end

  # State management per RFC7540§5.1
  defp update_stream(streams, stream_id, stream_state, pid, end_stream) do
    if end_stream do
      case stream_state do
        :open -> Map.put(streams, stream_id, {:local_closed, pid})
        :remote_closed -> Map.delete(streams, stream_id)
      end
    else
      streams
    end
  end

  def stream_terminated(pid, _reason, _socket, connection) do
    connection.streams
    |> Enum.find(fn {_stream_id, {_stream_state, stream_pid}} -> stream_pid == pid end)
    |> case do
      {stream_id, _} ->
        {:ok, connection |> Map.update!(:streams, &Map.delete(&1, stream_id))}

      nil ->
        {:ok, connection}
    end
  end

  defp close(error_code, socket, connection) do
    %Frame.Goaway{last_stream_id: connection.last_remote_stream_id, error_code: error_code}
    |> send_frame(socket)

    {:ok, :close, connection}
  end

  defp send_frame(frame, socket) do
    ThousandIsland.Socket.send(socket, Frame.serialize(frame))
  end
end