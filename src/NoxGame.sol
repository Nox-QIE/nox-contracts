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
/// @dev Hashing follows @nox/shared crypto-spec v1 (see docs/adr/ADR-001-commit-reveal-hashing.md).
contract NoxGame is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint8 public constant MIN_PLAYERS = 5;
    uint8 public constant MAX_PLAYERS = 12;

    // crypto-spec v1 codes
    uint8 internal constant ROLE_VILLAGER = 1;
    uint8 internal constant ROLE_WEREWOLF = 2;
    uint8 internal constant ROLE_DOCTOR = 4;
    uint8 internal constant ACTION_PROTECT = 3;
    uint8 public constant TEAM_VILLAGE = 1;
    uint8 public constant TEAM_WOLVES = 2;

    enum Status {
        None,
        Lobby,
        Running,
        Finalized,
        Cancelled
    }

    struct Game {
        Status status;
        uint8 playerCount;
        uint16 round;
        uint8 winner;
        uint16 nightCommits;
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

    struct NightReveal {
        uint16 round;
        address player;
        uint8 action;
        address target;
        bytes32 nonce;
    }

    NoxCredits public immutable credits;
    uint256 public participationCredits = 10;
    uint256 public winCredits = 20;

    mapping(bytes32 gameId => Game) public games;
    mapping(bytes32 gameId => address[]) internal _players;
    mapping(bytes32 gameId => mapping(address => bool)) public isPlayer;
    mapping(bytes32 gameId => mapping(uint16 round => mapping(address player => bytes32))) public nightCommitOf;
    mapping(bytes32 gameId => mapping(uint16 round => mapping(address voter => address))) public voteOf;
    mapping(bytes32 gameId => mapping(uint16 round => bytes32)) public roundResultOf;
    mapping(bytes32 gameId => mapping(address player => uint8)) public revealedRoleOf;

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
    event CreditsConfigured(uint256 participation, uint256 win);

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
        emit NightActionCommitted(gameId, round, msg.sender, actionHash_);
    }

    /// @notice Public day vote, one per player per round, from the player's own wallet.
    function castVote(bytes32 gameId, uint16 round, address target) external {
        _expectRound(gameId, round);
        _expectPlayer(gameId, msg.sender);
        _expectPlayer(gameId, target);
        if (voteOf[gameId][round][msg.sender] != address(0)) revert AlreadyVoted();
        voteOf[gameId][round][msg.sender] = target;
        emit VoteCast(gameId, round, msg.sender, target);
    }

    /// @notice Closes a round with the hash of its public result and moves to the next round.
    function recordRound(bytes32 gameId, uint16 round, bytes32 resultHash_) external onlyRole(OPERATOR_ROLE) {
        Game storage g = _expectRound(gameId, round);
        roundResultOf[gameId][round] = resultHash_;
        g.round = round + 1;
        emit RoundRecorded(gameId, round, resultHash_);
    }

    // ---------------------------------------------------------------- end

    /// @notice Reveals every role and every committed night action; reverts unless all match their
    ///         commitments. Mints participation credits to everyone and win credits to the winning team.
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

        for (uint256 i; i < roles.length; ++i) {
            uint8 team = roles[i].role == ROLE_WEREWOLF ? TEAM_WOLVES : TEAM_VILLAGE;
            uint256 amount = participationCredits + (team == winner ? winCredits : 0);
            if (amount > 0) credits.mint(roles[i].player, amount, gameId);
        }
    }

    function cancelGame(bytes32 gameId, string calldata reason) external onlyRole(OPERATOR_ROLE) {
        Game storage g = games[gameId];
        if (g.status != Status.Lobby && g.status != Status.Running) revert WrongStatus(Status.Running, g.status);
        g.status = Status.Cancelled;
        emit GameCancelled(gameId, reason);
    }

    function setCredits(uint256 participation, uint256 win) external onlyRole(DEFAULT_ADMIN_ROLE) {
        participationCredits = participation;
        winCredits = win;
        emit CreditsConfigured(participation, win);
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

    function _expectPlayer(bytes32 gameId, address account) internal view {
        if (!isPlayer[gameId][account]) revert NotAPlayer(account);
    }
}
