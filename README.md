# Adyen123FS

An Elixir client for Adyen Checkout, built on Req (the HTTP client included in
Phoenix 1.8's generated applications). Independent of Phoenix, Ecto and Charger.

## Configuration

```elixir
client = Adyen123FS.Client.new(api_key: System.fetch_env!("ADYEN_API_KEY"))

live_client = Adyen123FS.Client.new(
  api_key: System.fetch_env!("ADYEN_API_KEY"),
  environment: :live,
  live_prefix: System.fetch_env!("ADYEN_LIVE_PREFIX")
)
```

Test is the default environment, Checkout API version 72 is the default version.
Live URLs include your company prefix. No global configuration is required.
Requests return `{:ok, %Req.Response{}}` or `{:error, %Adyen123FS.Error{}}`.
HTTP success is distinct from payment success; inspect `resultCode` and process
verified webhooks. Redirects and automatic HTTP retries are disabled.

## Idempotency and errors

Generate `Adyen123FS.idempotency_key()` once and persist it with the operation
before sending. Supply `idempotency_key: persisted_key` on every attempt. Each
capture and refund is a separate operation with its own key. Never change the
payload or region while retrying an operation.

`error.retryable` tells a durable job whether a retry is permitted. HTTP errors
require Adyen's `transient-error: true`; keyed POST transport failures are also
retryable because their outcome is unknown. A timeout is not a failed payment.
An HTTP response without that header, or with `false`, must not be retried
automatically. Reconcile uncertain results using webhooks and your operation log.

The full `error.headers` includes `retry-after` (a list of header values, possibly
an HTTP date rather than seconds). Schedule the retry no earlier than that time,
and use bounded exponential backoff with jitter. The client makes **one HTTP
attempt** and does not sleep, drop the key, or retry behind your job queue.

Errors distinguish `:validation`, `:api`, `:protocol` (unexpected success body),
and `:transport`. Error `Inspect` hides bodies and reasons. Raw response bodies,
headers, wallet tokens and session data can contain sensitive data: do not log
them. The library emits no request payload logs or telemetry.

## Development

```sh
mix deps.get
mix test
mix format --check-formatted
mix docs --warnings-as-errors
```

The tests exercise the real public client against an in-process Req adapter;
they do not contact Adyen or charge money. Add tests and observe them failing
before implementing behavior. Keep commits focused and review each with CodeRabbit.

## Sources

- [Checkout API v72](https://docs.adyen.com/api-explorer/Checkout/72/overview)
- [Live endpoints](https://docs.adyen.com/development-resources/live-endpoints/)
- [API idempotency](https://docs.adyen.com/development-resources/api-idempotency/)
- [Req](https://hexdocs.pm/req/Req.html)

This is an independent client maintained by 123Fahrschule, not an official Adyen SDK.

## Payments and 3DS

```elixir
alias Adyen123FS.Checkout

# payment_method is the paymentMethod map provided by Adyen Web Components.
# amount and reference must come from your server-side order, not the browser.
params = %{
  "merchantAccount" => merchant_account,
  "amount" => %{"currency" => "EUR", "value" => 15000},
  "reference" => registration_reference,
  "returnUrl" => "https://signup.123fahrschule.de/payments/return",
  "paymentMethod" => payment_method,
  "channel" => "Web",
  "origin" => "https://signup.123fahrschule.de",
  "browserInfo" => browser_info
}

Checkout.create_payment(client, params, idempotency_key: payment_operation_key)

# After the Component's onAdditionalDetails or a redirect return:
Checkout.submit_details(client, %{"details" => details},
  idempotency_key: details_operation_key)
```

Forward Adyen's `action` to the Component without interpreting or stripping its
fields. `IdentifyShopper`, `ChallengeShopper` and `RedirectShopper` need further
shopper interaction. Pass the Component's details, including `paymentData` when
provided, to `submit_details/3`; reuse its operation key on retries. Handle
`Authorised`, `Refused`, `Pending`, `Received`, `Cancelled` and `Error` explicitly.
Treat unrecognised result codes conservatively. Verified webhooks drive your
durable payment state; an `Authorised` result is not a capture confirmation.

For the Sessions flow, use `create_session/3` with amount, merchantAccount,
reference and returnUrl. Return `id` and `sessionData` to Adyen Web. To retrieve
the outcome use `get_session(client, session_id, session_result)` with the actual
result from Adyen Web. A session ID alone cannot be polled for its result.

### Payment methods

| Method | paymentMethod.type | Source of payment details |
| --- | --- | --- |
| Credit cards | `scheme` | Adyen Components encrypted fields or storedPaymentMethodId |
| Apple Pay | `applepay` | Component payload including applePayToken |
| Google Pay | `googlepay` | Component payload including googlePayToken |
| Alma | `alma` | Redirect flow; additional shopper and order data as required |

This package implements the server API. Adyen Web remains responsible for secure
card fields, wallet buttons, device support and 3DS challenges. It neither stores
raw card details nor decrypts wallet tokens. `apple_pay_session/3` covers Adyen's
merchant-validation endpoint when that integration requires a server call; it
does not replace Apple Pay domain registration.

Call `payment_methods/2` with your merchantAccount, countryCode, amount and
shopperLocale to discover what Adyen enables for that transaction. In the current
[Alma documentation](https://docs.adyen.com/payment-methods/alma/api-only), Adyen
lists France/EUR. Do not assume an Alma offer for German shoppers just because
the client supports its API. Add telephoneNumber, shopperEmail, billingAddress
and deliveryAddress as required by your integration. The optional
`additionalData["alma.installments_count"]` selects 3 or 4 installments; omit it
to let the shopper choose. Complete its redirect through `submit_details/3`.

The new signup domain still needs Adyen Allowed Origins and the applicable
Apple Pay domain verification / Google Pay website approval. The SDK cannot
enable payment methods or merchant capabilities in any provider account.

## Reserve, confirm the order, capture

For your registration checkout, create the payment with:

```elixir
params = Map.put(params, "additionalData", %{"manualCapture" => "true"})
Checkout.create_payment(client, params, idempotency_key: payment_operation_key)
```

Merge this into existing additionalData when other fields are present. This
per-payment setting also works with `/sessions` and overrides the merchant's
global capture setting. `captureDelayHours` schedules automatic capture; it is
not the manual-capture setting. `authorisationType: PreAuth` is for adjustable
authorisations, not a replacement for manual capture.

After authorisation and the binding order confirmation, persist the capture
operation and call:

```elixir
Checkout.capture(client, payment_psp_reference, %{
  "merchantAccount" => merchant_account,
  "amount" => %{"currency" => "EUR", "value" => 15000},
  "reference" => capture_reference
}, idempotency_key: capture_operation_key)
```

Store both the original payment PSP reference and the capture PSP reference.
`status: received` means the request was accepted, not settled. Process CAPTURE
and CAPTURE_FAILED; a later CAPTURE_FAILED may arrive after a successful CAPTURE.
For abandoned registrations, schedule cancellation before the authorisation
expires. Expiry, partial capture and multiple capture support vary by method and
merchant configuration. By default a single partial capture releases the rest.

`refund/4` uses the original payment PSP reference, merchantAccount and amount
for full or partial refunds after capture. Each partial refund gets its own
persisted key. Handle REFUND, REFUND_FAILED and REFUNDED_REVERSED events.
Use `cancel/4` before capture, `cancel_by_reference/3` with `paymentReference`
when the PSP reference is unavailable, or `reverse/4` when the capture state is
unknown. Reversal eligibility has provider limitations; reconcile its webhook.

`update_amount/4` supports eligible pre-authorisation adjustments. Token creation,
listing and deletion are available via `store_payment_method/3`,
`list_stored_payment_methods/2` and `delete_stored_payment_method/3`. For a payment
with tokenization, pass storePaymentMethod, shopperReference and
recurringProcessingModel to `create_payment/3` after obtaining shopper consent.
Alma does not support recurring payments. Wallet tokenization depends on your
Adyen configuration and the payment method.

Sources: [capture](https://docs.adyen.com/online-payments/capture/),
[refund](https://docs.adyen.com/online-payments/refund/),
[Alma capabilities](https://docs.adyen.com/payment-methods/alma/),
[tokenization](https://docs.adyen.com/online-payments/tokenization/).
