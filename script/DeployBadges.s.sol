// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NoxBadges} from "../src/NoxBadges.sol";

/// @notice Deploys NoxBadges next to an existing deployment and, when the broadcaster is also the
///         admin, defines the Scam Spotter badge.
/// Usage:
///   NOX_ADMIN=0x... NOX_OPERATOR=0x... forge script script/DeployBadges.s.sol --rpc-url qie_testnet --account nox-deployer --broadcast --slow
contract DeployBadges is Script {
    bytes32 public constant SCAM_SPOTTER = keccak256("SCAM_SPOTTER");

    function run() external returns (NoxBadges badges) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("NOX_ADMIN", deployer);
        address operator = vm.envOr("NOX_OPERATOR", admin);
        badges = deploy(deployer, admin, operator);
        vm.stopBroadcast();
        console.log("NoxBadges:", address(badges));
        if (admin != deployer) {
            console.log(
                "Define the badge with the admin wallet: defineBadge(keccak256(\"SCAM_SPOTTER\"), \"Scam Spotter\", true)"
            );
        }
    }

    /// @dev Without env or broadcast, so tests can call it directly.
    function deploy(address deployer, address admin, address operator) public returns (NoxBadges badges) {
        badges = new NoxBadges(admin, operator);
        if (admin == deployer) badges.defineBadge(SCAM_SPOTTER, "Scam Spotter", true);
    }
}
