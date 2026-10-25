# nox-contracts

Smart contracts for [Nox](https://github.com/Nox-QIE): provably fair Werewolf on QIE.

| Contract | Purpose |
|---|---|
| `NoxGame` | Commit-reveal record of a game: create, join (player wallet), commit role Merkle root, commit night actions and cast votes (player wallets), record rounds, then reveal and verify every role and night action at finalize |
| `NoxCredits` | Non-transferable ERC-20 status points (0 decimals), minted by `NoxGame` at finalize |
| `NoxAgentRegistry` | Third-party AI Game Masters: owner, mode, status, persona/endpoint hash, revenue share (default 30%) |
| `NoxPayments` | Host/Season Pass (QIE or QUSDC; rupiah recorded), Game Night with instant agent share, monthly agent pool, pull withdrawals. See [ADR-003](docs/adr/ADR-003-payments-and-agent-revenue.md) |

Hashing follows `@nox/shared/crypto-spec` v1; see [ADR-001](docs/adr/ADR-001-commit-reveal-hashing.md). `test/vectors/crypto-spec-v1.json` is copied from [nox-shared](https://github.com/Nox-QIE/nox-shared) and the tests prove both sides hash identically.

## Build & test

Foundry, Solidity 0.8.28, OpenZeppelin 5.7.0, `evm_version = "shanghai"` (QIE has no Cancun opcodes).

```bash
git submodule update --init --recursive
forge test
forge test --gas-report
```

Networks: testnet 1983 via `https://rpc2testnet.qie.digital/` (`rpc1`/`rpc3` testnet are down), mainnet 1990 via `https://rpc1mainnet.qie.digital`.

## Deploy

`script/Deploy.s.sol` deploys `NoxCredits` + `NoxGame` + `NoxAgentRegistry` + `NoxPayments`, grants the game the minter role, and hands credit admin to `NOX_ADMIN` (defaults to the deployer). `NOX_OPERATOR` (defaults to `NOX_ADMIN`) is the backend's operator wallet.

```bash
cast wallet import nox-deployer --interactive   # once; stores the key encrypted, not in shell history
NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/Deploy.s.sol --rpc-url qie_testnet --account nox-deployer --broadcast
```

Then set `NOX_GAME_ADDRESS` in nox-backend.

Add `--slow` when broadcasting to QIE: its Cosmos EVM rejects a transaction whose nonce arrives ahead of the previous one (`invalid nonce; got 4, expected 3: invalid sequence`). Forge retries without it, but `--slow` sends one transaction at a time.

## Deployments

| Network | Contracts | Block | Commit |
|---|---|---|---|
| QIE Testnet (1983) | [`deployments/qie-testnet.json`](deployments/qie-testnet.json): NoxCredits `0xbDe39D4d…f1fc`, NoxGame `0xa845444E…626e`, NoxAgentRegistry `0x27Add0D3…357e`, NoxPayments `0x8DcD6Ff6…B505` | 9,366,050 | `5ae1fbd` |

Source verification on the testnet Blockscout (v7.0.2) failed for solc 0.8.28 through both the etherscan-compatible and v2 APIs; contracts verified there so far use 0.8.25 or 0.8.30. Still to resolve. The testnet faucet is at https://www.qie.digital/faucet; mainnet needs real QIE (no faucet).
