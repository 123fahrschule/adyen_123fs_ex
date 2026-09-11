defmodule Adyen123FS.DataProtectionTest do
  use ExUnit.Case, async: true
  alias Adyen123FS.{Client, DataProtection, TestAdapter}
  @body %{"merchantAccount" => "Merchant", "pspReference" => "PAYMENT123"}
  @contract __DIR__
            |> Path.join("fixtures/data_protection_v1_contract.json")
            |> File.read!()
            |> Jason.decode!()

  test "erasure obeys the pinned method/path and passes through every documented or future result" do
    [method, path] = @contract["operations"] |> Map.keys() |> hd() |> String.split(" ", parts: 2)

    for result <- @contract["documentation_contract"]["result_values"] ++ ["FUTURE_RESULT"] do
      response = %{"result" => result, "futureField" => %{"preserved" => true}}

      client =
        client(fn req ->
          assert String.upcase(Atom.to_string(req.method)) == method
          assert req.url.host == "ca-test.adyen.com"
          assert req.url.path == "/ca/services/DataProtectionService/v1" <> path
          assert Jason.decode!(req.body) == @body
          assert Req.Request.get_header(req, "x-api-key") == ["key"]
          assert Req.Request.get_header(req, "idempotency-key") == []
          {req, Req.Response.new(status: 200, body: response)}
        end)

      assert {:ok, %{status: 200, body: ^response}} =
               DataProtection.request_subject_erasure(client, @body)
    end
  end

  test "documented required fields are enforced although the OpenAPI marks none required" do
    assert @contract["operations"]["POST /requestSubjectErasure"]["required_body"] == %{}
    client = client(fn _ -> flunk("must not send") end)

    for {field, "string"} <- @contract["documentation_contract"]["required_body"],
        value <- [nil, "", " ", 123, %{}] do
      assert {:error, %{kind: :validation, retryable: false}} =
               DataProtection.request_subject_erasure(
                 client,
                 Map.put(@body, field, value)
               )

      assert {:error, %{kind: :validation}} =
               DataProtection.request_subject_erasure(client, Map.delete(@body, field))
    end

    for body <- ["invalid", %{merchantAccount: "Merchant", pspReference: "PAYMENT123"}] do
      assert {:error, %{kind: :validation}} =
               DataProtection.request_subject_erasure(client, body)
    end
  end

  test "forceErasure and future fields are forwarded only when explicitly supplied" do
    for flag <- [true, false] do
      body = Map.merge(@body, %{"forceErasure" => flag, "futureField" => %{"enabled" => true}})

      client =
        client(fn req ->
          assert Jason.decode!(req.body) == body
          {req, Req.Response.new(status: 200, body: %{"result" => "SUCCESS"})}
        end)

      assert {:ok, _} = DataProtection.request_subject_erasure(client, body, [])
    end
  end

  test "erasure rejects a Checkout client before any network access" do
    client = TestAdapter.client(fn _ -> flunk("must not send") end)

    assert {:error,
            %{kind: :validation, message: "client is configured for a different Adyen service"}} =
             DataProtection.request_subject_erasure(client, @body)
  end

  test "transport and transient HTTP errors are never marked automatically retryable" do
    for failure <- [
          %Req.TransportError{reason: :timeout},
          Req.Response.new(
            status: 503,
            headers: [{"transient-error", "true"}],
            body: %{"errorCode" => "703"}
          )
        ] do
      client = client(fn req -> {req, failure} end)

      assert {:error, %{retryable: false, message: message}} =
               DataProtection.request_subject_erasure(client, @body)

      assert is_binary(message)
    end
  end

  test "a caller cannot opt erasure into Checkout idempotency or bypass query validation" do
    client = client(fn _ -> flunk("must not send") end)

    for options <- [[idempotency_key: "unsupported"], [query: %{"extra" => %{}}], [retry: true]] do
      assert {:error, %{kind: :validation, retryable: false}} =
               DataProtection.request_subject_erasure(client, @body, options)
    end

    assert {:error, %{kind: :validation}} =
             Client.request(client, :post, "/requestSubjectErasure", @body,
               idempotency_key: "unsupported"
             )
  end

  defp client(callback) do
    TestAdapter.register(callback)
    Client.new(api_key: "key", service: :data_protection, adapter: TestAdapter)
  end
end
