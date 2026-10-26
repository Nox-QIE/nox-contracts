# nox-contracts

Smart contracts for [Nox](https://github.com/Nox-QIE): provably fair Werewolf on QIE.

| Contract | Purpose |
|---|---|
| `NoxGame` | Commit-reveal record of a game: create, join (player wallet), commit role Merkle root, commit night actions and cast votes (player wallets), record rounds, then reveal and verify every role and night action at finalize. A failed or missing reveal ends as `Disputed` (operator report, or anyone after `revealTimeout`); see [ADR-004](docs/adr/ADR-004-disputed-games.md). Credits per player follow a versioned formula (participation, win, seer hit, doctor save, accurate vote, daily streak), all computed from on-chain data; see [ADR-005](docs/adr/ADR-005-reward-formula.md) |
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
| QIE Testnet (1983) | [`deployments/qie-testnet.json`](deployments/qie-testnet.json): NoxCredits `0x67cA9002…a118`, NoxGame `0x5ecA1C5A…a6e4`, NoxAgentRegistry `0xC7977854…3937`, NoxPayments `0x691304FD…EE18` | 9,375,796 | `8571a64` |
| QIE Testnet (1983), archive | NoxGame `0xa845444E…626e` (before ADR-004/005; the first real game was played here) | 9,366,050 | `5ae1fbd` |

Source verification on the testnet Blockscout (v7.0.2) fails for every Solidity version: its verifier currently lists no compilers (`/api/v2/smart-contracts/verification/config` returns an empty `solidity_compiler_versions`, checked 26 Oct 2026; the last testnet verification succeeded on 20 Oct). The mainnet verifier lists 0.8.28, so mainnet contracts can be verified without changing the compiler. The testnet faucet is at https://www.qie.digital/faucet; mainnet needs real QIE (no faucet).
