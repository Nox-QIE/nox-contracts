// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployPayments} from "../script/DeployPayments.s.sol";
import {NoxAgentRegistry} from "../src/NoxAgentRegistry.sol";
import {NoxPayments} from "../src/NoxPayments.sol";

/// @dev No vm.setEnv here: env is process-wide and test suites run in parallel.
contract DeployPaymentsTest is Test {
    NoxAgentRegistry registry;
    DeployPayments script;
    address operator = makeAddr("operator");

    function setUp() public {
        registry = new NoxAgentRegistry(address(this), operator);
        script = new DeployPayments();
    }

    function test_replacesPayments_keepsRegistry_andPricesThePassWhenAdmin() public {
        // The script contract stands in for the broadcaster: it deploys, so it is the admin here.
        NoxPayments p = script.deploy(registry, address(script), address(script), operator, 1 ether, 30 days);
        assertEq(address(p.registry()), address(registry));
        assertTrue(p.hasRole(p.OPERATOR_ROLE(), operator));
        assertEq(p.priceOf(1, address(0)), 1 ether);
        assertEq(p.periodOf(1), 30 days);
    }

    function test_leavesThePriceToASeparateAdmin() public {
        address admin = makeAddr("cold admin");
        NoxPayments p = script.deploy(registry, address(script), admin, operator, 1 ether, 30 days);
        assertTrue(p.hasRole(p.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(p.priceOf(1, address(0)), 0);
    }

    function test_refusesARegistryWithoutCode() public {
        vm.expectRevert("NOX_REGISTRY has no code");
        script.deploy(NoxAgentRegistry(makeAddr("nothing")), address(script), address(script), operator, 0, 30 days);
    }
}
