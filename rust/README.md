# Tempo vendor crate

`allowit-tempo` owns Tempo plan verification, native transactions, executor
recovery, MPP challenge validation and paid HTTP delivery. The SDK client facade
calls this crate. The crate uses shared SDK client primitives through
`allowit-client-core` and never depends on the facade.

The default feature set contains offline verification. Enable `client` for
executor transport, signing and durable journal recovery:

```sh
cargo test --manifest-path rust/Cargo.toml --locked
cargo test --manifest-path rust/Cargo.toml --locked --features client
```

The `run` entry point accepts Tempo operation arguments and separate output
buffers. The public verification functions accept exact configuration, policy
and transaction bindings. Offline verification reads no signing key and sends
no network request.

`validate_execution_request_service` binds normalized `ServicePaymentRequest`
terms to the authority-signed transaction. The terms bind the HTTP request,
network, asset, recipient, amount, memo and expiry. The action and merchant must
match those terms. Native identities remain unchanged without service terms.

The MPP adapter preserves its original `mppRequest` identity and challenge
checks through `execution_request_identity_mpp` and
`validate_execution_request_mpp`. These identities remain distinct from
`servicePaymentRequest` identities. Recovery verifies the original saved
transaction and request. It never creates a replacement payment or challenge.

The executor transport supports Tempo testnet and localnet. Owner deployment,
funding and recovery use browser signing. `execute` prepares a plan without
sending it. `pay` signs and sends with the designated executor key. `call`
handles the admitted testnet MPP profile. Payment and HTTP delivery remain
separate results. See [executor usage](src/tempo-usage.txt) for configuration,
commands, journal requirements and exit codes.

On macOS, use a canonical temporary directory for journal tests:
`TMPDIR=/private/tmp cargo test --manifest-path rust/Cargo.toml --locked --features client`.
The journal rejects symlinked directory components, including `/var` aliases.
