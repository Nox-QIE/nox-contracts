// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";

/// @notice Deploys NoxCredits + NoxGame and lets the game mint credits.
/// Usage (key from a secure keystore, never on the command line in shared terminals):
///   NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/Deploy.s.sol \
///     --rpc-url qie_testnet --account nox-deployer --broadcast
/// NOX_ADMIN defaults to the deployer; NOX_OPERATOR defaults to NOX_ADMIN.
contract Deploy is Script {
    function run() external returns (NoxCredits credits, NoxGame game) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("NOX_ADMIN", deployer);
        address operator = vm.envOr("NOX_OPERATOR", admin);

        // The deployer is temporary admin of NoxCredits so it can grant the minter role, then hands over.
        credits = new NoxCredits(deployer);
        game = new NoxGame(admin, operator, credits);
        credits.grantRole(credits.MINTER_ROLE(), address(game));
        if (admin != deployer) {
            credits.grantRole(credits.DEFAULT_ADMIN_ROLE(), admin);
            credits.renounceRole(credits.DEFAULT_ADMIN_ROLE(), deployer);
        }
        vm.stopBroadcast();

        console.log("NoxCredits:", address(credits));
        console.log("NoxGame:   ", address(game));
        console.log("admin:     ", admin);
        console.log("operator:  ", operator);
    }
}
