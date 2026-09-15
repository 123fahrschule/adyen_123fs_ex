ExUnit.start()

defmodule WithoutPlugSmokeTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    def run(request) do
      {request, Req.Response.new(status: 200, body: %{"paymentMethods" => []})}
    end
  end

  test "the consumer compiles without installing Plug or the optional WebhookPlug" do
    refute Code.ensure_loaded?(Plug.Conn)
    refute Code.ensure_loaded?(Adyen123FS.WebhookPlug)
    assert Code.ensure_loaded?(Adyen123FS.Webhook)
  end

  test "the client makes an offline request without Plug" do
    client = Adyen123FS.Client.new(api_key: "test-key", adapter: Adapter)

    assert {:ok, %{body: %{"paymentMethods" => []}}} =
             Adyen123FS.Checkout.payment_methods(client, %{"merchantAccount" => "Merchant"})
  end

  test "HMAC verification works without Plug" do
    payload =
      __DIR__
      |> Path.join("../../test/fixtures/standard_webhook.json")
      |> File.read!()
      |> Jason.decode!()

    key = "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056"
    assert {:ok, [_]} = Adyen123FS.Webhook.verify_standard_request(payload, key)
  end
end
