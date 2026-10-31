<div align="center">

# Allowit on Tempo

*Policy-controlled TIP-20 payment vaults for AI agents*

[![Tempo contracts](https://img.shields.io/github/actions/workflow/status/allowit-hq/allowit-contracts-tempo/contracts.yml?style=flat-square&label=contracts)](https://github.com/allowit-hq/allowit-contracts-tempo/actions/workflows/contracts.yml)
[![Tempo Rust vendor](https://img.shields.io/github/actions/workflow/status/allowit-hq/allowit-contracts-tempo/rust.yml?style=flat-square&label=rust)](https://github.com/allowit-hq/allowit-contracts-tempo/actions/workflows/rust.yml)
[![Solidity 0.8.30](https://img.shields.io/badge/Solidity-0.8.30-363636?style=flat-square&logo=solidity)](foundry.toml)
[![Rust 1.98](https://img.shields.io/badge/Rust-1.98-dea584?style=flat-square&logo=rust)](rust/Cargo.toml)
[![Node.js >=24](https://img.shields.io/badge/Node.js->=24-3c873a?style=flat-square&logo=node.js&logoColor=white)](package.json)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

**Go on. On your terms.**

[What is this?](#what-is-this) • [Features](#features) • [Quick start](#quick-start) • [Deploy to Moderato](#deploy-to-moderato-testnet) • [How it works](#how-it-works) • [Contract API](#contract-api) • [Rust crates](#rust-crates) • [Allowit family](#the-allowit-family)

</div>

Allowit lets your AI agents spend and invest, within a policy you set. This repository is the [Tempo](https://github.com/tempoxyz/tempo) rail: two small Solidity contracts that hold stablecoins for an agent, plus Rust crates that verify, sign and deliver each payment.

You fund a vault. You name the executor that may spend, the authority that must approve, and the caps that never bend. The agent pays merchants from the vault. Everything else stays in your hands.

## What is this?

An Allowit policy is evaluated offchain by an **evidence authority**, which signs a short EIP-712 attestation for one exact payment. The onchain vault does not run the policy. It checks that the attestation binds to this vault, this policy revision, this recipient and this amount, then checks the hard limits you set and moves the tokens. That split keeps the contract tiny and keeps your money behind rules a model cannot talk its way around.

The repository has three parts:

| Part | Where | What it does |
| --- | --- | --- |
| Solidity contracts | [`src/`](src) | `AllowItTempoVault` holds funds and enforces limits. `AllowItTempoVaultFactory` creates one vault per owner and policy. |
| Rust vendor crate | [`rust/`](rust) | `allowit-tempo` verifies plans offline and, with the `client` feature, signs and sends native Tempo transactions, recovers interrupted payments and pays MPP `402` challenges. |
| Rust host services | [`rust/services/`](rust/services) | `allowit-tempo-services` gives the Allowit server typed RPC requests and native `0x76` transaction encoding. |

## Features

- **Hard caps, enforced onchain** - total, daily and per-payment limits in six-decimal USD units. The UTC day resets daily usage; nothing else does.
- **One signature per payment** - the authority signs an `Execution` struct that pins chain, vault, token, policy digests, revision, nonce, recipient, amount, expiry and request hash. Attestations live at most five minutes.
- **No replays, ever** - each payment needs the next nonce and an unused request hash. Tuning the terms bumps the revision and voids every older signature.
- **Exact delivery** - the vault compares balances before and after each transfer. Fee-on-transfer tokens, redirected receipts and partial deliveries revert the whole payment.
- **Owner stays in charge** - only the owner funds, tunes, revokes or withdraws. Funding never raises the spending caps. Withdrawal works even after expiry.
- **No upgrades, no arbitrary calls** - the vault has no proxy, grants no token approvals and calls nothing but its own token (plus one TIP-20 factory check at deployment).
- **Native Tempo** - TIP-20 tokens, `transferWithMemo` for tagged payments, TIP-403 aware tests, and type `0x76` transactions paid in a TIP-20 fee token.
- **Offline-first Rust** - the default crate build verifies a plan without a signing key or a network connection.

## Quick start

You need Node 24 and [Foundry v1.8.5](https://github.com/foundry-rs/foundry/releases/tag/v1.8.5) or later with Tempo support.

```sh
git clone https://github.com/allowit-hq/allowit-contracts-tempo.git
cd allowit-contracts-tempo
```

Install the pinned libraries. The exact revisions are recorded in [`dependencies.lock.json`](dependencies.lock.json):

```sh
forge install --no-git openzeppelin-contracts=OpenZeppelin/openzeppelin-contracts@rev=fcbae5394ae8ad52d8e580a3477db99814b9d565
forge install --no-git forge-std=foundry-rs/forge-std@rev=0258fe875e1d8e207c1eb7175e542ea32356773c
forge install --no-git tempo-std=tempoxyz/tempo-std@rev=701c4bf8d8d275f44c025b4686b42a82a83a3184
```

Build, lint and test on the Tempo runtime:

```sh
forge build
forge fmt --check
forge test --network tempo -vv
```

> [!TIP]
> `forge test --network tempo` runs the Tempo precompiles, so the suite in [`test/TempoNative.t.sol`](test/TempoNative.t.sol) can create a real TIP-20 token, pause it, blacklist a recipient and prove the vault rolls back cleanly each time. For a local node, run `anvil --network tempo --host 127.0.0.1`.

The test suite covers authorization, every binding substitution, replay, nonce order, expiry boundaries, the five-minute attestation window, total and daily caps across day rollover, fixed recipients, semantic assessments, tuning, revocation, owner recovery, token failures, reentrancy, factory atomicity and fuzzed conservation. Two invariants check that caps and nonces always hold and that tokens are conserved with owner-only recovery.

## Deploy to Moderato testnet

| Network | Chain ID | RPC |
| --- | --- | --- |
| Moderato testnet | 42431 | https://rpc.moderato.tempo.xyz |

The deployment scripts in [`scripts/moderato-demo.mjs`](scripts/moderato-demo.mjs) create wallets, request faucet funds, deploy the factory and verify it. Install dependencies and build first:

```sh
npm ci
forge build
```

Pick a wallet directory outside every Git checkout and an absolute manifest path outside that wallet directory. Then run the four stages in order:

```sh
wallet_dir="$HOME/.local/share/allowit-tempo-moderato-demo"
manifest=/absolute/path/to/demo/config/deployment.json
npm run demo:wallets -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:fund -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:deploy -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:verify -- --manifest "$manifest"
```

What each stage does:

1. **wallets** creates five separate accounts: deployer, owner, executor, authority and recipient. Keys land in owner-only `0600` files inside a `0700` directory. The script refuses to overwrite keys or a manifest.
2. **fund** tops up deployer, owner and executor with at most one Tempo faucet call per account, skipping any account that already holds enough, then waits for the balances. The owner needs at least 40 USD in payment and fee tokens; the others need 10.
3. **deploy** checks the chain ID, writes the manifest before broadcasting, then sends one native `0x76` transaction that creates the factory.
4. **verify** waits for the receipt, checks the transaction shape, compares the deployed code hash with the compiled runtime and waits for finality. It needs only the public manifest.

AlphaUSD (`0x20c0000000000000000000000000000000000001`) is the default payment and fee token. To use another six-decimal USD TIP-20 token, pass the same `--token` and `--fee-token` to every command. `--rpc` and `--artifact` override the RPC URL and the compiled factory artifact.

The manifest records the factory address, code hash, transaction hash, block number and account addresses. Keep it for your application's configuration. If a broadcast loses its reply, the manifest stays at `broadcasting` and the script refuses a blind retry until you inspect the deployer nonce and receipt.

Offline checks for the scripts run with:

```sh
npm run test:deployment
```

## How it works

```
 owner                       authority                 executor (agent)
   │                            │                            │
   │ createVault / fund / tune  │                            │
   ▼                            │                            │
┌──────────────────────┐        │ evaluates the policy       │
│  AllowItTempoVault   │        │ offchain, signs Execution  │
│  caps · nonce · terms│◀───────┴────────────────────────────┤ execute(request, signature)
│  TIP-20 balance      │                                     │
└──────────┬───────────┘                                     │
           │ transfer / transferWithMemo (exact amount)      │
           ▼                                                 │
       recipient                                             │
```

1. The owner calls `createVault` on the factory with a policy ID, token, executor, authority, terms and an initial deposit. The factory deploys the vault with CREATE2 and funds it in the same transaction.
2. The agent asks for a payment. The Allowit authority evaluates the reviewed policy offchain and signs an `Execution` for that exact payment.
3. The executor calls `execute(request, authoritySignature)`. The vault checks the signer, every binding, the next nonce, the unused request hash, the recipient rule, expiry and all three caps.
4. The vault transfers the exact amount, records usage, and emits `Executed` with the request hash, recipient, nonce, revision, amount, assessment hash and memo.
5. At any time the owner can `fund`, `tune`, `revoke` or `withdrawRemaining`.

Settlement consumers should confirm the `Executed` event and the TIP-20 `Transfer` in a finalized block, with the expected caller, target and calldata. Record chain ID, transaction hash and log index before any retry.

[`docs/tempo-vault.md`](docs/tempo-vault.md) describes the vault lifecycle and the transactions that the Rust crate validates offline.

## Contract API

### `AllowItTempoVaultFactory`

[`src/AllowItTempoVaultFactory.sol`](src/AllowItTempoVaultFactory.sol) is permissionless. A caller can create and fund only its own vault.

| Method | Effect |
| --- | --- |
| `createVault(policyId, token, executor, authority, terms, initialAmount)` | Deploy one vault per `(owner, policyId)` with CREATE2 and transfer `initialAmount` into it. Reverts on a duplicate, on zero funding or on a short delivery. |
| `predictVault(owner, policyId, token, executor, authority, terms)` | Compute the vault address before creation. |
| `vaultOf(owner, policyId)` | Look up an existing vault. |
| `DEPOSIT_TERMS_VERSION` | Constant `1`. Check it, together with the factory runtime hash, before preparing deposit-selected terms. |

Approve the exact initial amount before calling `createVault`. Funding may exceed the spending caps; it never raises them.

### `AllowItTempoVault`

[`src/AllowItTempoVault.sol`](src/AllowItTempoVault.sol) fixes owner, token, executor, authority and policy ID at construction. The token must be a canonical TIP-20 with six decimals and `USD` currency.

`Terms` is `(bytes32 policyDigest, bytes32 requirementsDigest, uint256 totalUnits, uint256 dailyUnits, uint256 actionUnits, uint64 expiresAt, address recipient, bool semanticRequired)`. A zero `recipient` permits any nonzero recipient that the authority signs. `actionUnits <= dailyUnits <= totalUnits` must hold.

> [!NOTE]
> The token issuer still has a say. A paused TIP-20 or a TIP-403 transfer policy can block funding, payments and owner recovery alike; the vault reverts cleanly rather than moving funds partially.

| Method | Who | Effect |
| --- | --- | --- |
| `fund(amount)` | owner | Add tokens without touching usage or caps. |
| `tune(terms)` | owner | Replace terms and advance `revision`. Usage, nonce and consumed request hashes are kept. New caps cannot fall below what is already spent. |
| `revoke()` | owner | Permanently disable payments. |
| `withdrawRemaining()` | owner | Revoke and return the whole balance to the owner, including after expiry. |
| `execute(request, authoritySignature)` | executor | Pay one authority-signed request. |
| `executionDigest(request)` | anyone | The EIP-712 digest the authority signs. |
| `getState()` | anyone | Terms, revision, nonce, spent, spentToday, spendDay, revoked flag and token balance. |

Events: `Funded`, `Tuned`, `Revoked`, `Recovered`, `Executed`. Errors: `Unauthorized`, `InvalidConfiguration`, `InvalidToken`, `Inactive`, `Expired`, `BindingMismatch`, `Replay`, `LimitExceeded`, `InvalidAttestation`, `DeliveryMismatch`.

### Execution authorization

EIP-712 domain: `name = "AllowIt Tempo Vault"`, `version = "1"`, the current chain ID, `verifyingContract = vault`.

```
Execution(uint256 chainId,address vault,address token,bytes32 policyId,bytes32 policyDigest,bytes32 requirementsDigest,uint64 revision,uint64 nonce,address recipient,uint256 amount,uint64 expiresAt,bytes32 requestHash,bytes32 assessmentHash,bytes32 memo)
```

The vault accepts a request only when all of these hold:

- `msg.sender` is the executor and the vault is not revoked.
- Neither the terms nor the request have expired, and `request.expiresAt` is at most 300 seconds ahead and not past the terms' expiry.
- Chain ID, vault, token, policy ID, both digests and revision match the vault exactly.
- The recipient is nonzero, is not the vault, and equals the fixed recipient when one is set.
- `requestHash` is nonzero and unused; `nonce` is exactly the current nonce plus one.
- When `semanticRequired` is set, `assessmentHash` is nonzero.
- `amount` is nonzero and within the per-payment, remaining daily and remaining total caps.
- The signature recovers to the authority.

A nonzero `memo` uses TIP-20 `transferWithMemo`; a zero memo uses a plain transfer. Either way the vault verifies that it lost exactly `amount` and the recipient gained exactly `amount`.

When you read `getState()`, treat `spentToday` as zero if `spendDay` is behind the current UTC day. Encode integers beyond JavaScript's safe range as decimal strings. Wallet integrations use `viem/tempo`, select a TIP-20 fee token and read the token's `balanceOf`.

## Rust crates

### `allowit-tempo` (vendor crate)

[`rust/`](rust/README.md) verifies Tempo plans against exact configuration, policy and transaction bindings, validates MPP challenges and, with the `client` feature, signs and sends payments as the designated executor with a durable journal for recovery.

```sh
cargo test --manifest-path rust/Cargo.toml --locked
cargo test --manifest-path rust/Cargo.toml --locked --features client
```

The executor commands are `import`, `execute`, `pay`, `call`, `resume`, `submit` and `status`. Configuration comes from `ALLOWIT_TEMPO_*` environment variables. See [`rust/src/tempo-usage.txt`](rust/src/tempo-usage.txt) for the full reference and exit codes.

### `allowit-tempo-services` (host services)

[`rust/services/`](rust/services/README.md) packages typed RPC requests and native `0x76` transaction signing for the Allowit server. It signs one self-paid EOA call and refuses sponsorship, access keys, extra calls and noncanonical signatures.

```sh
cargo fmt --manifest-path rust/services/Cargo.toml --check
cargo clippy --manifest-path rust/services/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/services/Cargo.toml --locked
```

## Project structure

```
src/                      Solidity vault and factory
test/                     Foundry unit, invariant and native Tempo tests
scripts/                  Moderato deployment scripts and their offline tests
rust/                     allowit-tempo vendor crate (verification + executor client)
rust/services/            allowit-tempo-services host protocol crate
docs/                     Vault lifecycle and transaction validation notes
.github/workflows/        contracts, runtime smoke, Rust vendor and services CI
foundry.toml              Solidity 0.8.30, osaka EVM, via-IR, Tempo mode on
dependencies.lock.json    Pinned Foundry library revisions
```

## The Allowit family

Allowit policies are written in a restricted subset of Rust and run on a deterministic interpreter. Each rail enforces the result on its own chain, and this repository is the Tempo rail. Its siblings:

- [allowit-sdk](https://github.com/allowit-hq/allowit-sdk) - the policy language, compiler, deterministic interpreter, CLI and language server. The Rust crates here depend on its `allowit-sdk` core crate (`core/`) for shared client, service and transport primitives.
- [allowit-cli](https://github.com/allowit-hq/allowit-cli) - the Go command-line client for evaluating and executing actions under a policy.
- [allowit-contracts-stellar](https://github.com/allowit-hq/allowit-contracts-stellar) - policy vaults and factory for Stellar.
- [allowit-contracts-solana](https://github.com/allowit-hq/allowit-contracts-solana) - policy evaluator and custody vault for Solana.
- [allowit.xyz](https://allowit.xyz) - the story, in full.

## Resources

- [Tempo documentation](https://github.com/tempoxyz/docs)
- [Tempo Solidity interfaces (`tempo-std`)](https://github.com/tempoxyz/tempo-std)
- [Tempo application examples](https://github.com/tempoxyz/tempo-apps)
- [Tempo core](https://github.com/tempoxyz/tempo)
- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.5.0)
- [MPP SDK](https://github.com/wevm/mppx)

## Contributing

Issues and pull requests are welcome. Before you open one, run the same checks CI runs: `forge fmt --check`, `forge build`, `forge test --network tempo`, `npm run test:deployment`, and the Cargo commands above for the crates you touched. Keep the pinned dependency revisions unless the change is about updating them.

## License

The contracts, scripts and the `allowit-tempo` crate are released under the [MIT License](LICENSE). The `allowit-tempo-services` crate carries `LicenseRef-Proprietary` in its [`Cargo.toml`](rust/services/Cargo.toml); see that crate's [README](rust/services/README.md).
