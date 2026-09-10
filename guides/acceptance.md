# Merchant acceptance testing

The offline suite verifies request contracts, response/error handling, signature
compatibility and webhook acknowledgement behavior. It cannot prove merchant
enablement, wallet domain setup or real issuer challenges. Before production,
exercise the following flows in your Adyen **test** environment through the
actual signup frontend and a durable webhook inbox.

| Flow | Expected observations |
| --- | --- |
| Card authorisation, manual capture | AUTHORISATION reserves; order confirmation sends one capture; modification reference is stored; CAPTURE updates the operation |
| Card refusal | resultCode Refused is displayed as refusal despite HTTP 200 |
| 3DS frictionless and challenge | browser action completes, details are submitted and correlated, webhook updates state |
| Apple Pay | domain and merchant validation succeed; token is forwarded without logging; capture/refund work for the underlying card |
| Google Pay | approved website and supported device show the wallet; token and any further action complete correctly |
| Alma | eligible country/currency/account receives Alma from paymentMethods; redirect and details complete; permitted capture/refund behavior matches merchant setup |
| Full and partial refund | unique key per refund, amount/currency reconcile, refund webhook completes the operation |
| Abandoned signup | uncaptured authorisation is cancelled and a late callback cannot create an unintended booking |
| Unknown capture state | reversal result is reconciled using its asynchronous webhook |
| Timeout after sending | retry uses the identical persisted key/body and produces one payment |
| Duplicate/out-of-order webhook | no duplicate financial booking; later CAPTURE_FAILED / REFUND_FAILED / REFUNDED_REVERSED are handled |
| RegistrationService restart | persisted operations and inbox/outbox resume without losing or duplicating work |
| Charger unavailable / Debitor not ready | signup/payment continues; accounting event is retained and eventually booked exactly once |

Use Adyen's [test cards](https://docs.adyen.com/development-resources/test-cards-and-credentials/test-card-numbers/)
and [payment-method-specific instructions](https://docs.adyen.com/payment-methods/).
No tests in this repository create real payments or need live credentials.

Keep API keys and webhook keys in runtime secrets. The API key, browser client
key and webhook HMAC key have different purposes. Configure test/live and the
live prefix explicitly; never switch endpoints/regions while retrying the same
operation because Adyen does not deduplicate idempotency keys across regions.

The SDK deliberately leaves amount calculation, shopper consent, registration
order confirmation, authorisation expiry scheduling, persistent retry policy and
accounting transitions to your application. The public map API forwards optional
fields without imposing a stale copy of Adyen's full schema.
