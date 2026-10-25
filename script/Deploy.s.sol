// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NoxAgentRegistry} from "../src/NoxAgentRegistry.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";
import {NoxPayments} from "../src/NoxPayments.sol";

/// @notice Deploys NoxCredits + NoxGame (game mints credits), NoxAgentRegistry and NoxPayments.
/// Usage (key from a secure keystore, never on the command line in shared terminals):
///   NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/Deploy.s.sol \
///     --rpc-url qie_testnet --account nox-deployer --broadcast
/// NOX_ADMIN defaults to the deployer; NOX_OPERATOR defaults to NOX_ADMIN.
contract Deploy is Script {
    struct Deployment {
        NoxCredits credits;
        NoxGame game;
        NoxAgentRegistry registry;
        NoxPayments payments;
    }

    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("NOX_ADMIN", deployer);
        address operator = vm.envOr("NOX_OPERATOR", admin);

        // The deployer is temporary admin of NoxCredits so it can grant the minter role, then hands over.
        d.credits = new NoxCredits(deployer);
        d.game = new NoxGame(admin, operator, d.credits);
        d.credits.grantRole(d.credits.MINTER_ROLE(), address(d.game));
        if (admin != deployer) {
            d.credits.grantRole(d.credits.DEFAULT_ADMIN_ROLE(), admin);
            d.credits.renounceRole(d.credits.DEFAULT_ADMIN_ROLE(), deployer);
        }
        d.registry = new NoxAgentRegistry(admin, operator);
        d.payments = new NoxPayments(admin, operator, d.registry);
        vm.stopBroadcast();

        console.log("NoxCredits:      ", address(d.credits));
        console.log("NoxGame:         ", address(d.game));
        console.log("NoxAgentRegistry:", address(d.registry));
        console.log("NoxPayments:     ", address(d.payments));
        console.log("admin:     ", admin);
        console.log("operator:  ", operator);
    }
}
