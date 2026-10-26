# ADR-003: Payments and agent revenue share

- Status: accepted
- Date: 2026-10-25

## Context

Nox earns from Host Pass / Season Pass and Game Night bookings, and shares revenue with owners of third-party AI Game Masters (Agent Marketplace, F18): owner 30%, Nox 70%, changeable. Players never receive money and nobody stakes on a result (Indonesian gambling law; Polymarket was blocked as gambling in May 2026). Indonesian buyers pay in rupiah through a licensed PSP; global buyers pay in QIE or QUSDC.

## Decision

1. **`NoxAgentRegistry`** stores each agent's owner, mode (hosted persona / external endpoint), status and a hash of its off-chain persona or endpoint. Only the operator registers after moderation and changes status; only the admin changes revenue shares. `defaultShareBps = 3000`, with an optional per-agent override, capped at 10,000.
2. **`NoxPayments`** accepts native QIE (`address(0)`) and allow-listed ERC-20s. Passes extend an expiry per buyer and pass type (renewals stack). Rupiah purchases are recorded with a receipt hash and move no funds. `buyPassFor(holder, …)` lets anyone pay for another wallet's pass (26 Oct 2026). A host pays from their own wallet for the game wallet Nox derives for them, so Nox never has to spend a player's funds; it emits `PassPaidBy(payer, holder, passType)` next to `PassPurchased(holder, …)`.
3. **Game Night with an agent** credits the owner's share at payment time (`amount * shareBps / 10000`, rounded down; the remainder goes to the treasury, so nothing is lost or created).
4. **Pass revenue to agents** is settled monthly by `allocateAgentPool(period, token, agentIds, amounts, usageRoot)`: amounts are computed off-chain (pass revenue x share, pro-rata to valid games per agent), capped by the treasury, once per (period, token), and `usageRoot` commits to the usage data for audit.
5. **Pull payments.** Owners call `withdraw(token)`; the admin calls `withdrawTreasury`. Nothing is pushed to arbitrary addresses during a purchase; all value-moving functions are `nonReentrant`.
6. Share changes apply to future payments and settlements only; credited balances are never touched.

## Consequences

- The operator is trusted to compute pool amounts correctly; the `usageRoot` and public events make that checkable, and the treasury cap bounds any error.
- Fiat Game Night shares for agent owners are paid off-chain (PSP disbursement) and only recorded on-chain.
