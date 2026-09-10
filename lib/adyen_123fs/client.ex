defmodule Adyen123FS.Client do
  @moduledoc """
  Explicit, immutable configuration and transport for Adyen Checkout API v72.

  `new/1` requires `:api_key`. Optional settings: `:environment` (`:test` or
  `:live`), `:live_prefix` (required in live), `:region` (`:eu`, `:us`, `:au`,
  `:in`), `:api_version` (integer), `:receive_timeout` (milliseconds, default
  30_000), `:connect_timeout` (default 10_000), and `:adapter` (Req adapter,
  primarily for tests). No application-global configuration is read or changed.

  Requests never follow redirects or automatically retry. The caller owns the
  durable operation and retry policy. Credentials are excluded from `Inspect`.
  """

  alias Adyen123FS.Error
  @derive {Inspect, only: [:base_url]}
  @enforce_keys [:base_url, :request]
  defstruct [:base_url, :request]
  @type t :: %__MODULE__{base_url: String.t(), request: Req.Request.t()}
  @type result :: {:ok, Req.Response.t()} | {:error, Error.t()}

  @doc "Build a client; invalid programmer configuration raises `ArgumentError`."
  @spec new(keyword()) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [
        :api_key,
        :environment,
        :live_prefix,
        :region,
        :api_version,
        :receive_timeout,
        :connect_timeout,
        :adapter
      ])

    key = Keyword.get(options, :api_key)

    unless is_binary(key) and byte_size(key) > 0 and not String.contains?(key, ["\r", "\n"]),
      do: raise(ArgumentError, "api_key must be a non-empty HTTP header value")

    version = positive_integer!(Keyword.get(options, :api_version, 72), :api_version)

    receive_timeout =
      positive_integer!(Keyword.get(options, :receive_timeout, 30_000), :receive_timeout)

    connect_timeout =
      positive_integer!(Keyword.get(options, :connect_timeout, 10_000), :connect_timeout)

    base_url = base_url(options, version)

    request =
      Req.new(
        [
          headers: [{"x-api-key", key}, {"accept", "application/json"}],
          retry: false,
          redirect: false,
          retry_log_level: false,
          receive_timeout: receive_timeout,
          connect_options: [timeout: connect_timeout]
        ] ++ Keyword.take(options, [:adapter])
      )

    %__MODULE__{base_url: base_url, request: request}
  end

  @doc """
  Make one request to a relative Checkout endpoint. Returns the full response
  on HTTP 2xx, including payment refusals. `{:ok, response}` does not mean paid.
  Request bodies use Adyen's JSON field names. Errors retain status and headers.
  """
  @spec request(t(), atom(), String.t(), map() | nil, keyword()) :: result()
  def request(client, method, path, body, options \\ []) do
    if is_binary(path) and Regex.match?(~r{\A(?:/[A-Za-z0-9_-]+)+\z}, path) do
      request_options = [method: method, url: client.base_url <> path] ++ options

      request_options =
        if is_nil(body), do: request_options, else: Keyword.put(request_options, :json, body)

      case Req.request(client.request, request_options) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, response} ->
          {:error,
           %Error{
             kind: :api,
             status: response.status,
             headers: response.headers,
             body: response.body
           }}

        {:error, reason} ->
          {:error, %Error{kind: :transport, reason: reason}}
      end
    else
      {:error, %Error{kind: :validation, message: "invalid relative endpoint path"}}
    end
  end

  defp base_url(options, version) do
    region = Keyword.get(options, :region, :eu)
    unless region in [:eu, :us, :au, :in], do: raise(ArgumentError, "invalid region")

    case Keyword.get(options, :environment, :test) do
      :test ->
        "https://checkout-test.adyen.com/v#{version}"

      :live ->
        prefix = Keyword.get(options, :live_prefix)

        unless is_binary(prefix) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/, prefix),
          do: raise(ArgumentError, "live_prefix is required and must be a hostname prefix")

        suffix = if region == :eu, do: "", else: "-#{region}"
        "https://#{prefix}-checkout-live#{suffix}.adyenpayments.com/checkout/v#{version}"

      _ ->
        raise ArgumentError, "environment must be :test or :live"
    end
  end

  defp positive_integer!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive_integer!(_, name), do: raise(ArgumentError, "#{name} must be a positive integer")
end
