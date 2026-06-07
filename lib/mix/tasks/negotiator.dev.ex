defmodule Mix.Tasks.Negotiator.Dev do
  @moduledoc """
  runs the local http app with an ngrok tunnel.
  """

  use Mix.Task

  alias Negotiator.Env

  @shortdoc "runs the local http app and ngrok tunnel"

  @health_attempts 50
  @health_sleep_ms 100
  @ngrok_attempts 80
  @ngrok_sleep_ms 250
  @ngrok_api "http://127.0.0.1:4040/api/tunnels"

  @impl true
  def run(_args) do
    System.put_env("NEGOTIATOR_HTTP_ENABLED", "1")
    System.put_env("NEGOTIATOR_LOG_LEVEL", System.get_env("NEGOTIATOR_LOG_LEVEL") || "info")

    preferred_port = Env.port()

    case existing_dev_runtime(preferred_port) do
      {:ok, public_url} ->
        System.put_env("PUBLIC_BASE_URL", public_url)
        print_ready(preferred_port, health_url(preferred_port), public_url, :existing)

      :not_running ->
        start_dev_runtime(preferred_port)
    end
  end

  defp start_dev_runtime(preferred_port) do
    port = choose_port(preferred_port)
    System.put_env("PORT", Integer.to_string(port))

    Mix.Task.run("app.start")

    health_url = health_url(port)
    wait_for_health!(health_url)

    ngrok = ngrok_executable!()

    {ngrok_port, public_url} =
      case existing_ngrok_tunnel(port) do
        {:ok, public_url} ->
          {nil, public_url}

        :not_found ->
          ensure_no_conflicting_ngrok_tunnel!(port)
          ngrok_port = start_ngrok!(ngrok, port)
          {ngrok_port, wait_for_ngrok_url!(port)}
      end

    System.put_env("PUBLIC_BASE_URL", public_url)

    print_ready(port, health_url, public_url, :started)

    if ngrok_port do
      wait_until_stopped(ngrok_port)
    end
  end

  defp wait_for_health!(url) do
    if wait_until(@health_attempts, @health_sleep_ms, fn -> http_ok?(url) end) do
      :ok
    else
      Mix.raise("local http app did not answer #{url}")
    end
  end

  defp existing_dev_runtime(port) do
    with {:ok, public_url} <- existing_ngrok_tunnel(port),
         true <- negotiator_runtime?(port) do
      {:ok, public_url}
    else
      _missing -> :not_running
    end
  end

  defp negotiator_runtime?(port) do
    url = "http://127.0.0.1:#{port}/runtime"

    with {:ok, {{_, 200, _}, _headers, body}} <- http_get(url),
         {:ok, %{"app" => "negotiator"}} <- Jason.decode(to_string(body)) do
      true
    else
      _other -> false
    end
  end

  defp choose_port(preferred_port) do
    case available_port(preferred_port, 20) do
      ^preferred_port ->
        preferred_port

      port ->
        Mix.shell().info(
          "port #{preferred_port} is in use, running negotiator dev on port #{port}"
        )

        port
    end
  end

  defp available_port(port, 0), do: Mix.raise("could not find an available port near #{port}")

  defp available_port(port, attempts_left) do
    if port_available?(port) do
      port
    else
      available_port(port + 1, attempts_left - 1)
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, _reason} ->
        false
    end
  end

  defp ngrok_executable! do
    System.find_executable("ngrok") || Mix.raise("ngrok is not installed or not on PATH")
  end

  defp start_ngrok!(ngrok, port) do
    Port.open({:spawn_executable, ngrok}, [
      :binary,
      :exit_status,
      args: ["http", Integer.to_string(port), "--log=stdout"]
    ])
  rescue
    error -> Mix.raise("failed to start ngrok: #{Exception.message(error)}")
  end

  defp wait_for_ngrok_url!(port) do
    case wait_until_value(@ngrok_attempts, @ngrok_sleep_ms, fn ->
           case existing_ngrok_tunnel(port) do
             {:ok, public_url} -> public_url
             :not_found -> nil
           end
         end) do
      {:ok, public_url} -> public_url
      :error -> Mix.raise("ngrok did not expose a public tunnel through #{@ngrok_api}")
    end
  end

  defp existing_ngrok_tunnel(port) do
    port
    |> ngrok_tunnel_for_port()
    |> case do
      %{public_url: public_url} when is_binary(public_url) -> {:ok, public_url}
      nil -> :not_found
    end
  end

  defp ngrok_tunnel_for_port(port) do
    Enum.find(ngrok_tunnels(), fn tunnel ->
      tunnel[:port] == port and String.starts_with?(tunnel[:public_url] || "", "https://")
    end)
  end

  defp ensure_no_conflicting_ngrok_tunnel!(port) do
    case ngrok_tunnels() do
      [] ->
        :ok

      tunnels ->
        summary =
          tunnels
          |> Enum.map_join(", ", fn tunnel ->
            "#{tunnel[:public_url]} -> #{tunnel[:addr]}"
          end)

        Mix.raise(
          "ngrok is already running but not forwarding port #{port}: #{summary}. stop the existing ngrok process or set PORT to the forwarded app port."
        )
    end
  end

  defp ngrok_tunnels do
    with {:ok, {{_, 200, _}, _headers, body}} <- http_get(@ngrok_api),
         {:ok, %{"tunnels" => tunnels}} <- Jason.decode(to_string(body)) do
      Enum.map(tunnels, &normalize_ngrok_tunnel/1)
    else
      _missing -> []
    end
  end

  defp normalize_ngrok_tunnel(tunnel) do
    addr = get_in(tunnel, ["config", "addr"]) || ""

    %{
      public_url: tunnel["public_url"],
      addr: addr,
      port: uri_port(addr)
    }
  end

  defp uri_port(addr) do
    case URI.parse(addr) do
      %URI{port: port} when is_integer(port) -> port
      _other -> nil
    end
  end

  defp print_ready(port, health_url, public_url, source) do
    IO.puts("""
    negotiator dev is #{ready_source(source)}

    local:
      port: #{port}
      health: #{health_url}

    ngrok:
      public base: #{public_url}
      dashboard: http://127.0.0.1:4040

    telnyx:
      webhook: #{public_url}/telnyx/webhook
      media websocket: #{String.replace_prefix(public_url, "https://", "wss://")}/media/:call_control_id/founder

    press ctrl-c to stop negotiator and ngrok.
    """)
  end

  defp ready_source(:existing), do: "already running"
  defp ready_source(:started), do: "running"

  defp wait_until_stopped(ngrok_port) do
    receive do
      {^ngrok_port, {:exit_status, status}} ->
        Mix.raise("ngrok exited with status #{status}")

      {_port, {:data, _line}} ->
        wait_until_stopped(ngrok_port)
    end
  end

  defp wait_until(attempts, sleep_ms, fun) do
    wait_until_value(attempts, sleep_ms, fn ->
      if fun.(), do: true
    end) == {:ok, true}
  end

  defp wait_until_value(0, _sleep_ms, _fun), do: :error

  defp wait_until_value(attempts, sleep_ms, fun) do
    case fun.() do
      nil ->
        Process.sleep(sleep_ms)
        wait_until_value(attempts - 1, sleep_ms, fun)

      false ->
        Process.sleep(sleep_ms)
        wait_until_value(attempts - 1, sleep_ms, fun)

      value ->
        {:ok, value}
    end
  end

  defp http_ok?(url) do
    match?({:ok, {{_, 200, _}, _headers, _body}}, http_get(url))
  end

  defp health_url(port), do: "http://127.0.0.1:#{port}/health"

  defp http_get(url) do
    :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)
  end
end
