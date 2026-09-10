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
