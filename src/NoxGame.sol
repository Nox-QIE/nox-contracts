// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {NoxCredits} from "./NoxCredits.sol";

/// @title NoxGame
/// @notice Commit-reveal record of a Nox (Werewolf) game. The operator commits a Merkle root of all
///         secret roles before roles are sent out; players join, commit night actions and vote from
///         their own wallets; at the end the operator reveals every role and night action and this
///         contract checks each one against what was committed. Game rules run off-chain in the
///         open-source engine; anyone can replay them from the revealed data and the logged events.
///         A game whose reveal does not match its commitments, or that is never revealed, ends as
///         Disputed instead of quietly disappearing: the operator reports its own failed reveal, and
///         anyone can flag a running game that has been silent longer than `revealTimeout`.
/// @dev Hashing follows @nox/shared crypto-spec v1 (see docs/adr/ADR-001-commit-reveal-hashing.md).
contract NoxGame is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint8 public constant MIN_PLAYERS = 5;
    uint8 public constant MAX_PLAYERS = 12;

    // crypto-spec v1 codes
    uint8 internal constant ROLE_VILLAGER = 1;
    uint8 internal constant ROLE_WEREWOLF = 2;
    uint8 internal constant ROLE_SEER = 3;
    uint8 internal constant ROLE_DOCTOR = 4;
    uint8 internal constant ACTION_KILL = 1;
    uint8 internal constant ACTION_INSPECT = 2;
    uint8 internal constant ACTION_PROTECT = 3;
    uint8 public constant TEAM_VILLAGE = 1;
    uint8 public constant TEAM_WOLVES = 2;

    enum Status {
        None,
        Lobby,
        Running,
        Finalized,
        Cancelled,
        Disputed
    }

    // GameDisputed reasons
    uint8 public constant DISPUTE_REVEAL_MISMATCH = 1;
    uint8 public constant DISPUTE_REVEAL_TIMEOUT = 2;

    struct Game {
        Status status;
        uint8 playerCount;
        uint16 round;
        uint8 winner;
        uint16 nightCommits;
        /// @dev Last time the game moved (roles committed, a night action, a vote, a round). Packed
        ///      into the first slot, so keeping it costs little.
        uint64 lastActivity;
        bytes32 configHash;
        bytes32 rolesRoot;
        bytes32 resultHash;
    }

    struct RoleReveal {
        address player;
        uint8 role;
        bytes32 salt;
        bytes32[] proof;
    }

    /// @notice Credits formula (F08-S04). Every part is computed here from revealed, on-chain data,
    ///         so anyone can recompute a player's credits. Credits are status points only: they
    ///         reward playing, winning, playing a role well and coming back, never luck or payment.
    struct Rewards {
        uint16 participation; // every player of a finalized game
        uint16 win; // every player on the winning team
        uint16 seerHit; // per seer inspection that found a werewolf
        uint16 doctorSave; // per doctor protection of a player a werewolf chose that night
        uint16 accurateVote; // per day vote a village player cast for a werewolf
        uint16 streakStep; // per consecutive UTC day with a finalized game, after the first
        uint16 streakCap; // most streak steps that count
        uint16 version; // bumped on every change, recorded with each grant
    }

    struct Streak {
        uint32 lastDay; // UTC day number of the last finalized game
        uint16 days_; // consecutive days up to lastDay
    }

    struct NightReveal {
        uint16 round;
        address player;
        uint8 action;
        address target;
        bytes32 nonce;
    }

    NoxCredits public immutable credits;
    Rewards public rewards = Rewards({
        participation: 10, win: 20, seerHit: 5, doctorSave: 5, accurateVote: 2, streakStep: 2, streakCap: 5, version: 1
    });
    /// @notice How long a running game may stay silent before anyone can mark it Disputed.
    uint64 public revealTimeout = 6 hours;

    mapping(bytes32 gameId => Game) public games;
    mapping(bytes32 gameId => address[]) internal _players;
    mapping(bytes32 gameId => mapping(address => bool)) public isPlayer;
    mapping(bytes32 gameId => mapping(uint16 round => mapping(address player => bytes32))) public nightCommitOf;
    mapping(bytes32 gameId => mapping(uint16 round => mapping(address voter => address))) public voteOf;
    mapping(bytes32 gameId => mapping(uint16 round => bytes32)) public roundResultOf;
    mapping(bytes32 gameId => mapping(address player => uint8)) public revealedRoleOf;
    mapping(address player => Streak) public streakOf;

    event GameCreated(bytes32 indexed gameId, bytes32 configHash);
    event PlayerJoined(bytes32 indexed gameId, address indexed player);
    event RolesCommitted(bytes32 indexed gameId, bytes32 rolesRoot, uint8 playerCount);
    event NightActionCommitted(
        bytes32 indexed gameId, uint16 indexed round, address indexed player, bytes32 actionHash
    );
    event VoteCast(bytes32 indexed gameId, uint16 indexed round, address indexed voter, address target);
    event RoundRecorded(bytes32 indexed gameId, uint16 indexed round, bytes32 resultHash);
    event RoleRevealed(bytes32 indexed gameId, address indexed player, uint8 role);
    event NightActionRevealed(
        bytes32 indexed gameId, uint16 indexed round, address indexed player, uint8 action, address target
    );
    event GameFinalized(bytes32 indexed gameId, bytes32 resultHash, uint8 winner);
    event GameCancelled(bytes32 indexed gameId, string reason);
    event GameDisputed(bytes32 indexed gameId, uint8 reason, string detail);
    event RevealTimeoutConfigured(uint64 seconds_);
    event RewardsConfigured(uint16 indexed version, Rewards rewards);
    /// @dev base = participation (+ win); total minted = base + roleBonus + voteBonus + streakBonus.
    event RewardGranted(
        bytes32 indexed gameId,
        address indexed player,
        uint16 version,
        uint16 base,
        uint16 roleBonus,
        uint16 voteBonus,
        uint16 streakBonus
    );

    error WrongStatus(Status expected, Status actual);
    error AlreadyExists();
    error AlreadyJoined();
    error GameFull();
    error NotEnoughPlayers();
    error NotAPlayer(address account);
    error WrongRound(uint16 expected, uint16 actual);
    error AlreadyCommitted();
    error AlreadyVoted();
    error BadReveal(address player);
    error BadNightReveal(address player, uint16 round);
    error RevealCountMismatch();
    error InvalidCode();
    error NotTimedOut(uint64 deadline);

    constructor(address admin, address operator, NoxCredits credits_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        credits = credits_;
    }

    // ---------------------------------------------------------------- lobby

    function createGame(bytes32 gameId, bytes32 configHash) external onlyRole(OPERATOR_ROLE) {
        if (games[gameId].status != Status.None) revert AlreadyExists();
        games[gameId].status = Status.Lobby;
        games[gameId].configHash = configHash;
        emit GameCreated(gameId, configHash);
    }

    /// @notice Called by each player from their own wallet.
    function joinGame(bytes32 gameId) external {
        Game storage g = _expect(gameId, Status.Lobby);
        if (isPlayer[gameId][msg.sender]) revert AlreadyJoined();
        if (g.playerCount >= MAX_PLAYERS) revert GameFull();
        isPlayer[gameId][msg.sender] = true;
        _players[gameId].push(msg.sender);
        g.playerCount++;
        emit PlayerJoined(gameId, msg.sender);
    }

    /// @notice Locks the secret roles before anyone receives theirs. Starts round 1.
    function commitRoles(bytes32 gameId, bytes32 rolesRoot) external onlyRole(OPERATOR_ROLE) {
        Game storage g = _expect(gameId, Status.Lobby);
        if (g.playerCount < MIN_PLAYERS) revert NotEnoughPlayers();
        g.rolesRoot = rolesRoot;
        g.round = 1;
        g.status = Status.Running;
        g.lastActivity = uint64(block.timestamp);
        emit RolesCommitted(gameId, rolesRoot, g.playerCount);
    }

    // ---------------------------------------------------------------- rounds

    /// @notice Hash of a secret night action, sent by the player's own wallet. Any player may commit,
    ///         so committing does not reveal who holds a night role.
    function commitNightAction(bytes32 gameId, uint16 round, bytes32 actionHash_) external {
        Game storage g = _expectRound(gameId, round);
        _expectPlayer(gameId, msg.sender);
        if (nightCommitOf[gameId][round][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        nightCommitOf[gameId][round][msg.sender] = actionHash_;
        g.nightCommits++;
        g.lastActivity = uint64(block.timestamp);
        emit NightActionCommitted(gameId, round, msg.sender, actionHash_);
    }

    /// @notice Public day vote, one per player per round, from the player's own wallet.
    function castVote(bytes32 gameId, uint16 round, address target) external {
        Game storage g = _expectRound(gameId, round);
        _expectPlayer(gameId, msg.sender);
        _expectPlayer(gameId, target);
        if (voteOf[gameId][round][msg.sender] != address(0)) revert AlreadyVoted();
        voteOf[gameId][round][msg.sender] = target;
        g.lastActivity = uint64(block.timestamp);
        emit VoteCast(gameId, round, msg.sender, target);
    }

    /// @notice Closes a round with the hash of its public result and moves to the next round.
    function recordRound(bytes32 gameId, uint16 round, bytes32 resultHash_) external onlyRole(OPERATOR_ROLE) {
        Game storage g = _expectRound(gameId, round);
        roundResultOf[gameId][round] = resultHash_;
        g.round = round + 1;
        g.lastActivity = uint64(block.timestamp);
        emit RoundRecorded(gameId, round, resultHash_);
    }

    // ---------------------------------------------------------------- end

    /// @notice Reveals every role and every committed night action; reverts unless all match their
    ///         commitments. Then mints each player's credits by the `rewards` formula.
    function revealAndFinalize(
        bytes32 gameId,
        RoleReveal[] calldata roles,
        NightReveal[] calldata nights,
        bytes32 resultHash_,
        uint8 winner
    ) external onlyRole(OPERATOR_ROLE) {
        Game storage g = _expect(gameId, Status.Running);
        if (winner != TEAM_VILLAGE && winner != TEAM_WOLVES) revert InvalidCode();
        if (roles.length != g.playerCount || nights.length != g.nightCommits) revert RevealCountMismatch();

        for (uint256 i; i < roles.length; ++i) {
            RoleReveal calldata r = roles[i];
            _expectPlayer(gameId, r.player);
            if (r.role < ROLE_VILLAGER || r.role > ROLE_DOCTOR) revert InvalidCode();
            // A second reveal for the same player would overwrite; reject duplicates.
            if (revealedRoleOf[gameId][r.player] != 0) revert BadReveal(r.player);
            if (!MerkleProof.verifyCalldata(r.proof, g.rolesRoot, roleLeaf(gameId, r.player, r.role, r.salt))) {
                revert BadReveal(r.player);
            }
            revealedRoleOf[gameId][r.player] = r.role;
            emit RoleRevealed(gameId, r.player, r.role);
        }

        for (uint256 i; i < nights.length; ++i) {
            NightReveal calldata n = nights[i];
            if (n.action == 0 || n.action > ACTION_PROTECT) revert InvalidCode();
            bytes32 committed = nightCommitOf[gameId][n.round][n.player];
            if (
                committed == bytes32(0)
                    || committed != actionHash(gameId, n.round, n.player, n.action, n.target, n.nonce)
            ) {
                revert BadNightReveal(n.player, n.round);
            }
            // Clear so the same commitment cannot be counted twice.
            delete nightCommitOf[gameId][n.round][n.player];
            emit NightActionRevealed(gameId, n.round, n.player, n.action, n.target);
        }

        g.status = Status.Finalized;
        g.resultHash = resultHash_;
        g.winner = winner;
        emit GameFinalized(gameId, resultHash_, winner);

        Rewards memory rw = rewards;
        for (uint256 i; i < roles.length; ++i) {
            _grant(gameId, roles[i], winner, g.round, nights, rw);
        }
    }

    function cancelGame(bytes32 gameId, string calldata reason) external onlyRole(OPERATOR_ROLE) {
        Game storage g = games[gameId];
        if (g.status != Status.Lobby && g.status != Status.Running) revert WrongStatus(Status.Running, g.status);
        g.status = Status.Cancelled;
        emit GameCancelled(gameId, reason);
    }

    /// @notice The operator reports that its own reveal does not match what it committed (a server bug
    ///         or tampering). The game ends with no credits, and the record stays public.
    function reportDispute(bytes32 gameId, string calldata detail) external onlyRole(OPERATOR_ROLE) {
        _dispute(_expect(gameId, Status.Running), gameId, DISPUTE_REVEAL_MISMATCH, detail);
    }

    /// @notice Anyone may call this once a running game has been silent longer than `revealTimeout`:
    ///         the operator can neither hide a game nor sit on its reveal.
    function claimRevealTimeout(bytes32 gameId) external {
        Game storage g = _expect(gameId, Status.Running);
        uint64 deadline = g.lastActivity + revealTimeout;
        if (block.timestamp <= deadline) revert NotTimedOut(deadline);
        _dispute(g, gameId, DISPUTE_REVEAL_TIMEOUT, "no reveal before the deadline");
    }

    function setRevealTimeout(uint64 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seconds_ < 10 minutes) revert InvalidCode();
        revealTimeout = seconds_;
        emit RevealTimeoutConfigured(seconds_);
    }

    /// @notice New formula for future games; `version` is set here, the caller's value is ignored.
    function setRewards(Rewards calldata r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Bounds keep every sum far below uint16 overflow, so a bad setting can never block a finalize.
        if (
            r.participation > 1000 || r.win > 1000 || r.seerHit > 1000 || r.doctorSave > 1000 || r.accurateVote > 1000
                || r.streakStep > 1000 || r.streakCap > 30
        ) revert InvalidCode();
        Rewards memory next = r;
        next.version = rewards.version + 1;
        rewards = next;
        emit RewardsConfigured(next.version, next);
    }

    // ---------------------------------------------------------------- views & hashing (crypto-spec v1)

    function playersOf(bytes32 gameId) external view returns (address[] memory) {
        return _players[gameId];
    }

    /// @notice keccak256(bytes.concat(keccak256(abi.encode(gameId, player, role, salt))))
    function roleLeaf(bytes32 gameId, address player, uint8 role, bytes32 salt) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(gameId, player, role, salt))));
    }

    /// @notice keccak256(abi.encode(gameId, round, player, action, target, nonce))
    function actionHash(bytes32 gameId, uint16 round, address player, uint8 action, address target, bytes32 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(gameId, round, player, action, target, nonce));
    }

    // ---------------------------------------------------------------- internal

    function _expect(bytes32 gameId, Status s) internal view returns (Game storage g) {
        g = games[gameId];
        if (g.status != s) revert WrongStatus(s, g.status);
    }

    function _expectRound(bytes32 gameId, uint16 round) internal view returns (Game storage g) {
        g = _expect(gameId, Status.Running);
        if (round != g.round) revert WrongRound(g.round, round);
    }

    struct Grant {
        uint16 base;
        uint16 roleBonus;
        uint16 voteBonus;
        uint16 streakBonus;
    }

    function _grant(
        bytes32 gameId,
        RoleReveal calldata r,
        uint8 winner,
        uint16 lastRound,
        NightReveal[] calldata nights,
        Rewards memory rw
    ) internal {
        Grant memory x;
        uint8 team = r.role == ROLE_WEREWOLF ? TEAM_WOLVES : TEAM_VILLAGE;
        x.base = rw.participation + (team == winner ? rw.win : 0);
        x.roleBonus = _roleBonus(gameId, r.player, r.role, nights, rw);
        x.voteBonus = r.role == ROLE_WEREWOLF ? 0 : _voteBonus(gameId, r.player, lastRound, rw);
        x.streakBonus = _streakBonus(r.player, rw);
        emit RewardGranted(gameId, r.player, rw.version, x.base, x.roleBonus, x.voteBonus, x.streakBonus);
        uint256 total = uint256(x.base) + x.roleBonus + x.voteBonus + x.streakBonus;
        if (total > 0) credits.mint(r.player, total, gameId);
    }

    /// @dev Seer: inspections that found a werewolf. Doctor: protections of a player a werewolf
    ///      chose the same night (counted even when several wolves split their choice).
    function _roleBonus(bytes32 gameId, address player, uint8 role, NightReveal[] calldata nights, Rewards memory rw)
        internal
        view
        returns (uint16 bonus)
    {
        if (role != ROLE_SEER && role != ROLE_DOCTOR) return 0;
        for (uint256 i; i < nights.length; ++i) {
            NightReveal calldata n = nights[i];
            if (n.player != player) continue;
            if (role == ROLE_SEER && n.action == ACTION_INSPECT && revealedRoleOf[gameId][n.target] == ROLE_WEREWOLF) {
                bonus += rw.seerHit;
            } else if (
                role == ROLE_DOCTOR && n.action == ACTION_PROTECT && _wolfChose(gameId, nights, n.round, n.target)
            ) {
                bonus += rw.doctorSave;
            }
        }
    }

    function _wolfChose(bytes32 gameId, NightReveal[] calldata nights, uint16 round, address target)
        internal
        view
        returns (bool)
    {
        for (uint256 j; j < nights.length; ++j) {
            NightReveal calldata m = nights[j];
            if (
                m.round == round && m.action == ACTION_KILL && m.target == target
                    && revealedRoleOf[gameId][m.player] == ROLE_WEREWOLF
            ) return true;
        }
        return false;
    }

    /// @dev Day votes a village player cast for someone whose revealed role is werewolf (a wolf voting
    ///      out a fellow wolf is strategy, not a find, so wolves get no vote bonus).
    function _voteBonus(bytes32 gameId, address player, uint16 lastRound, Rewards memory rw)
        internal
        view
        returns (uint16 bonus)
    {
        for (uint16 r = 1; r <= lastRound; ++r) {
            address target = voteOf[gameId][r][player];
            if (target != address(0) && revealedRoleOf[gameId][target] == ROLE_WEREWOLF) bonus += rw.accurateVote;
        }
    }

    /// @dev Consecutive UTC days with a finalized game. Several games on one day count once; the
    ///      first day earns nothing, each following day one step, up to streakCap steps.
    function _streakBonus(address player, Rewards memory rw) internal returns (uint16) {
        uint32 today = uint32(block.timestamp / 1 days);
        Streak storage s = streakOf[player];
        if (s.days_ == 0 || s.lastDay != today) {
            s.days_ = s.lastDay + 1 == today ? s.days_ + 1 : 1;
            s.lastDay = today;
        }
        uint16 steps = s.days_ - 1;
        if (steps > rw.streakCap) steps = rw.streakCap;
        return steps * rw.streakStep;
    }

    function _dispute(Game storage g, bytes32 gameId, uint8 reason, string memory detail) internal {
        g.status = Status.Disputed;
        emit GameDisputed(gameId, reason, detail);
    }

    function _expectPlayer(bytes32 gameId, address account) internal view {
        if (!isPlayer[gameId][account]) revert NotAPlayer(account);
    }
}
