defmodule Adyen123FS.ModificationsTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Checkout, TestAdapter}
  @amount %{"currency" => "EUR", "value" => 5000}
  @key [idempotency_key: "modification-operation"]

  for {function, suffix, amount?} <- [
        {:capture, "captures", true},
        {:refund, "refunds", true},
        {:cancel, "cancels", false},
        {:reverse, "reversals", false},
        {:update_amount, "amountUpdates", true}
      ] do
    @function function
    @suffix suffix
    @amount_required amount?
    test "#{function} sends its documented endpoint and keeps modification references distinct" do
      body = %{"merchantAccount" => "Merchant", "reference" => "operation-ref"}
      body = if @amount_required, do: Map.put(body, "amount", @amount), else: body

      client =
        TestAdapter.client(fn req ->
          assert req.method == :post
          assert req.url.path == "/v72/payments/PAYMENT123/" <> @suffix
          assert Jason.decode!(req.body) == body
          assert Req.Request.get_header(req, "idempotency-key") == ["modification-operation"]

          {req,
           Req.Response.new(
             status: 201,
             body: %{
               "status" => "received",
               "paymentPspReference" => "PAYMENT123",
               "pspReference" => "MODIFICATION456"
             }
           )}
        end)

      assert {:ok, %{body: %{"status" => "received", "pspReference" => "MODIFICATION456"}}} =
               apply(Checkout, @function, [client, "PAYMENT123", body, @key])

      assert {:error, %{kind: :validation}} =
               apply(Checkout, @function, [client, "../other", body, @key])

      assert {:error, %{kind: :validation}} =
               apply(Checkout, @function, [client, "PAYMENT123", body, []])
    end
  end

  test "cancel by merchant reference requires paymentReference, not reference" do
    body = %{
      "merchantAccount" => "Merchant",
      "paymentReference" => "registration-42",
      "reference" => "cancellation-42"
    }

    client =
      TestAdapter.client(fn req ->
        assert req.url.path == "/v72/cancels"
        assert Jason.decode!(req.body) == body
        {req, Req.Response.new(status: 201, body: %{"status" => "received"})}
      end)

    assert {:ok, _} = Checkout.cancel_by_reference(client, body, @key)

    assert {:error, %{kind: :validation}} =
             Checkout.cancel_by_reference(client, Map.delete(body, "paymentReference"), @key)
  end

  test "stored payment methods use query parameters and DELETE has no JSON body" do
    query = %{"merchantAccount" => "Merchant", "shopperReference" => "customer+/=&"}

    client =
      TestAdapter.client(fn req ->
        assert URI.decode_query(req.url.query) == query
        assert req.body == nil

        case req.method do
          :get ->
            assert req.url.path == "/v72/storedPaymentMethods"
            {req, Req.Response.new(status: 200, body: %{"storedPaymentMethods" => []})}

          :delete ->
            assert req.url.path == "/v72/storedPaymentMethods/TOKEN123"
            {req, Req.Response.new(status: 204, body: "")}
        end
      end)

    assert {:ok, _} = Checkout.list_stored_payment_methods(client, query)

    assert {:ok, %{status: 204, body: nil}} =
             Checkout.delete_stored_payment_method(client, "TOKEN123", query)

    assert {:error, %{kind: :validation}} =
             Checkout.delete_stored_payment_method(client, "TOKEN123", %{})
  end

  test "create token preserves shopper consent parameters" do
    body = %{
      "merchantAccount" => "Merchant",
      "shopperReference" => "customer-42",
      "recurringProcessingModel" => "CardOnFile",
      "paymentMethod" => %{"type" => "scheme", "encryptedCardNumber" => "encrypted"}
    }

    client =
      TestAdapter.client(fn req ->
        assert req.method == :post
        assert req.url.path == "/v72/storedPaymentMethods"
        assert Jason.decode!(req.body) == body
        {req, Req.Response.new(status: 200, body: %{"storedPaymentMethodId" => "TOKEN123"})}
      end)

    assert {:ok, _} = Checkout.store_payment_method(client, body, @key)
  end
end
