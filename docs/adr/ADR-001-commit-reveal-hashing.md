# ADR-001: Commit-reveal hashing and on-chain scope

- Status: accepted
- Date: 2026-10-25

## Context

Nox needs players to trust that the server (and its AI Game Master) did not change roles or night actions mid-game. Game rules are a deterministic TypeScript engine (`@nox/shared/engine`); the chain is QIE (EVM, chain 1990 mainnet / 1983 testnet). The same hashes must be produced by the server, checked by the contract, and re-checked in a browser.

## Decision

1. **One spec, three runtimes.** Hashing is defined once in `@nox/shared/crypto-spec` (v1) and mirrored by `NoxGame.roleLeaf` / `NoxGame.actionHash`. `test/vectors/crypto-spec-v1.json` is copied from nox-shared; Foundry tests must reproduce every leaf, proof and action hash in it.
2. **Role leaf** = `keccak256(bytes.concat(keccak256(abi.encode(gameId, player, role, salt))))`. `abi.encode` (not packed) avoids ambiguous concatenation; the double hash (OpenZeppelin StandardMerkleTree style) stops a 64-byte inner node from being passed off as a leaf. Roles are `uint8` codes (villager 1, werewolf 2, seer 3, doctor 4; extended set: hunter 5, witch 6). Night actions: kill 1, inspect 2, protect 3; extended: heal 4, poison 5, shoot 6 (the hunter's last shot, committed in the round they die). Codes are only added, never reused, so the hash formats stay v1.
3. **Merkle tree** uses sorted-pair keccak256 so proofs verify with OpenZeppelin `MerkleProof`. The root is committed by the operator before any role is sent; each player gets their own leaf, salt and proof by DM and can check inclusion themselves.
4. **Night actions** are committed from the player's own wallet as `keccak256(abi.encode(gameId, round, player, action, target, nonce))`. Any player may commit, so a commitment does not reveal who holds a night role.
5. **On-chain scope is integrity, not rules.** The contract records commitments, votes and per-round result hashes, and at the end checks that every role and every committed night action reveals correctly (all or nothing). It does not replay the game; anyone can replay it off-chain from the revealed data and events. This keeps gas low (finalize ≈ 0.4M gas for 5 players including credit mints).
6. **Credits** (`NoxCredits`) are a non-transferable ERC-20 with 0 decimals, minted at finalize (participation + win bonus, team derived from the revealed role). No transfer, approve or burn, so they are not a tradable asset and not a prize.
7. **EVM version `shanghai`.** On 25 Oct 2026 the QIE mainnet RPC executed `PUSH0` but rejected `MCOPY` (`opcode 0x5e not defined`), so Cancun opcodes are unavailable.

## Consequences

- Changing any hashing rule is a breaking change: bump `SPEC_VERSION`, regenerate vectors in nox-shared, copy them here, and redeploy.
- The operator remains trusted for liveness (it must finalize or cancel). A timeout path that lets players force a cancel can be added later.
- Votes are public by design (day votes are public in the game too).
