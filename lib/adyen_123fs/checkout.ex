defmodule Adyen123FS.Checkout do
  @moduledoc """
  Adyen Checkout endpoints for cards, Apple Pay, Google Pay and Alma.

  Bodies are maps with **string keys matching Adyen's API**. Additional fields
  are preserved for 3DS, tokenization, billing/delivery addresses, line items,
  installments and future API extensions. Only required fields and amount shape
  are checked locally; Adyen validates payment-method-specific requirements.

  All creating/modifying POST operations require `idempotency_key: persisted_key`.
  Payment-method discovery is the exception. Responses are full `Req.Response`
  structs. Forward `action` unchanged to Adyen Web; complete 3DS or redirects
  with `submit_details/3`. A successful HTTP request is not proof of settlement.
  """
  alias Adyen123FS.{Client, Error}

  @doc "POST `/paymentMethods`: discover enabled methods for the amount and country. Requires merchantAccount."
  @spec payment_methods(Client.t(), map(), keyword()) :: Client.result()
  def payment_methods(client, body, options \\ []) do
    with :ok <- validate(body, ["merchantAccount"]) do
      Client.request(client, :post, "/paymentMethods", body, options)
    end
  end

  @doc """
  POST `/payments`: initiate a card, wallet, Alma, or stored-method payment.
  Requires amount, merchantAccount, paymentMethod, reference, returnUrl.
  `paymentMethod` comes from Adyen Web (types scheme/applepay/googlepay/alma).
  Preserve resultCode and action; Refused is also an HTTP 2xx response.
  """
  @spec create_payment(Client.t(), map(), keyword()) :: Client.result()
  def create_payment(client, body, options \\ []) do
    post(
      client,
      "/payments",
      body,
      ["amount", "merchantAccount", "paymentMethod", "reference", "returnUrl"],
      options
    )
  end

  @doc "POST `/payments/details`: complete 3DS or a redirect using details. paymentData is optional/fall-dependent."
  @spec submit_details(Client.t(), map(), keyword()) :: Client.result()
  def submit_details(client, body, options \\ []),
    do: post(client, "/payments/details", body, ["details"], options)

  @doc "POST `/sessions`: create a Drop-in/Components session. Requires amount, merchantAccount, reference, returnUrl."
  @spec create_session(Client.t(), map(), keyword()) :: Client.result()
  def create_session(client, body, options \\ []),
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
    with :ok <- identifier(session_id),
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
    with :ok <- identifier(session_id), :ok <- validate(body, ["amount", "sessionData"]) do
      Client.request(client, :patch, "/sessions/#{session_id}", body)
    end
  end

  @doc """
  POST `/applePay/sessions`: merchant validation when using Adyen's Apple Pay
  certificate. Requires displayName, domainName and merchantIdentifier.
  Merchant validation is separate from Checkout's payment session.
  """
  @spec apple_pay_session(Client.t(), map(), keyword()) :: Client.result()
  def apple_pay_session(client, body, options \\ []),
    do:
      post(
        client,
        "/applePay/sessions",
        body,
        ["displayName", "domainName", "merchantIdentifier"],
        options
      )

  defp post(client, path, body, required, options) do
    with :ok <- validate(body, required), :ok <- idempotency(options) do
      Client.request(client, :post, path, body, options)
    end
  end

  defp validate(body, required) when is_map(body) do
    cond do
      not Enum.all?(Map.keys(body), &is_binary/1) ->
        invalid("use Adyen string keys")

      not Enum.all?(required, &present?(Map.get(body, &1))) ->
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
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_), do: false

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
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value),
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
