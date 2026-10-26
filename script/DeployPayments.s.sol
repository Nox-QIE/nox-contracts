// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NoxAgentRegistry} from "../src/NoxAgentRegistry.sol";
import {NoxPayments} from "../src/NoxPayments.sol";

/// @notice Replaces only NoxPayments (e.g. to add buyPassFor) next to an existing NoxAgentRegistry,
///         so NoxGame, NoxCredits and the registry keep their addresses and history. When the
///         broadcaster is also the admin, it sets the Host Pass price in the same run.
/// Usage:
///   NOX_REGISTRY=0x... NOX_ADMIN=0x... NOX_OPERATOR=0x... NOX_HOST_PASS_PRICE_WEI=1000000000000000000 \
///   NOX_HOST_PASS_DAYS=30 forge script script/DeployPayments.s.sol --rpc-url qie_testnet --account nox-deployer --broadcast --slow
contract DeployPayments is Script {
    uint8 internal constant HOST_PASS = 1;
    address internal constant NATIVE = address(0);

    function run() external returns (NoxPayments payments) {
        NoxAgentRegistry registry = NoxAgentRegistry(vm.envAddress("NOX_REGISTRY"));
        uint256 price = vm.envOr("NOX_HOST_PASS_PRICE_WEI", uint256(0));
        uint64 period = uint64(vm.envOr("NOX_HOST_PASS_DAYS", uint256(30))) * 1 days;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("NOX_ADMIN", deployer);
        address operator = vm.envOr("NOX_OPERATOR", admin);
        payments = deploy(registry, deployer, admin, operator, price, period);
        vm.stopBroadcast();

        console.log("NoxPayments:", address(payments));
        console.log("registry:   ", address(registry));
        if (price > 0 && admin != deployer) {
            console.log("Set the price with the admin wallet: configurePass(1, 0x0, price, period)");
        }
    }

    /// @dev The deployment itself, without env or broadcast (tests call it directly).
    function deploy(
        NoxAgentRegistry registry,
        address deployer,
        address admin,
        address operator,
        uint256 price,
        uint64 period
    ) public returns (NoxPayments payments) {
        require(address(registry).code.length > 0, "NOX_REGISTRY has no code");
        payments = new NoxPayments(admin, operator, registry);
        if (price > 0 && admin == deployer) payments.configurePass(HOST_PASS, NATIVE, price, period);
    }
}
