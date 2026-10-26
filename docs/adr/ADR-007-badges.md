# ADR-007: Achievement badges on chain

- Status: accepted
- Date: 2026-10-26

## Context

Scam Shield rewards the group that exposes the scammers with a "Scam Spotter" badge (F10-S05). Until now that badge was only a Telegram DM. The player's record (D7) should show it, and like everything else in Nox, anyone should be able to check where it came from.

## Decision

- A separate contract, **NoxBadges**, so NoxGame (and its deployments and history) stays unchanged.
- The admin defines badges (`defineBadge(id, name, active)`; id = `keccak256("SCAM_SPOTTER")`, ...). The operator awards one badge to up to 12 players for one game: `award(badgeId, gameId, accounts)`.
- Each award emits `BadgeAwarded(account, badgeId, gameId, count)`. `gameId` points at the NoxGame game whose recorded winner justifies it. The same badge cannot be awarded twice for one game, so a retried transaction cannot inflate counts.
- Badges are a count per wallet and an event. There is no transfer, approval or redemption: status, not value (the same rule as credits).
- The award is attested by the operator. The game's result is public on NoxGame; whether a game was a Scam Shield game is part of its committed config, not readable on chain.

## Consequences

- The indexer can show badges in a player's record next to credits and streaks.
- Mainnet deploys NoxBadges with the rest (`Deploy.s.sol`). Testnet adds it with `DeployBadges.s.sol`.
