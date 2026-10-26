// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";

/// @notice Replaces only NoxGame (e.g. to add game modes) next to an existing NoxCredits, so credits,
///         the registry, payments and badges keep their addresses and history. When the broadcaster
///         is the NoxCredits admin, it grants the new game the minter role in the same run. The old
///         game keeps its role, so its finished games stay as they are.
/// Usage:
///   NOX_CREDITS=0x... NOX_ADMIN=0x... NOX_OPERATOR=0x... \
///   forge script script/DeployGame.s.sol --rpc-url qie_testnet --account nox-deployer --broadcast --slow
contract DeployGame is Script {
    function run() external returns (NoxGame game) {
        NoxCredits credits = NoxCredits(vm.envAddress("NOX_CREDITS"));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("NOX_ADMIN", deployer);
        address operator = vm.envOr("NOX_OPERATOR", admin);
        game = deploy(credits, deployer, admin, operator);
        vm.stopBroadcast();

        console.log("NoxGame:   ", address(game));
        console.log("NoxCredits:", address(credits));
        if (!credits.hasRole(credits.MINTER_ROLE(), address(game))) {
            console.log("Grant the minter role with the NoxCredits admin: grantRole(MINTER_ROLE, game)");
        }
    }

    /// @dev The deployment itself, without env or broadcast (tests call it directly).
    function deploy(NoxCredits credits, address deployer, address admin, address operator)
        public
        returns (NoxGame game)
    {
        require(address(credits).code.length > 0, "NOX_CREDITS has no code");
        game = new NoxGame(admin, operator, credits);
        if (credits.hasRole(credits.DEFAULT_ADMIN_ROLE(), deployer)) {
            credits.grantRole(credits.MINTER_ROLE(), address(game));
        }
    }
}
