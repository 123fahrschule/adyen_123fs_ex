defmodule Adyen123FS.Webhook do
  @moduledoc """
  HMAC verification for Standard and body-signed Adyen webhooks, without Plug.

  Keys are 64-character hex strings from the webhook configuration. Pass a list
  of current/previous keys during rotation. Malformed input returns false/error.
  Standard HMAC covers only Adyen's eight documented fields, not the entire
  event. Other fields, including eventDate and extra additionalData, are not
  authenticated by that signature. Merchant routing and persistence are owned
  by the application. Never acknowledge a batch before durable storage succeeds.
  """
  @type keys :: String.t() | [String.t()]

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
