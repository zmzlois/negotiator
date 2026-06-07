defmodule Negotiator.Telephony.Telnyx.Readiness do
  @moduledoc """
  reads telnyx carrier-call readiness without exposing secrets.
  """

  alias Negotiator.{Env, Tools}

  @base_url "https://api.telnyx.com/v2"
  @supported_webhook_paths ["/telnyx/webhook", "/webhooks/telnyx"]

  @doc """
  returns a secret-safe status snapshot for the configured telnyx app and number.
  """
  def snapshot(opts \\ []) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> Env.fetch!("TELNYX_API_KEY") end)

    connection_id =
      Keyword.get_lazy(opts, :connection_id, fn -> Env.fetch!("TELNYX_CONNECTION_ID") end)

    phone_number =
      Keyword.get_lazy(opts, :phone_number, fn -> Env.fetch!("TELNYX_PHONE_NUMBER") end)

    public_base_url =
      Keyword.get_lazy(opts, :public_base_url, fn -> Env.fetch!("PUBLIC_BASE_URL") end)

    http_get = Keyword.get(opts, :http_get, &Tools.http_get/2)

    expected_webhook_urls = expected_webhook_urls(public_base_url)

    %{
      public_base_url: sanitize_url(public_base_url),
      expected_webhook_paths: @supported_webhook_paths,
      application: application_status(http_get, api_key, connection_id, expected_webhook_urls),
      phone_number: phone_number_status(http_get, api_key, phone_number, connection_id)
    }
    |> put_ready()
  end

  defp application_status(http_get, api_key, connection_id, expected_webhook_urls) do
    url = "#{@base_url}/call_control_applications/#{connection_id}"

    case http_get.(url, auth: {:bearer, api_key}, receive_timeout: 15_000) do
      {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 ->
        webhook_url = data["webhook_event_url"]

        %{
          reachable?: true,
          active?: data["active"],
          id_matches_env?: data["id"] == connection_id,
          webhook_api_version: data["webhook_api_version"],
          webhook_url: sanitize_url(webhook_url),
          webhook_supported?: webhook_url in expected_webhook_urls,
          webhook_host_matches?: host(webhook_url) == expected_host(expected_webhook_urls),
          webhook_path_supported?: path(webhook_url) in @supported_webhook_paths
        }

      {:ok, %{status: status, body: body}} ->
        %{reachable?: false, status: status, error: inspect(body, limit: 4, printable_limit: 120)}

      {:error, reason} ->
        %{reachable?: false, error: inspect(reason)}
    end
  end

  defp phone_number_status(http_get, api_key, phone_number, connection_id) do
    query = URI.encode_query(%{"filter[phone_number]" => phone_number})
    url = "#{@base_url}/phone_numbers?#{query}"

    case http_get.(url, auth: {:bearer, api_key}, receive_timeout: 15_000) do
      {:ok, %{status: status, body: %{"data" => numbers}}}
      when status in 200..299 and is_list(numbers) ->
        number = Enum.find(numbers, &(&1["phone_number"] == phone_number))

        %{
          reachable?: true,
          found?: not is_nil(number),
          status: number && number["status"],
          assigned_to_connection?: number && number["connection_id"] == connection_id,
          connection_name_present?: number && is_binary(number["connection_name"]),
          call_forwarding_enabled?: number && number["call_forwarding_enabled"]
        }

      {:ok, %{status: status, body: body}} ->
        %{reachable?: false, status: status, error: inspect(body, limit: 4, printable_limit: 120)}

      {:error, reason} ->
        %{reachable?: false, error: inspect(reason)}
    end
  end

  defp put_ready(%{application: app, phone_number: number} = snapshot) do
    ready? =
      app[:reachable?] == true and
        app[:active?] == true and
        app[:id_matches_env?] == true and
        app[:webhook_api_version] == "2" and
        app[:webhook_host_matches?] == true and
        app[:webhook_path_supported?] == true and
        number[:reachable?] == true and
        number[:found?] == true and
        number[:status] == "active" and
        number[:assigned_to_connection?] == true

    Map.put(snapshot, :ready?, ready?)
  end

  defp expected_webhook_urls(public_base_url) do
    base_url = String.trim_trailing(public_base_url, "/")
    Enum.map(@supported_webhook_paths, &"#{base_url}#{&1}")
  end

  defp expected_host([]), do: nil
  defp expected_host([url | _rest]), do: host(url)

  defp host(nil), do: nil
  defp host(url), do: URI.parse(url).host

  defp path(nil), do: nil
  defp path(url), do: URI.parse(url).path

  defp sanitize_url(nil), do: nil

  defp sanitize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://<host>#{path || ""}"

      _other ->
        "<invalid-url>"
    end
  end
end
