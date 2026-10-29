# Tempo host services

Typed RPC requests and native `0x76` transaction encoding for the SDK service facade. The server retains policy admission, signer selection, journals, budgets and recovery decisions.

`transaction::NativeTransaction` signs and checks one self-paid EOA call. It binds the chain, fee token, destination, calldata, gas limits and nonce. It rejects sponsorship, access keys, additional calls and noncanonical signatures.

The copied transaction implementation retains `LicenseRef-Proprietary`. Its engine source revision is recorded in `Cargo.toml`.

```sh
cargo fmt --manifest-path rust/services/Cargo.toml --check
cargo clippy --manifest-path rust/services/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/services/Cargo.toml --locked
```
