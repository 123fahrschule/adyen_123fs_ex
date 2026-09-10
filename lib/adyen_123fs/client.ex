defmodule Adyen123FS.Client do
  @moduledoc """
  Explicit, immutable configuration and transport for Adyen services.

  `new/1` requires `:api_key`. Optional settings: `:environment` (`:test` or
  `:live`), `:service` (`:checkout`, the default, or `:data_protection`),
  `:live_prefix` (required for live Checkout; forbidden for Data Protection),
  `:api_version` (integer, default 72 for Checkout or 1 for Data Protection),
  `:receive_timeout` (milliseconds, default
  30_000), `:connect_timeout` (default 10_000), and `:adapter` (Req adapter,
  primarily for tests). No application-global configuration is read or changed.

  Requests never follow redirects or automatically retry. The caller owns the
  durable retry policy; all POST transport failures without an idempotency key
  are conservatively marked non-retryable, including `/paymentMethods`.
  Data Protection requests never support idempotency keys or automatic retries.
  Client `Inspect` excludes the API key;
  the stored Req template contains no credentials. The outgoing request must
  contain the key, so never log it or directly inspect the `api_key` field.
  """

  alias Adyen123FS.Error
  @derive {Inspect, only: [:base_url, :service]}
  @enforce_keys [:base_url, :service, :api_key, :request]
  defstruct [:base_url, :service, :api_key, :request]
  @type service :: :checkout | :data_protection
  @type t :: %__MODULE__{
          base_url: String.t(),
          service: service(),
          api_key: String.t(),
          request: Req.Request.t()
        }
  @type result :: {:ok, Req.Response.t()} | {:error, Error.t()}

  @doc "Build a client; invalid programmer configuration raises `ArgumentError`."
  @spec new(keyword()) :: t()
  def new(options) do
    options =
      Keyword.validate!(options, [
        :api_key,
        :service,
        :environment,
        :live_prefix,
        :api_version,
        :receive_timeout,
        :connect_timeout,
        :adapter
      ])

    key = Keyword.get(options, :api_key)

    unless is_binary(key) and Regex.match?(~r/\A[\x21-\x7e]+\z/, key),
      do: raise(ArgumentError, "api_key must contain printable ASCII without whitespace")

    service = Keyword.get(options, :service, :checkout)

    default_version =
      case service do
        :checkout -> 72
        :data_protection -> 1
        _ -> raise ArgumentError, "service must be :checkout or :data_protection"
      end

    if service == :data_protection and Keyword.has_key?(options, :live_prefix),
      do: raise(ArgumentError, "live_prefix is not supported by Data Protection")

    version = positive_integer!(Keyword.get(options, :api_version, default_version), :api_version)

    receive_timeout =
      positive_integer!(Keyword.get(options, :receive_timeout, 30_000), :receive_timeout)

    connect_timeout =
      positive_integer!(Keyword.get(options, :connect_timeout, 10_000), :connect_timeout)

    base_url = base_url(service, options, version)

    request =
      Req.new(
        [
          headers: [{"accept", "application/json"}],
          retry: false,
          redirect: false,
          decode_body: false,
          retry_log_level: false,
          receive_timeout: receive_timeout,
          connect_options: [timeout: connect_timeout]
        ] ++ Keyword.take(options, [:adapter])
      )

    %__MODULE__{base_url: base_url, service: service, api_key: key, request: request}
  end

  @doc """
  Make one request to a relative endpoint of the configured service. Returns the full response
  on HTTP 2xx, including payment refusals. `{:ok, response}` does not mean paid.
  Request bodies use Adyen's JSON field names. Errors retain status and headers.
  Options are `:idempotency_key` (1–64 printable ASCII characters) and `:query`
  (string-keyed map with string, integer, boolean or nil values).
  A key is never generated implicitly. Persist one
  key per operation and reuse it with the identical body after a retryable error.
  Data Protection rejects `:idempotency_key` and never marks errors retryable.
  """
  @spec request(t(), atom(), String.t(), map() | nil, keyword()) :: result()
  def request(client, method, path, body, options \\ []) do
    with :ok <- validate_request(client, method, path, options),
         {:ok, encoded_body} <- encode(body) do
      key = Keyword.get(options, :idempotency_key)

      safe_retry =
        client.service == :checkout and
          (method in [:get, :delete] or (method == :post and not is_nil(key)))

      headers = if key, do: [{"idempotency-key", key}], else: []
      headers = if body, do: [{"content-type", "application/json"} | headers], else: headers

      request_options = [
        method: method,
        url: client.base_url <> path,
        body: encoded_body,
        headers: [{"x-api-key", client.api_key} | headers]
      ]

      request_options =
        if Keyword.has_key?(options, :query),
          do: Keyword.put(request_options, :params, options[:query]),
          else: request_options

      case Req.request(client.request, request_options) do
        {:ok, response} ->
          response_result(response, safe_retry)

        {:error, reason} ->
          {:error,
           Error.with_message(%Error{kind: :transport, reason: reason, retryable: safe_retry})}
      end
    end
  end

  @doc false
  @spec ensure_service(t(), service()) :: :ok | {:error, Error.t()}
  def ensure_service(%__MODULE__{service: service}, service), do: :ok
  def ensure_service(_, _), do: invalid("client is configured for a different Adyen service")

  defp validate_request(client, method, path, options) do
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

      client.service == :data_protection and Keyword.has_key?(options, :idempotency_key) ->
        invalid("Data Protection does not support idempotency keys")

      Keyword.has_key?(options, :idempotency_key) and not valid_key?(options[:idempotency_key]) ->
        invalid("invalid idempotency key")

      not valid_query?(Keyword.get(options, :query, %{})) ->
        invalid("query must map string keys to string, integer, boolean or nil values")

      true ->
        :ok
    end
  end

  @doc false
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key), do: is_binary(key) and Regex.match?(~r/\A[\x21-\x7e]{1,64}\z/, key)

  defp valid_query?(query) when is_map(query) and not is_struct(query) do
    Enum.all?(query, fn {key, value} ->
      is_binary(key) and
        (is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value))
    end)
  end

  defp valid_query?(_), do: false

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
      {true, {:ok, body}} when is_map(body) ->
        {:ok, %{response | body: body}}

      {true, {:ok, nil}} when response.status == 204 and response.body in ["", nil] ->
        {:ok, %{response | body: nil}}

      {success, _} ->
        body =
          case decoded do
            {:ok, value} -> value
            _ -> response.body
          end

        {:error,
         Error.with_message(%Error{
           kind: if(success, do: :protocol, else: :api),
           status: response.status,
           headers: response.headers,
           body: body,
           retryable:
             not success and safe_retry and
               Req.Response.get_header(response, "transient-error") == ["true"]
         })}
    end
  end

  defp base_url(:data_protection, options, version) do
    host =
      case Keyword.get(options, :environment, :test) do
        :test -> "ca-test.adyen.com"
        :live -> "ca-live.adyen.com"
        _ -> raise ArgumentError, "environment must be :test or :live"
      end

    "https://#{host}/ca/services/DataProtectionService/v#{version}"
  end

  defp base_url(:checkout, options, version) do
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
