# allowit-contracts-tempo

Solidity vaults for policy-controlled TIP-20 payments on Tempo. An independent evidence authority approves each payment offchain. The vault checks its signature, policy binding and spending limits.

## Build and test

Use Node 24 and [Foundry v1.8.5](https://github.com/foundry-rs/foundry/releases/tag/v1.8.5) or later with Tempo support. Install pinned dependencies:

```sh
forge install --no-git openzeppelin-contracts=OpenZeppelin/openzeppelin-contracts@rev=fcbae5394ae8ad52d8e580a3477db99814b9d565
forge install --no-git forge-std=foundry-rs/forge-std@rev=0258fe875e1d8e207c1eb7175e542ea32356773c
forge install --no-git tempo-std=tempoxyz/tempo-std@rev=701c4bf8d8d275f44c025b4686b42a82a83a3184
```

```sh
forge build
forge fmt --check
forge test --network tempo -vv
anvil --network tempo --host 127.0.0.1
```

Tests cover authorization, replay, spending limits, owner recovery and native TIP-20/TIP-403 behavior. Use a Tempo runtime for gas estimates and precompile simulation.

## Deploy to Moderato testnet

| Network | Chain ID | RPC |
| --- | --- | --- |
| Moderato testnet | 42431 | https://rpc.moderato.tempo.xyz |

Install dependencies above, then run `npm ci` and `forge build`. Choose a fresh wallet directory outside every Git checkout. Set an absolute manifest path outside that wallet directory:

```sh
wallet_dir="$HOME/.local/share/allowit-tempo-moderato-demo"
manifest=/absolute/path/to/demo/config/deployment.json
npm run demo:wallets -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:fund -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:deploy -- --wallet-dir "$wallet_dir" --manifest "$manifest"
npm run demo:verify -- --manifest "$manifest"
```

The scripts create separate deployer, owner, executor, authority and recipient accounts. Keys remain in owner-only files. The faucet funds deployer, owner and executor. The owner needs at least 40 USD in payment and fee tokens.

AlphaUSD is the default payment and fee token. To choose other supported six-decimal USD tokens, pass matching `--token` and `--fee-token` options to every command.

Deployment checks chain ID, finalized receipt and factory runtime hash. The manifest records factory address, code hash, transaction and account addresses. Keep it for application configuration. If a broadcast loses its reply, inspect the original nonce and receipt before another deployment. Run `npm run test:deployment` for offline checks.

## Mainnet deployments

No AllowIt Tempo mainnet factory address is recorded in this repository. The deployment script accepts only Moderato testnet.

## Contract API

[`AllowItTempoVaultFactory`](src/AllowItTempoVaultFactory.sol) creates one immutable vault per owner/policy using CREATE2:

`createVault(policyId,token,executor,authority,terms,initialAmount)`

Approve the exact initial amount. Funding can exceed spending caps. Use `vaultOf(owner,policyId)` to retrieve the vault. Check factory runtime hash and `DEPOSIT_TERMS_VERSION() == 1` before preparing deposit-selected terms.

[`AllowItTempoVault`](src/AllowItTempoVault.sol) fixes owner, token, executor, authority and policy ID. Only the owner can fund, tune, revoke or withdraw.

`Terms` is `(bytes32 policyDigest,bytes32 requirementsDigest,uint256 totalUnits,uint256 dailyUnits,uint256 actionUnits,uint64 expiresAt,address recipient,bool semanticRequired)`.

| Method | Effect |
| --- | --- |
| `fund(amount)` | Add tokens without resetting spending. |
| `tune(terms)` | Advance revision while preserving usage, nonce and consumed request IDs. |
| `revoke()` | Permanently disable payments. |
| `withdrawRemaining()` | Revoke and return tokens to owner, including after expiry. |
| `getState()` | Return terms, revision, nonce, usage, day, revoked flag and balance. |

Issuer restrictions can block funding, payment or recovery. There are no upgrades or arbitrary external calls.

## Execution authorization

EIP-712 domain: `name = "AllowIt Tempo Vault"`, `version = "1"`, current chain ID, `verifyingContract = vault`.

```
Execution(uint256 chainId,address vault,address token,bytes32 policyId,bytes32 policyDigest,bytes32 requirementsDigest,uint64 revision,uint64 nonce,address recipient,uint256 amount,uint64 expiresAt,bytes32 requestHash,bytes32 assessmentHash,bytes32 memo)
```

The executor calls `execute(Execution,bytes authoritySignature)`. The authority evaluates the reviewed policy offchain. Solidity checks exact bindings, next nonce, unused request hash, recipient, expiry and total/daily/per-payment caps. Attestations last at most five minutes. Tuning invalidates old signatures. Semantic policies require a nonzero assessment hash.

Exact balance changes reject transfer fees and recipient redirection. Settlement consumers must check `Executed`, TIP-20 `Transfer`, finalized block, caller, target and calldata. Record chain ID, transaction hash and log index before retrying.

For `getState()`, treat stored daily usage as zero after the UTC day changes. Encode integers beyond JavaScript's safe range as decimal strings. Wallet integrations use `viem/tempo`, select a TIP-20 fee token and read token `balanceOf`.

## References

- [Tempo documentation](https://github.com/tempoxyz/docs)
- [Tempo Solidity interfaces](https://github.com/tempoxyz/tempo-std)
- [Tempo application examples](https://github.com/tempoxyz/tempo-apps)
- [Tempo core](https://github.com/tempoxyz/tempo)
- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.5.0)
- [MPP SDK](https://github.com/wevm/mppx)
