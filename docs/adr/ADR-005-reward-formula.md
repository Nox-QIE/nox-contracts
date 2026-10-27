# ADR-005: Credits formula

- Status: accepted
- Date: 2026-10-26

## Context

Nox Credits are non-transferable status points (rank, leaderboard, badges). The design asks for credits from participation, winning, playing a role well and streaks (F08-S04), with versioned parameters (F08-D04). Credits must never look like a prize for luck or for paying (Indonesian gambling law), and anyone should be able to check why a player got what they got.

## Decision

`revealAndFinalize` mints each player's credits from data that is on chain by the end of that transaction. Nothing comes from the server's say-so:

| Part | Default | Rule |
|---|---|---|
| Participation | 10 | Every player of a finalized game |
| Win | 20 | Every player on the winning team |
| Seer hit | 5 | Per revealed inspection whose target's revealed role is werewolf. Extended roles: also per witch poison or hunter shot (actions 5, 6) whose target is a werewolf |
| Doctor save | 5 | Per revealed protection of a player a werewolf chose (revealed kill) the same night. Counted even when several wolves split their choice: the engine's tie-break uses seat order, which the chain cannot see, so the rule is "blocked a wolf's choice". Extended roles: a witch heal (action 4) of a wolf's choice counts the same |
| Accurate vote | 2 | Per day vote (`voteOf`) a **village** player cast for a revealed werewolf. Wolves get no vote bonus: voting out a fellow wolf is strategy, not a find |
| Streak | 2 per step, max 5 steps | Consecutive UTC days with a finalized game (`streakOf`). Several games on one day count once; the first day earns nothing; a missed day starts over |

- Parameters live in `rewards` (one struct). `setRewards` (admin) applies to future games only, bumps `version` (the caller's value is ignored), and bounds every value (≤ 1,000 each, cap ≤ 30), so a setting can never make a finalize overflow and revert.
- Each grant emits `RewardGranted(gameId, player, version, base, roleBonus, voteBonus, streakBonus)` next to `CreditsMinted`, so a dashboard can show the breakdown and anyone can recompute it.
- Disputed or cancelled games mint nothing and do not touch streaks.
- **Scam Shield bonus (27 Oct 2026, F10-S05).** A game created with `createGameWithMode(gameId, configHash, MODE_SCAM_SHIELD)` has a public mode (`modeOf`, `GameModeSet`). When the village wins it, every village player also earns `scamShieldBonus` (default 5; admin `setScamShieldBonus`, ≤ 1,000, `0` turns it off). The bonus is emitted as its own `ScamShieldBonus(gameId, player, amount)` event, so `RewardGranted` keeps its shape. The operator chooses the mode at creation, as it chooses the rules; the mode is on chain before anyone joins.

## Consequences

- A 12-player finalize with 25 night reveals costs about 1.65M gas (was 1.11M). The backend's gas floor for `revealAndFinalize` rises to match. QIE's block gas limit is about 4.29B, so this is not a constraint.
- `setCredits`, `participationCredits`, `winCredits` and `CreditsConfigured` are replaced by `setRewards`, `rewards` and `RewardsConfigured`. Nothing off chain used them.
- Multi-account farming of streaks earns only status points. Ranked play with QIE ID (F02) is the planned defence.
