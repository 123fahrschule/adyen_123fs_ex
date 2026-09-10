# Phoenix webhook integration and durable payment state

The library supplies signature verification and an optional Plug. Your service
owns the database, transaction boundaries, retries and booking rules. No Ecto,
Oban or RabbitMQ dependency is imposed by this package.

## Mount the Standard webhook before body parsing

Add the plug in your Phoenix endpoint **before `Plug.Parsers`**, so it can read
the complete raw request body and enforce its size limit. The exact path is
handled and halted; all other requests continue down the endpoint pipeline.

```elixir
plug Adyen123FS.WebhookPlug,
  path: "/webhooks/adyen",
  hmac_keys: {MyApp.Payments, :webhook_keys, []},
  merchant_accounts: ["YOUR_MERCHANT_ACCOUNT"],
  persist: {MyApp.Payments.WebhookInbox, :store_batch, []},
  max_body_bytes: 1_000_000

plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"], json_decoder: Phoenix.json_library()
```

The named `MyApp` modules are application callbacks you implement, not modules
provided by the SDK. `webhook_keys/0` reads runtime configuration and returns the
current hex key, or `[current_key, previous_key]` during rotation. Keep live/test
webhooks and keys separate. The merchant list must match the actual account.

`store_batch/1` receives the verified item maps in delivery order. It must insert
them into a durable inbox and return **`:ok` only after commit**. For example,
adapt the following transaction outline to your own schema:

```elixir
def store_batch(items) do
  case MyApp.Repo.transaction(fn ->
         Enum.each(items, fn item ->
           # Application implementation: insert with a durable unique key;
           # a previously stored duplicate is a successful delivery.
           MyApp.Payments.WebhookInbox.insert_or_confirm_existing!(item)
         end)
       end) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

A DB error returns 503. Exceptions propagate as failed HTTP requests. The Plug
does not acknowledge failed storage and never starts a fire-and-forget Task.
After storing, a separate worker processes the inbox. Persisting an inbox row
and starting an external job must not leave a gap: either use a transactional
database job or poll unprocessed inbox rows. Keep business processing short and
outside the webhook HTTP request. Adyen expects an acknowledgement within ten
seconds; set short DB/pool timeouts in the callback so overload fails promptly.

An HMAC key source that raises also fails the request. Monitor these failures
and database failures as operational problems. Do not log API keys, webhook
keys, request bodies, wallet tokens, session data or full response structs.

## Duplicates and ordering

Delivery can be repeated and out of order. Adyen documents `eventCode` plus
`pspReference` for duplicate recognition; scope your inbox keys to merchant and
environment as well. Keep the original payload for reconciliation and account
for updated event data in repeated deliveries. A deduplication policy must not
silently discard a materially changed outcome. Use database uniqueness and
transactions to prevent the same event from creating two financial bookings.

Separate `paymentPspReference` (authorisation) from a modification's `pspReference`.
Webhook `originalReference` links modifications back to their original payment.
Use amount, currency, merchant reference and account to reconcile against the
local operation; never let the browser choose the payable amount or target order.

Suggested application states: created → awaiting_shopper → authorised →
capture_requested → captured. Include cancellation/refund requests and failure
states. Unknown outcomes need reconciliation. Do not model payment state as a
single paid boolean:

- AUTHORISATION success reserves funds for manual-capture payments.
- CAPTURE and CAPTURE_FAILED update the capture operation. A later failure can
  invalidate a previously successful capture notification.
- REFUND, REFUND_FAILED and REFUNDED_REVERSED update the refund operation.
- CANCELLATION and CANCEL_OR_REFUND complete their respective modifications.
- Preserve and route chargebacks and unknown event codes for reconciliation.

Immediate automatic capture does not normally emit a separate CAPTURE webhook.
Make your state transitions match the configured capture mode; the registration
flow described in the README explicitly requests manual capture.

## RegistrationService → Charger

Keep Adyen operations and the webhook inbox in RegistrationService. After the
state transition commits, place an integration event in a transactional outbox.
A worker publishes that outbox to RabbitMQ and retries until acknowledged. The
event should carry a unique event ID, registration/student reference, merchant,
payment PSP reference, modification PSP reference, operation type, amount,
currency and verified outcome. Send references and accounting facts, never card
or wallet payloads.

Charger consumes idempotently. If the Debitor is not yet available, retain/retry
the event instead of discarding it. Deduplicate booking by stable operation/event
identity inside the same transaction as the booking. This permits signup and
capture while Charger is unavailable and avoids booking an AUTHORISATION as a
completed capture. Decide explicitly how subsequent capture/refund failures
reverse or flag the corresponding accounting entries.

## Header-signed webhooks

The Plug handles Standard notifications only. For recurring token lifecycle or
other header-signed events, use a separate endpoint, read and limit the raw body,
require `protocol: HmacSHA256`, and verify the `hmacsignature` header using
`Adyen123FS.Webhook.verify_body/3` **before** JSON decoding. Apply the same durable
inbox/acknowledgement contract and validate the event's merchant and schema.

Sources: [handling webhooks](https://docs.adyen.com/development-resources/webhooks/handle-webhook-events/),
[HMAC verification](https://docs.adyen.com/development-resources/webhooks/secure-webhooks/verify-hmac-signatures/),
[capture](https://docs.adyen.com/online-payments/capture/).
