defmodule Adyen123FS.Client do
  @moduledoc """
  Explicit, immutable configuration and transport for Adyen Checkout API v72.

  `new/1` requires `:api_key`. Optional settings: `:environment` (`:test` or
  `:live`), `:live_prefix` (required in live), `:api_version` (integer),
  `:receive_timeout` (milliseconds, default
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
          decode_body: false,
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
  Options are `:idempotency_key` (1–64 printable ASCII characters) and `:query`
  (map of query parameters). A key is never generated implicitly. Persist one
  key per operation and reuse it with the identical body after a retryable error.
  """
  @spec request(t(), atom(), String.t(), map() | nil, keyword()) :: result()
  def request(client, method, path, body, options \\ []) do
    with :ok <- validate_request(method, path, options),
         {:ok, encoded_body} <- encode(body) do
      key = Keyword.get(options, :idempotency_key)
      safe_retry = method in [:get, :delete] or (method == :post and not is_nil(key))
      headers = if key, do: [{"idempotency-key", key}], else: []
      headers = if body, do: [{"content-type", "application/json"} | headers], else: headers

      request_options = [
        method: method,
        url: client.base_url <> path,
        body: encoded_body,
        headers: headers
      ]

      request_options =
        if Keyword.has_key?(options, :query),
          do: Keyword.put(request_options, :params, options[:query]),
          else: request_options

      case Req.request(client.request, request_options) do
        {:ok, response} ->
          response_result(response, safe_retry)

        {:error, reason} ->
          {:error, %Error{kind: :transport, reason: reason, retryable: safe_retry}}
      end
    end
  end

  defp validate_request(method, path, options) do
    valid_options =
      Keyword.keyword?(options) and
        Enum.all?(Keyword.keys(options), &(&1 in [:idempotency_key, :query]))

    cond do
      method not in [:get, :post, :patch, :delete] ->
        invalid("unsupported HTTP method")

      not (is_binary(path) and Regex.match?(~r{\A(?:/[A-Za-z0-9_-]+)+\z}, path)) ->
        invalid("invalid relative endpoint path")

      not valid_options ->
        invalid("unsupported request option")

      Keyword.has_key?(options, :idempotency_key) and not valid_key?(options[:idempotency_key]) ->
        invalid("invalid idempotency key")

      not is_map(Keyword.get(options, :query, %{})) ->
        invalid("query must be a map")

      true ->
        :ok
    end
  end

  @doc false
  def valid_key?(key), do: is_binary(key) and Regex.match?(~r/\A[\x21-\x7e]{1,64}\z/, key)

  defp encode(nil), do: {:ok, nil}

  defp encode(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> invalid("body must be JSON encodable")
    end
  end

  defp encode(_), do: invalid("body must be a map")
  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}

  defp response_result(response, safe_retry) do
    decoded =
      cond do
        is_map(response.body) -> {:ok, response.body}
        response.status == 204 and response.body in ["", nil] -> {:ok, nil}
        is_binary(response.body) -> Jason.decode(response.body)
        true -> :error
      end

    case {response.status in 200..299, decoded} do
      {true, {:ok, body}} when is_map(body) or is_nil(body) ->
        {:ok, %{response | body: body}}

      {success, _} ->
        body =
          case decoded do
            {:ok, value} -> value
            _ -> response.body
          end

        {:error,
         %Error{
           kind: if(success, do: :protocol, else: :api),
           status: response.status,
           headers: response.headers,
           body: body,
           retryable:
             not success and safe_retry and
               Req.Response.get_header(response, "transient-error") == ["true"]
         }}
    end
  end

  defp base_url(options, version) do
    case Keyword.get(options, :environment, :test) do
      :test ->
        "https://checkout-test.adyen.com/v#{version}"

      :live ->
        prefix = Keyword.get(options, :live_prefix)

        unless is_binary(prefix) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9-]*\z/, prefix),
          do: raise(ArgumentError, "live_prefix is required and must be a hostname prefix")

        "https://#{prefix}-checkout-live.adyenpayments.com/checkout/v#{version}"

      _ ->
        raise ArgumentError, "environment must be :test or :live"
    end
  end

  defp positive_integer!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive_integer!(_, name), do: raise(ArgumentError, "#{name} must be a positive integer")
end
