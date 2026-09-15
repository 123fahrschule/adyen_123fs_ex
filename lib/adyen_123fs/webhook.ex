defmodule Adyen123FS.Webhook do
  @moduledoc """
  HMAC verification for Standard and body-signed Adyen webhooks, without Plug.

  Keys are 64-character hex strings from the webhook configuration. Pass a list
  of current/previous keys during rotation. Malformed input returns false/error.
  Standard HMAC covers eight values in seven top-level fields (`signed_fields/0`):
  amount contributes value and currency. Other fields, including eventDate,
  paymentMethod, reason and extra additionalData, are not authenticated by that
  signature. Do not base financial or state decisions on these unsigned fields;
  paymentMethod and reason are display/diagnostic data only. Merchant routing and persistence are owned
  by the application. Never acknowledge a batch before durable storage succeeds.

  `event_codes/0` lists the pinned Webhooks v1 enum. `known_event_code?/1` is a
  classification helper, not signature verification or business-policy approval.
  Verified unknown events must be stored and routed to reconciliation. Even a
  known code can be unsupported by your application's state machine.
  """
  @type keys :: String.t() | [String.t()]

  @event_codes ~w(
    AUTHENTICATION AUTHORISATION AUTHORISATION_ADJUSTMENT AUTORESCUE CANCELLATION
    CANCEL_AUTORESCUE CANCEL_OR_REFUND CAPTURE CAPTURE_FAILED CHARGEBACK
    CHARGEBACK_REVERSED DISPUTE_DEFENSE_PERIOD_ENDED EXPIRE HANDLED_EXTERNALLY
    INFORMATION_SUPPLIED ISSUER_COMMENTS ISSUER_RESPONSE_TIMEFRAME_EXPIRED
    MANUAL_REVIEW_ACCEPT MANUAL_REVIEW_REJECT NOTIFICATION_OF_CHARGEBACK
    NOTIFICATION_OF_FRAUD OFFER_CLOSED ORDER_CLOSED ORDER_OPENED PAYOUT_DECLINE
    PAYOUT_EXPIRE PAYOUT_THIRDPARTY POSTPONED_REFUND PREARBITRATION_LOST
    PREARBITRATION_OPEN PREARBITRATION_WON RECURRING_CONTRACT REFUND
    REFUNDED_REVERSED REFUND_FAILED REFUND_WITH_DATA REQUEST_FOR_INFORMATION
    SECOND_CHARGEBACK TECHNICAL_CANCEL VOID_PENDING_REFUND
  )

  @doc "Sorted eventCode enum from the pinned Webhooks v1 specification, independent of runtime fixtures."
  @spec event_codes() :: [String.t()]
  def event_codes, do: @event_codes

  @doc "Whether a string belongs to the pinned enum; this does not authenticate it or approve a state transition."
  @spec known_event_code?(term()) :: boolean()
  def known_event_code?(code), do: code in @event_codes

  @doc """
  Top-level fields authenticated by Standard HMAC. Only value and currency
  inside amount are covered; additional amount properties are not signed.
  This list is not the schema's required-field list: eventDate is required but
  unsigned, and optional originalReference contributes an empty value if absent.
  """
  @spec signed_fields() :: [String.t()]
  def signed_fields,
    do: [
      "pspReference",
      "originalReference",
      "merchantAccountCode",
      "merchantReference",
      "amount",
      "eventCode",
      "success"
    ]

  @doc "Verify one NotificationRequestItem using Standard webhook canonicalization."
  @spec verify_standard(term(), keys()) :: boolean()
  def verify_standard(%{"additionalData" => %{"hmacSignature" => signature}} = item, keys) do
    case canonical(item) do
      {:ok, data} -> verify_body(data, signature, keys)
      :error -> false
    end
  end

  def verify_standard(_, _), do: false

  @doc "Verify all items before returning the batch; reject missing or empty notificationItems."
  @spec verify_standard_request(term(), keys()) :: {:ok, [map()]} | {:error, atom()}
  def verify_standard_request(%{"notificationItems" => [_ | _] = items}, keys) do
    Enum.reduce_while(items, {:ok, []}, fn
      %{"NotificationRequestItem" => item}, {:ok, verified} ->
        if verify_standard(item, keys),
          do: {:cont, {:ok, [item | verified]}},
          else: {:halt, {:error, :invalid_signature}}

      _, _ ->
        {:halt, {:error, :invalid_payload}}
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      error -> error
    end
  end

  def verify_standard_request(_, _), do: {:error, :invalid_payload}

  @doc """
  Verify exact raw bytes for header-signed webhooks (for example token lifecycle).
  Supply the hmacsignature header and require protocol HmacSHA256 at your
  endpoint. Do not decode and re-encode JSON before calling this function.
  This algorithm is different from Standard NotificationRequestItem signing.
  """
  @spec verify_body(term(), term(), keys()) :: boolean()
  def verify_body(raw, signature, keys) when is_binary(raw) and is_binary(signature) do
    case Base.decode64(signature) do
      {:ok, received} when byte_size(received) == 32 ->
        Enum.any?(List.wrap(keys), fn key ->
          with true <- is_binary(key) and byte_size(key) == 64,
               {:ok, decoded} <- Base.decode16(key, case: :mixed) do
            expected = :crypto.mac(:hmac, :sha256, decoded, raw)
            :crypto.hash_equals(expected, received)
          else
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  def verify_body(_, _, _), do: false

  defp canonical(
         %{
           "pspReference" => psp,
           "merchantAccountCode" => merchant,
           "merchantReference" => reference,
           "amount" => %{"value" => value, "currency" => currency},
           "eventCode" => event,
           "success" => success
         } = item
       )
       when is_integer(value) do
    original =
      case Map.get(item, "originalReference") do
        nil -> ""
        value -> value
      end

    fields = [psp, original, merchant, reference, Integer.to_string(value), currency, event]

    if Enum.all?(fields, &is_binary/1) and success in ["true", "false", true, false] do
      # Standard notifications join raw values; legacy HPP escaping does not apply.
      {:ok, Enum.join(fields ++ [to_string(success)], ":")}
    else
      :error
    end
  end

  defp canonical(_), do: :error
end
