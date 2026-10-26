// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title NoxBadges
/// @notice Non-transferable achievement badges (F10-S05, F08-D02), e.g. "Scam Spotter" for every
///         player on the side that exposed the scammers in a Scam Shield game. A badge is a count per
///         wallet plus an event that names the game, so anyone can check the game's recorded result
///         on NoxGame. Nothing can be moved, sold or redeemed: badges are status, not value.
contract NoxBadges is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct Badge {
        string name;
        bool active;
    }

    mapping(bytes32 badgeId => Badge) public badges;
    mapping(address account => mapping(bytes32 badgeId => uint32)) public countOf;
    mapping(bytes32 badgeId => mapping(bytes32 gameId => mapping(address account => bool))) public awardedFor;

    event BadgeDefined(bytes32 indexed badgeId, string name, bool active);
    event BadgeAwarded(address indexed account, bytes32 indexed badgeId, bytes32 indexed gameId, uint32 count);

    error UnknownBadge(bytes32 badgeId);
    error InvalidInput();

    constructor(address admin, address operator) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    /// @notice Create, rename or retire a badge.
    function defineBadge(bytes32 badgeId, string calldata name, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (badgeId == bytes32(0) || bytes(name).length == 0 || bytes(name).length > 64) revert InvalidInput();
        badges[badgeId] = Badge(name, active);
        emit BadgeDefined(badgeId, name, active);
    }

    /// @notice Award one badge to several players for one game. A player already awarded this badge
    ///         for this game is skipped, so a retried transaction cannot count twice.
    function award(bytes32 badgeId, bytes32 gameId, address[] calldata accounts) external onlyRole(OPERATOR_ROLE) {
        if (!badges[badgeId].active) revert UnknownBadge(badgeId);
        if (gameId == bytes32(0) || accounts.length == 0 || accounts.length > 12) revert InvalidInput();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            if (a == address(0)) revert InvalidInput();
            if (awardedFor[badgeId][gameId][a]) continue;
            awardedFor[badgeId][gameId][a] = true;
            uint32 n = ++countOf[a][badgeId];
            emit BadgeAwarded(a, badgeId, gameId, n);
        }
    }
}
