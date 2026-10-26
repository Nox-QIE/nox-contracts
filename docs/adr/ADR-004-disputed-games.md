# ADR-004: Disputed games and the reveal deadline

- Status: accepted
- Date: 2026-10-26

## Context

Nox's fairness claim rests on the operator revealing every committed role and night action at the end of a game. Two failures would quietly undermine it:

1. **The reveal does not match the commitments** (a server bug or tampering). `revealAndFinalize` reverts, and a revert leaves no trace on chain: without more, the server could simply cancel the game and nobody would know why.
2. **The reveal never comes.** A server that dislikes the outcome, or that cheated and would be caught, could leave the game `Running` forever.

## Decision

1. A new terminal status **`Disputed`** (appended to the enum, so existing codes keep their values) and an event **`GameDisputed(gameId, reason, detail)`**.
2. **`reportDispute(gameId, detail)`** (operator only, while `Running`, reason `DISPUTE_REVEAL_MISMATCH = 1`): the bot calls it when simulating its own reveal fails with `BadReveal`, `BadNightReveal` or `RevealCountMismatch`, instead of cancelling. The failure becomes a permanent public record.
3. **`claimRevealTimeout(gameId)`** (anyone, reason `DISPUTE_REVEAL_TIMEOUT = 2`): allowed once a `Running` game has been silent longer than `revealTimeout` (default 6 hours, admin-settable, at least 10 minutes). Silence is measured from `lastActivity`, updated on `commitRoles`, every night commitment, every vote and every recorded round. It is packed into the game's first storage slot, which adds about 3k gas to a vote.
4. A disputed game mints no credits and accepts no further actions, reveal or cancel.

## Consequences

- Any player or observer can force an outcome on a stalled game without trusting Nox.
- The operator cannot turn a failed reveal into a silent cancel: the bot reports it, and if the bot does not, the timeout does.
- `cancelGame` is still used for games that break before the end (players leave, chain errors during play). Cancelling stays operator-only and is logged with a reason.
- `games()` gains a `lastActivity` field after `nightCommits`. The fields read by index (`status` 0, `winner` 3) do not move.
- Contracts deployed before this change (the 25 Oct 2026 testnet deployment) do not have it. Redeploy to use it.
