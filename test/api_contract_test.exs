defmodule Adyen123FS.APIContractTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Checkout, TestAdapter}

  @contract File.read!(Path.join(__DIR__, "fixtures/checkout_v72_contract.json"))
            |> Jason.decode!()
  @operations [
    {:payment_methods, "POST /paymentMethods", :body_optional_key},
    {:card_details, "POST /cardDetails", :body_optional_key},
    {:create_payment, "POST /payments", :body},
    {:submit_details, "POST /payments/details", :body},
    {:create_session, "POST /sessions", :body},
    {:get_session, "GET /sessions/{sessionId}", :session_result},
    {:update_session, "PATCH /sessions/{sessionId}", :update_session},
    {:apple_pay_session, "POST /applePay/sessions", :body},
    {:cancel_by_reference, "POST /cancels", :body},
    {:capture, "POST /payments/{paymentPspReference}/captures", :modification},
    {:refund, "POST /payments/{paymentPspReference}/refunds", :modification},
    {:cancel, "POST /payments/{paymentPspReference}/cancels", :modification},
    {:reverse, "POST /payments/{paymentPspReference}/reversals", :modification},
    {:update_amount, "POST /payments/{paymentPspReference}/amountUpdates", :modification},
    {:list_stored_payment_methods, "GET /storedPaymentMethods", :query},
    {:store_payment_method, "POST /storedPaymentMethods", :body},
    {:delete_stored_payment_method, "DELETE /storedPaymentMethods/{storedPaymentMethodId}",
     :delete}
  ]

  for {function, operation, kind} <- @operations do
    @function function
    @operation operation
    @kind kind
    @specification @contract["operations"][operation]

    test "#{function} obeys the pinned Adyen v72 method, path and required field contract" do
      body = sample_body(@specification["required_body"])
      [method, path] = String.split(@operation, " ", parts: 2)
      path = Regex.replace(~r/\{[^}]+\}/, path, "RESOURCE123")

      client =
        TestAdapter.client(fn request ->
          assert String.upcase(Atom.to_string(request.method)) == method
          assert request.url.path == "/v72" <> path
          if body != %{}, do: assert(Jason.decode!(request.body) == body)

          if @kind == :body_optional_key,
            do: assert(Req.Request.get_header(request, "idempotency-key") == [])

          query = URI.decode_query(request.url.query || "")
          for key <- @specification["required_query"], do: assert(Map.has_key?(query, key))
          {request, Req.Response.new(status: 200, body: %{})}
        end)

      assert {:ok, _} = invoke(client, @function, @kind, body)
    end

    if kind in [:body, :body_optional_key, :modification, :update_session] do
      test "#{function} rejects missing or wrongly typed required fields" do
        body = sample_body(@specification["required_body"])
        client = TestAdapter.client(fn _ -> flunk("invalid request must not reach Adyen") end)

        for {field, type} <- @specification["required_body"] do
          assert {:error, %{kind: :validation}} =
                   invoke(client, @function, @kind, Map.delete(body, field))

          wrong = if type == "object", do: "wrong", else: %{"wrong" => "type"}

          assert {:error, %{kind: :validation}} =
                   invoke(client, @function, @kind, Map.put(body, field, wrong))
        end
      end
    end
  end

  defp sample_body(required) do
    Map.new(required, fn
      {"amount", _} -> {"amount", %{"currency" => "EUR", "value" => 1000}}
      {"paymentMethod", _} -> {"paymentMethod", %{"type" => "scheme"}}
      {"details", _} -> {"details", %{"redirectResult" => "opaque"}}
      {key, _} -> {key, "test-value"}
    end)
  end

  test "card discovery preserves optional fields and allows an explicit operation key" do
    for options <- [[], [idempotency_key: "discovery-key"]] do
      body = %{
        "merchantAccount" => "Merchant",
        "encryptedCardNumber" => "test_encrypted",
        "countryCode" => "DE",
        "supportedBrands" => ["visa", "mc"],
        "futureField" => %{"preserved" => true}
      }

      response = %{"brands" => [%{"type" => "visa", "supported" => true}]}

      client =
        TestAdapter.client(fn req ->
          assert req.method == :post
          assert req.url.path == "/v72/cardDetails"
          assert Jason.decode!(req.body) == body

          assert Req.Request.get_header(req, "idempotency-key") ==
                   List.wrap(options[:idempotency_key])

          {req, Req.Response.new(status: 200, body: response)}
        end)

      assert {:ok, %{body: ^response}} = apply(Checkout, :card_details, [client, body, options])
    end
  end

  defp invoke(client, function, :body_optional_key, body),
    do: apply(Checkout, function, [client, body])

  defp invoke(client, function, :body, body),
    do: apply(Checkout, function, [client, body, [idempotency_key: "operation"]])

  defp invoke(client, function, :modification, body),
    do: apply(Checkout, function, [client, "RESOURCE123", body, [idempotency_key: "operation"]])

  defp invoke(client, function, :update_session, body),
    do: apply(Checkout, function, [client, "RESOURCE123", body])

  defp invoke(client, function, :session_result, _),
    do: apply(Checkout, function, [client, "RESOURCE123", "opaque-result"])

  defp invoke(client, function, :query, _),
    do:
      apply(Checkout, function, [
        client,
        %{"merchantAccount" => "Merchant", "shopperReference" => "Shopper"}
      ])

  defp invoke(client, function, :delete, _),
    do:
      apply(Checkout, function, [
        client,
        "RESOURCE123",
        %{"merchantAccount" => "Merchant", "shopperReference" => "Shopper"}
      ])
end
