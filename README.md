# allowit-contracts-tempo

This local Solidity rail adds funded Tempo custody beside the Solana paid-API vault. The owner chooses a six-decimal USD TIP-20 token, an executor, an independent offchain evidence authority, exact policy and requirements digests, and total/daily/per-payment limits. Jev and the AllowIt evaluator run in the existing backend. The evidence authority signs the exact approved execution; Solidity verifies that signature and always enforces the hard limits. Solidity does not compile or execute AllowIt Rust source or IR.

Contract and integration validation uses private Tempo chains. Production keys, deployment addresses and transaction artifacts are excluded from this repository.

## Owner flow and contract bindings

`AllowItTempoVaultFactory.createVault(policyId,token,executor,authority,terms,initialAmount)` deploys a non-upgradeable vault with CREATE2, then transfers the exact initial funding amount from `msg.sender`. The owner approves only the exact amount to the factory. A caller can create and fund only its own vault. `vaultOf(owner,policyId)` permanently identifies a created vault; a duplicate owner/policy deployment is rejected. `predictVault(owner,policyId,token,executor,authority,terms)` includes all constructor arguments in the address derivation.

`Terms` is `(bytes32 policyDigest,bytes32 requirementsDigest,uint256 totalUnits,uint256 dailyUnits,uint256 actionUnits,uint64 expiresAt,address recipient,bool semanticRequired)`.

The owner, token, executor, evidence authority and policy ID are immutable. Only the owner can fund, tune, revoke or withdraw. There is no arbitrary external-call, token approval, proxy, upgrade, owner transfer or self-destruct entrypoint. A zero terms recipient means the owner permits any nonzero recipient covered by the evidence authority's exact signature; a nonzero terms recipient additionally pins the destination.

`fund(amount)` replenishes the vault balance without resetting spend caps. `tune(terms)` increments revision and preserves lifetime spending, current-day spending, nonce and consumed request IDs. Revised total/daily limits cannot fall below already consumed usage. Source, expiry, recipient and semantic requirements may change only through an owner transaction. `revoke()` is permanent for this vault. `withdrawRemaining()` permanently revokes and returns all remaining tokens to the immutable owner, including after expiry. Issuer pause/compliance policies can prevent a transfer or recovery; the owner must resolve those issuer restrictions separately.

## Exact execution authorization

EIP-712 domain: `name = "AllowIt Tempo Vault"`, `version = "1"`, current chain ID, and `verifyingContract = vault`.

```
Execution(uint256 chainId,address vault,address token,bytes32 policyId,bytes32 policyDigest,bytes32 requirementsDigest,uint64 revision,uint64 nonce,address recipient,uint256 amount,uint64 expiresAt,bytes32 requestHash,bytes32 assessmentHash,bytes32 memo)
```

The executor calls `execute(Execution,bytes authoritySignature)`. The low-S secp256k1 signature is verified with OpenZeppelin ECDSA. The evidence authority must compile/evaluate the owner's reviewed snapshot itself and attest only an approved result; a hash supplied by a caller is not evidence. A required semantic policy needs a nonzero assessment digest, but the digest's interpretation and Jev result remain the evidence authority's responsibility.

The contract requires exact current chain/vault/token/policy/source/requirements/revision binding, next nonce exactly `previous + 1`, a nonzero request digest unused within this vault across all revisions, nonzero amount, an authorized recipient, and an exclusive expiry boundary. EIP-712 binds authorizations to the exact vault, preventing cross-vault signature replay. Attestations may remain valid for at most five minutes and never past the mandate expiry. A revised source invalidates old signatures. Consumed request IDs cannot be reused after tuning. Total, UTC-day and per-payment caps are checked regardless of the evidence contents.

State changes precede token interaction and roll back atomically on failure. Memo transfers use the official TIP-20 interface; ordinary transfers use OpenZeppelin SafeERC20. Exact source and recipient balance deltas are required. This rejects fee-on-transfer behavior and Tempo ReceivePolicyGuard redirection that would otherwise produce a successful transaction without delivery to the intended recipient.

`Executed(bytes32 indexed requestHash,address indexed recipient,uint64 indexed nonce,uint64 revision,uint256 amount,bytes32 assessmentHash,bytes32 memo)` is the canonical application event. Backend settlement must also verify the exact TIP-20 `Transfer` log, canonical finalized block, caller, target and prepared calldata. Save chain ID, transaction hash and log index; a timeout does not justify submitting another payment.

`getState()` returns the static 15-word tuple: Terms (8 words), revision, nonce, lifetime spent, stored daily spent, stored spend-day number, revoked boolean, token balance. Consumers treat daily spent as zero when the stored spend-day differs from `block.timestamp / 86400`; the getter itself does not normalize that value. API wire values exceeding JavaScript's safe integer range must be decimal strings, especially a `uint64.max` expiry.

