# nox-contracts

Smart contracts for [Nox](https://github.com/Nox-QIE): provably fair Werewolf on QIE.

| Contract | Purpose |
|---|---|
| `NoxGame` | Commit-reveal record of a game: create, join (player wallet), commit role Merkle root, commit night actions and cast votes (player wallets), record rounds, then reveal and verify every role and night action at finalize. A failed or missing reveal ends as `Disputed` (operator report, or anyone after `revealTimeout`); see [ADR-004](docs/adr/ADR-004-disputed-games.md). Credits per player follow a versioned formula (participation, win, seer hit, doctor save, accurate vote, daily streak; hunter and witch reuse the seer-hit and doctor-save amounts), all computed from on-chain data; see [ADR-005](docs/adr/ADR-005-reward-formula.md) |
| `NoxCredits` | Non-transferable ERC-20 status points (0 decimals), minted by `NoxGame` at finalize |
| `NoxAgentRegistry` | Third-party AI Game Masters: owner, mode, status, persona/endpoint hash, revenue share (default 30%) |
| `NoxPayments` | Host/Season Pass (QIE or QUSDC; rupiah recorded), Game Night with instant agent share, monthly agent pool, pull withdrawals. See [ADR-003](docs/adr/ADR-003-payments-and-agent-revenue.md) |
| `NoxBadges` | Non-transferable achievement badges (e.g. Scam Spotter), awarded by the operator per game with the game id in the event. See [ADR-007](docs/adr/ADR-007-badges.md) |

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

`script/DeployGame.s.sol` replaces only `NoxGame` next to an existing `NoxCredits` (`NOX_CREDITS`). When the broadcaster is the credits admin, it also grants the new game the minter role. Credits, registry, payments and badges keep their addresses and history.

```bash
cast wallet import nox-deployer --interactive   # once; stores the key encrypted, not in shell history
NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/Deploy.s.sol --rpc-url qie_testnet --account nox-deployer --broadcast
```

Then set `NOX_GAME_ADDRESS` in nox-backend.

Add `--slow` when broadcasting to QIE: its Cosmos EVM rejects a transaction whose nonce arrives ahead of the previous one (`invalid nonce; got 4, expected 3: invalid sequence`). Forge retries without it, but `--slow` sends one transaction at a time.

## Mainnet runbook

1. **Wallets.** On mainnet, keep three roles apart:
   - the **deployer** (pays the deploy, then has no role);
   - the **admin** (`NOX_ADMIN`): a cold wallet that changes the rewards, the reveal timeout and the roles;
   - the **operator** (`NOX_OPERATOR`): the bot's hot key, used only to run games and gas drips.

   If the bot's key leaks, an operator-only key cannot change credits or grant roles.
2. **Fund.** There is no mainnet faucet.
   - The deploy simulates at 8.17M gas, about 0.0092 QIE at 1.125 gwei; the preflight asks for twice that.
   - The operator needs a float for games: a 5-player game used about 1.52M gas on testnet (operator steps, players' transactions paid through gas drips, and the drips themselves), about 0.0017 QIE.
   - Start with at least 0.5 QIE on the operator (the bot alerts below `NOX_TREASURY_ALERT`).
3. **Preflight** (no key, sends nothing): checks RPCs, gas price, roles, the simulation and the deployer's balance.
   ```bash
   DEPLOYER=0x... NOX_ADMIN=0x... NOX_OPERATOR=0x... script/preflight.sh mainnet
   ```
4. **Deploy and verify** in one go. The mainnet Blockscout verifier lists solc 0.8.28, and `foundry.toml` has its API under `[etherscan]`.
   ```bash
   NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/Deploy.s.sol --rpc-url qie_mainnet --account nox-deployer --broadcast --slow --verify --verifier blockscout --verifier-url https://mainnet.qie.digital/api/
   ```
5. **Record** the addresses in `deployments/qie-mainnet.json` and the README, then set them in nox-backend's `.env` (`NOX_CHAIN=mainnet`, `NOX_GAME_ADDRESS`, `NOX_AGENT_REGISTRY_ADDRESS`, `NOX_PAYMENTS_ADDRESS`, `NOX_PAYMENTS_FROM_BLOCK`) and in the dashboard build.
6. **Configure** with the admin wallet: pass prices (`configurePass`), and `allowToken` for QUSDC if passes are sold in it.
7. **Smoke test**: one `npm run sim:game` (about 0.002 QIE), then `npm run indexer -- --once`. The credits reconciliation must report 0 mismatches.

## Deployments

| Network | Contracts | Block | Commit |
|---|---|---|---|
| QIE Testnet (1983) | [`deployments/qie-testnet.json`](deployments/qie-testnet.json): NoxCredits `0x67cA9002…a118`, NoxGame `0x916C51ea…5825` (replaced at block 9,385,811 / `aa22234` for game modes and the Scam Shield bonus), NoxAgentRegistry `0xC7977854…3937`, NoxPayments `0x67C052aB…a16c` (replaced at block 9,385,818 / `aa22234` for the one-time rupiah receipt; Host Pass 1 QIE per 30 days), NoxBadges `0x2DA54515…3850` (added at block 9,379,590 / `892a3ce`, Scam Spotter defined) | 9,375,796 | `8571a64` |
| QIE Testnet (1983), archive | NoxGame `0xa845444E…626e` (before ADR-004/005; the first real game was played here) | 9,366,050 | `5ae1fbd` |

Source verification on the testnet Blockscout (v7.0.2) fails for every Solidity version: its verifier currently lists no compilers (`/api/v2/smart-contracts/verification/config` returns an empty `solidity_compiler_versions`, checked 26 Oct 2026; the last testnet verification succeeded on 20 Oct). The mainnet verifier lists 0.8.28, so mainnet contracts can be verified without changing the compiler. The testnet faucet is at https://www.qie.digital/faucet; mainnet needs real QIE (no faucet).
