// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NoxCredits
/// @notice Status points earned by playing Nox. Non-transferable: they can only be minted (by the game
///         or an operator) and never moved, approved, sold or redeemed. They count for ranks,
///         leaderboards and badges only.
contract NoxCredits is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error NonTransferable();

    event CreditsMinted(address indexed to, uint256 amount, bytes32 indexed gameId);

    constructor(address admin) ERC20("Nox Credits", "NOXC") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Credits are whole points.
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function mint(address to, uint256 amount, bytes32 gameId) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
        emit CreditsMinted(to, amount, gameId);
    }

    /// @dev Only minting (from == 0) passes; every transfer and burn reverts.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }
}