## Local verification

Dependencies are pinned in `dependencies.lock.json`. Install them without commits or submodules:

```sh
forge install --no-git openzeppelin-contracts=OpenZeppelin/openzeppelin-contracts@rev=fcbae5394ae8ad52d8e580a3477db99814b9d565
forge install --no-git forge-std=foundry-rs/forge-std@rev=0258fe875e1d8e207c1eb7175e542ea32356773c
forge install --no-git tempo-std=tempoxyz/tempo-std@rev=701c4bf8d8d275f44c025b4686b42a82a83a3184
```

`lib/`, build output, broadcasts and environment files are ignored. This repository contains only the Tempo contracts, their tests and public documentation; backend/frontend integration and internal project materials belong in their separate repositories. Anvil/Forge signing keys in tests are published synthetic fixtures, never user keys.

Use official upstream Foundry v1.8.5 or later with Tempo support. Archived `tempoxyz/tempo-foundry` and `tempo-ts` should not be used for a new integration. The installed v1.8.5 CLI uses `anvil --network tempo` and `forge --network tempo`; `foundry.toml` enables Tempo execution. Run `forge config` or help against the installed release to verify exact supported flags.

```
forge build
forge fmt --check
forge test -vv
anvil --network tempo --host 127.0.0.1
```

The unit/fuzz suite covers binding substitution, independent EIP-712 encoding, malformed/high-S signatures, nonce/request replay, exclusive expiry, semantic hashes, action/day/total limits, UTC rollover, revision preservation, permanent revocation, owner recovery, balance conservation, hostile token false returns, issuer pause, redirection, failed-funding rollback and deterministic factory deployment. Stateful invariants use 256 runs of depth 64 and randomized payments, funding, time advance, tuning and recovery. A separate suite exercises actual Tempo TIP-20 and TIP-403 precompiles, memo transfers, issuer pause, recipient blacklist and ReceivePolicyGuard redirection without public RPC or mocked tokens.

Ordinary Ethereum simulation does not reproduce Tempo's stateful precompiles or storage gas schedule. Tempo state creation costs 250,000 gas per fresh storage slot, so deployment and state-heavy execution estimates must come from a Tempo-aware runtime. Batch calls are atomic, native transaction value is always zero, and a single top-level CREATE must be first if used. Root keys are required for a top-level contract creation; scoped access keys can call an allowed factory.

For actual wallet transactions, use current `viem/tempo` or Viem's Tempo chain formatters, explicitly select the configured USD TIP-20 fee token, and confirm the wallet's account and chain before signing. Do not use `eth_getBalance` as the stablecoin balance; use TIP-20 `balanceOf`.

## Sources examined on 2026-10-11

Primary maintained sources were used instead of copying unaudited third-party escrow snippets:

- [Official Tempo documentation source](https://github.com/tempoxyz/docs), commit `2ee6e8d3f6258ecc162960737a16cded41b11202`. Network details, EVM differences, payments, fee selection, receive-policy monitoring and current Foundry/TypeScript guides.
- [Tempo Solidity standard library](https://github.com/tempoxyz/tempo-std), commit `701c4bf8d8d275f44c025b4686b42a82a83a3184`. Exact TIP-20/TIP-403/precompile interfaces and standard address constants.
- [Tempo application monorepo](https://github.com/tempoxyz/tempo-apps), commit `2635aee282616b9dc0157d61b4c8427ed0b98042`. Maintained fee-payer, key-management, verification and explorer patterns.
- [Wevm MPP SDK](https://github.com/wevm/mppx), commit `d8d800f101ba1568f0d737e12574c0ae8f6b6e93`. Payment-channel binding, signed cumulative amounts, separation of authorization/spend/settlement and exact escrow trust. This flow uses one-shot vault executions, not a streaming-payment channel.
- [Tempo core](https://github.com/tempoxyz/tempo), commit `87bd32a63d60de656a7571025048420cc1e41758`. Chain execution, native payment semantics and current implementation.
- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.5.0), commit `fcbae5394ae8ad52d8e580a3477db99814b9d565`. EIP-712, ECDSA low-S validation, SafeERC20 and ReentrancyGuard.
- [Foundry v1.8.5](https://github.com/foundry-rs/foundry/releases/tag/v1.8.5). Version validated on the remote workstation; forge-std commit `0258fe875e1d8e207c1eb7175e542ea32356773c`.

Mainnet is chain ID 4217 at `https://rpc.tempo.xyz`. Moderato testnet is chain ID 42431 at `https://rpc.moderato.tempo.xyz`. The integration defaults to explicitly configured localnet/testnet; selecting a token or network is not an automatic approval to move funds there. Test AlphaUSD is a test asset and must never inherit the USDC label.
