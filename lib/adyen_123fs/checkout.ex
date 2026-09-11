defmodule Adyen123FS.Checkout do
  @moduledoc """
  Adyen Checkout endpoints for cards, Apple Pay, Google Pay and Alma.

  Bodies are maps with **string keys matching Adyen's API**. Additional fields
  are preserved for 3DS, tokenization, billing/delivery addresses, line items,
  installments and future API extensions. Only required fields and amount shape
  are checked locally; Adyen validates payment-method-specific requirements.

  All creating/modifying POST operations require `idempotency_key: persisted_key`.
  Their options argument is mandatory; there are no convenience arities without
  it. Endpoint identifiers accept ASCII letters, digits, `_` and `-`, up to 1024
  bytes. This is a client resource limit, not an Adyen-defined identifier length.
  Payment-method and card discovery are the exceptions. Responses are full `Req.Response`
  structs. Forward `action` unchanged to Adyen Web; complete 3DS or redirects
  with `submit_details/3`. A successful HTTP request is not proof of settlement.
  """
  alias Adyen123FS.{Client, Error}

  @doc "POST `/paymentMethods`: discover enabled methods for the amount and country. Requires merchantAccount."
  @spec payment_methods(Client.t(), map(), keyword()) :: Client.result()
  def payment_methods(client, body, options \\ []) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- validate(body, ["merchantAccount"]) do
      Client.request(client, :post, "/paymentMethods", body, options)
    end
  end

  @doc """
  POST `/cardDetails`: discover card brands and funding information.
  Requires merchantAccount. Optional cardNumber, encryptedCardNumber, countryCode
  and supportedBrands are passed through. The idempotency key is optional.

  `cardNumber` contains an unencrypted card number or BIN. Never log or persist
  it, and never accept this raw field from the browser in this integration.
  Prefer `encryptedCardNumber` from Adyen Web. Passing full PANs through your
  application brings it into PCI DSS card-data handling scope.
  """
  @spec card_details(Client.t(), map(), keyword()) :: Client.result()
  def card_details(client, body, options \\ []) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- validate(body, ["merchantAccount"]) do
      Client.request(client, :post, "/cardDetails", body, options)
    end
  end

  @doc """
  POST `/paymentLinks`: create a hosted payment link. Requires amount,
  merchantAccount and reference, plus a persisted idempotency key in options.
  Take amount and reference from the server-side order, never from the browser.

  Optional fields are forwarded unchanged, including expiresAt (Adyen defaults
  to 24 hours), shopperEmail, description, countryCode, reusable,
  allowedPaymentMethods, blockedPaymentMethods, lineItems, manualCapture,
  storePaymentMethodMode, recurringProcessingModel and shopperReference.
  `reusable: true` permits multiple payments on the same link and is normally
  inappropriate for a single shopper's purchase. The returned url is a payment
  page: do not log it and share it only with the intended recipient.

  HTTP 201 means the link exists, not that it is paid. Process the payment's
  AUTHORISATION webhook to determine its outcome.
  """
  @spec create_payment_link(Client.t(), map(), keyword()) :: Client.result()
  def create_payment_link(client, body, options),
    do: post(client, "/paymentLinks", body, ["amount", "merchantAccount", "reference"], options)

  @doc "GET `/paymentLinks/{linkId}`: retrieve a link. Payment outcomes still require verified webhooks."
  @spec get_payment_link(Client.t(), String.t()) :: Client.result()
  def get_payment_link(client, link_id) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- identifier(link_id) do
      Client.request(client, :get, "/paymentLinks/#{link_id}", nil)
    end
  end

  @doc """
  PATCH `/paymentLinks/{linkId}`: expire a link with the fixed body
  `%{\"status\" => \"expired\"}`. Expired is the only request status allowed by v72.
  Adyen declares no idempotency key for this PATCH; none is sent and uncertain
  transport failures are not marked retryable. This does not cancel or refund
  a payment already made through the link.
  """
  @spec expire_payment_link(Client.t(), String.t()) :: Client.result()
  def expire_payment_link(client, link_id) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- identifier(link_id) do
      Client.request(client, :patch, "/paymentLinks/#{link_id}", %{"status" => "expired"})
    end
  end

  @doc """
  POST `/payments`: initiate a card, wallet, Alma, or stored-method payment.
  Requires amount, merchantAccount, paymentMethod, reference, returnUrl.
  `paymentMethod` comes from Adyen Web (types scheme/applepay/googlepay/alma).
  Preserve resultCode and action; Refused is also an HTTP 2xx response.
  """
  @spec create_payment(Client.t(), map(), keyword()) :: Client.result()
  def create_payment(client, body, options) do
    post(
      client,
      "/payments",
      body,
      ["amount", "merchantAccount", "paymentMethod", "reference", "returnUrl"],
      options
    )
  end

  @doc "POST `/payments/details`: complete 3DS or a redirect using details. paymentData is optional/flow-dependent."
  @spec submit_details(Client.t(), map(), keyword()) :: Client.result()
  def submit_details(client, body, options),
    do: post(client, "/payments/details", body, ["details"], options)

  @doc "POST `/sessions`: create a Drop-in/Components session. Requires amount, merchantAccount, reference, returnUrl."
  @spec create_session(Client.t(), map(), keyword()) :: Client.result()
  def create_session(client, body, options),
    do:
      post(
        client,
        "/sessions",
        body,
        ["amount", "merchantAccount", "reference", "returnUrl"],
        options
      )

  @doc """
  GET `/sessions/{sessionId}` with the mandatory sessionResult from Adyen Web.
  This is not an arbitrary session-status polling API; keep the result opaque.
  """
  @spec get_session(Client.t(), String.t(), String.t()) :: Client.result()
  def get_session(client, session_id, session_result) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- identifier(session_id),
         :ok <- require_string(session_result, "sessionResult") do
      Client.request(client, :get, "/sessions/#{session_id}", nil,
        query: %{"sessionResult" => session_result}
      )
    end
  end

  @doc """
  PATCH `/sessions/{sessionId}`: update amount using current sessionData.
  Adyen does not declare idempotency-key support for this PATCH operation.
  The client does not mark its transport errors as automatically retryable.
  """
  @spec update_session(Client.t(), String.t(), map()) :: Client.result()
  def update_session(client, session_id, body) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- identifier(session_id),
         :ok <- validate(body, ["amount", "sessionData"]) do
      Client.request(client, :patch, "/sessions/#{session_id}", body)
    end
  end

  @doc """
  POST `/applePay/sessions`: merchant validation when using Adyen's Apple Pay
  certificate. Requires displayName, domainName and merchantIdentifier.
  Merchant validation is separate from Checkout's payment session.
  """
  @spec apple_pay_session(Client.t(), map(), keyword()) :: Client.result()
  def apple_pay_session(client, body, options),
    do:
      post(
        client,
        "/applePay/sessions",
        body,
        ["displayName", "domainName", "merchantIdentifier"],
        options
      )

  @doc """
  POST `/payments/{paymentPspReference}/captures`: full or partial capture.
  Requires amount and merchantAccount. `status: received` is an asynchronous
  acknowledgement; process CAPTURE and CAPTURE_FAILED webhooks. The returned
  pspReference belongs to the modification, not the original authorisation.
  """
  @spec capture(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def capture(client, psp_reference, body, options),
    do: modify(client, psp_reference, "captures", body, ["amount", "merchantAccount"], options)

  @doc "POST `/payments/{paymentPspReference}/refunds`: full/partial refund after capture. Requires amount and merchantAccount; outcome is asynchronous."
  @spec refund(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def refund(client, psp_reference, body, options),
    do: modify(client, psp_reference, "refunds", body, ["amount", "merchantAccount"], options)

  @doc "POST `/payments/{paymentPspReference}/cancels`: cancel an uncaptured authorisation. Requires merchantAccount."
  @spec cancel(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def cancel(client, psp_reference, body, options),
    do: modify(client, psp_reference, "cancels", body, ["merchantAccount"], options)

  @doc """
  POST `/cancels`: cancel without the payment PSP reference. Requires
  merchantAccount and **paymentReference** (the original merchant reference).
  The optional reference identifies the cancellation, not the original payment.
  """
  @spec cancel_by_reference(Client.t(), map(), keyword()) :: Client.result()
  def cancel_by_reference(client, body, options),
    do: post(client, "/cancels", body, ["merchantAccount", "paymentReference"], options)

  @doc "POST `/payments/{paymentPspReference}/reversals`: cancel or refund when capture state is unknown. Requires merchantAccount; outcome is asynchronous."
  @spec reverse(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def reverse(client, psp_reference, body, options),
    do: modify(client, psp_reference, "reversals", body, ["merchantAccount"], options)

  @doc """
  POST `/payments/{paymentPspReference}/amountUpdates`: adjust a pre-authorisation.
  Requires amount and merchantAccount. Preserve adjustAuthorisationData when
  required by your authorisation-adjustment flow; scheme eligibility applies.
  """
  @spec update_amount(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def update_amount(client, psp_reference, body, options),
    do:
      modify(client, psp_reference, "amountUpdates", body, ["amount", "merchantAccount"], options)

  @doc "GET `/storedPaymentMethods` for a merchantAccount and shopperReference. Both are required by this client to scope access explicitly."
  @spec list_stored_payment_methods(Client.t(), map()) :: Client.result()
  def list_stored_payment_methods(client, query) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- validate(query, ["merchantAccount", "shopperReference"]) do
      Client.request(client, :get, "/storedPaymentMethods", nil, query: query)
    end
  end

  @doc "POST `/storedPaymentMethods`: create a token with merchantAccount, shopperReference, recurringProcessingModel and paymentMethod. Obtain shopper consent first."
  @spec store_payment_method(Client.t(), map(), keyword()) :: Client.result()
  def store_payment_method(client, body, options),
    do:
      post(
        client,
        "/storedPaymentMethods",
        body,
        ["merchantAccount", "paymentMethod", "recurringProcessingModel", "shopperReference"],
        options
      )

  @doc "DELETE `/storedPaymentMethods/{storedPaymentMethodId}`. Requires query merchantAccount and shopperReference. A successful deletion returns HTTP 204."
  @spec delete_stored_payment_method(Client.t(), String.t(), map()) :: Client.result()
  def delete_stored_payment_method(client, stored_id, query) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- identifier(stored_id),
         :ok <- validate(query, ["merchantAccount", "shopperReference"]) do
      Client.request(client, :delete, "/storedPaymentMethods/#{stored_id}", nil, query: query)
    end
  end

  defp modify(client, psp_reference, suffix, body, required, options) do
    with :ok <- identifier(psp_reference) do
      post(client, "/payments/#{psp_reference}/#{suffix}", body, required, options)
    end
  end

  defp post(client, path, body, required, options) do
    with :ok <- Client.ensure_service(client, :checkout),
         :ok <- validate(body, required),
         :ok <- idempotency(options) do
      Client.request(client, :post, path, body, options)
    end
  end

  defp validate(body, required) when is_map(body) do
    cond do
      not Enum.all?(Map.keys(body), &is_binary/1) ->
        invalid("use Adyen string keys")

      not Enum.all?(required, &present?(&1, Map.get(body, &1))) ->
        invalid("missing or invalid required fields: " <> Enum.join(required, ", "))

      Map.has_key?(body, "amount") and not amount?(body["amount"]) ->
        invalid(
          "amount requires uppercase currency and a non-negative integer value in minor units"
        )

      true ->
        :ok
    end
  end

  defp validate(_, _), do: invalid("body must be a map")

  defp present?(field, value) when field in ["amount", "details", "paymentMethod"],
    do: is_map(value) and not is_struct(value) and map_size(value) > 0

  defp present?(_, value), do: is_binary(value) and String.trim(value) != ""

  defp amount?(%{"value" => value, "currency" => currency}) do
    is_integer(value) and value >= 0 and is_binary(currency) and
      Regex.match?(~r/\A[A-Z]{3}\z/, currency)
  end

  defp amount?(_), do: false

  defp idempotency(options) do
    if Keyword.keyword?(options) and Client.valid_key?(options[:idempotency_key]),
      do: :ok,
      else: invalid("persist and supply an idempotency_key for this operation")
  end

  defp identifier(value) do
    if is_binary(value) and byte_size(value) <= 1024 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value),
       do: :ok,
       else: invalid("invalid identifier")
  end

  defp require_string(value, field) do
    if is_binary(value) and String.trim(value) != "",
      do: :ok,
      else: invalid("#{field} is required")
  end

  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}
end
