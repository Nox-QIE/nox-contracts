# nox-contracts

Smart contracts for [Nox](https://github.com/Nox-QIE): provably fair Werewolf on QIE.

| Contract | Purpose |
|---|---|
| `NoxGame` | Commit-reveal record of a game: create, join (player wallet), commit role Merkle root, commit night actions and cast votes (player wallets), record rounds, then reveal and verify every role and night action at finalize |
| `NoxCredits` | Non-transferable ERC-20 status points (0 decimals), minted by `NoxGame` at finalize |

Coming next: `NoxPayments` (passes, Game Night, agent revenue split), `NoxAgentRegistry` (Agent Marketplace).

Hashing follows `@nox/shared/crypto-spec` v1; see [ADR-001](docs/adr/ADR-001-commit-reveal-hashing.md). `test/vectors/crypto-spec-v1.json` is copied from [nox-shared](https://github.com/Nox-QIE/nox-shared) and the tests prove both sides hash identically.

## Build & test

Foundry, Solidity 0.8.28, OpenZeppelin 5.7.0, `evm_version = "shanghai"` (QIE has no Cancun opcodes).

```bash
git submodule update --init --recursive
forge test
forge test --gas-report
```

Networks: testnet 1983 via `https://rpc2testnet.qie.digital/` (`rpc1`/`rpc3` testnet are down), mainnet 1990 via `https://rpc1mainnet.qie.digital`.
