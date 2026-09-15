defmodule Adyen123FS.Error do
  @moduledoc """
  A validation, API, protocol, or transport error. Bodies and underlying reasons may contain
  personal data; never log them indiscriminately. `Inspect` omits these fields.
  A transport failure can leave a payment's outcome unknown.

  Errors returned by this library have a loggable `message`: a fixed description,
  status, retry eligibility and constrained diagnostic categories. Raw provider
  messages, headers and arbitrary transport reasons are never interpolated.
  Unknown diagnostic codes/types are omitted. The library does not log errors;
  the caller decides their severity and destination. This guarantee does not
  apply to messages supplied when manually constructing or modifying the struct.
  """
  @derive {Inspect, only: [:kind, :status, :retryable]}
  defstruct [:kind, :status, :body, :reason, :message, headers: %{}, retryable: false]

  @type t :: %__MODULE__{
          kind: :validation | :api | :transport | :protocol,
          status: integer() | nil,
          body: term(),
          reason: term(),
          message: String.t() | nil,
          headers: map(),
          retryable: boolean()
        }

  @doc false
  @spec with_message(%__MODULE__{kind: :api | :protocol | :transport}) :: t()
  def with_message(%__MODULE__{} = error), do: %{error | message: summary(error)}

  defp summary(%{kind: :api} = error) do
    "Adyen API error: status=#{error.status} retryable=#{error.retryable}" <>
      api_diagnostics(error.body)
  end

  defp summary(%{kind: :protocol} = error) do
    "Adyen protocol error: status=#{error.status} retryable=#{error.retryable} unexpected response body"
  end

  defp summary(%{kind: :transport} = error) do
    "Adyen transport error: retryable=#{error.retryable}" <> transport_diagnostic(error.reason)
  end

  defp api_diagnostics(body) when is_map(body) do
    code = body["errorCode"]
    type = body["errorType"]

    code_part =
      if is_binary(code) and byte_size(code) <= 7 and
           Regex.match?(~r/\A[0-9]{2,3}(?:_[0-9]{3})?\z/, code),
         do: " errorCode=" <> code,
         else: ""

    type_part =
      if type in ["validation", "security", "configuration", "internal"],
        do: " errorType=" <> type,
        else: ""

    code_part <> type_part
  end

  defp api_diagnostics(_), do: ""

  defp transport_diagnostic(%Req.TransportError{reason: reason})
       when reason in [
              :timeout,
              :closed,
              :econnrefused,
              :nxdomain,
              :enetunreach,
              :ehostunreach,
              :econnreset
            ],
       do: " reason=" <> Atom.to_string(reason)

  defp transport_diagnostic(_), do: ""
end
