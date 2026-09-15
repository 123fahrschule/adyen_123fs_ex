# Fixture provenance

`standard_webhook.json` contains the public example from Adyen's
[HMAC verification guide](https://docs.adyen.com/development-resources/webhooks/secure-webhooks/verify-hmac-signatures/).
Its public demonstration key is in the test. These are not account credentials.

The UTF-8/separator and raw-body expected signatures were calculated independently
with Python's `hmac` and `hashlib.sha256`, using the same public example key.
Standard canonicalization is also checked against the
[official Node SDK](https://github.com/Adyen/adyen-node-api-library/blob/main/src/utils/hmacValidator.ts).
Standard NotificationRequestItem values are colon-joined without the legacy HPP
key/value escaping. Header-signed events use the exact original raw body.

Sources checked 2026-09-10. No test calculates its expected signature using the
implementation under test.

`checkout_v72_contract.json` is an extracted contract from Adyen's official
CheckoutService-v72 OpenAPI specification, pinned to the source revision and
SHA-256 recorded in the fixture. It includes HTTP methods, routes, required body
fields/types and required query parameters. It is not generated from this SDK.
`api_contract_test.exs` invokes all supported public Checkout endpoint functions
against it, including discovery without an idempotency key.

When upgrading the API version, retrieve the official specification at a pinned
revision, re-extract the supported operations, and inspect the diff. Keep test
fixtures offline and deterministic. These contract tests check routing and
required shapes; they do not replace Adyen's full conditional schema validation
or sandbox acceptance testing for your merchant account.

`data_protection_v1_contract.json` records the pinned Data Protection v1 method
and path. Its OpenAPI required-body list is empty; the separately attributed
documentation contract requires merchantAccount and pspReference and lists the
four result values. `data_protection_test.exs` checks that stricter input policy,
service routing and unchanged result handling.

`webhooks_v1_contract.json` extracts NotificationRequestItem's required fields
and sorted 40-value eventCode enum from pinned Webhooks v1. Each new fixture
records its source revision and the SHA-256 of the complete upstream JSON file,
not of the extracted fixture. The implementation contains its own event list;
tests compare it with the independent fixture without loading fixtures at runtime.

The unknown-event HMAC vector in `webhook_test.exs` was calculated independently
with Python hmac/hashlib, the public example key and the canonical UTF-8 string
`7914073381342284::TestMerchant:TestPayment-1407325143704:1130:EUR:NOT_A_REAL_EVENT:true`.
It proves that signature verification continues to accept a valid unknown event
so the application can route it to reconciliation.
