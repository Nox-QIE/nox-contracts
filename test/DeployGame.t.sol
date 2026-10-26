// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployGame} from "../script/DeployGame.s.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";

/// @dev No vm.setEnv here: env is process-wide and test suites run in parallel.
contract DeployGameTest is Test {
    DeployGame script;
    address operator = makeAddr("operator");

    function setUp() public {
        script = new DeployGame();
    }

    function test_replacesGame_keepsCredits_andGrantsMinterWhenAdmin() public {
        // The script contract stands in for the broadcaster: it is the NoxCredits admin here.
        NoxCredits credits = new NoxCredits(address(script));
        NoxGame game = script.deploy(credits, address(script), address(script), operator);
        assertEq(address(game.credits()), address(credits));
        assertTrue(credits.hasRole(credits.MINTER_ROLE(), address(game)));
        assertTrue(game.hasRole(game.OPERATOR_ROLE(), operator));
        assertEq(game.scamShieldBonus(), 5);
    }

    function test_leavesTheMinterRoleToASeparateCreditsAdmin() public {
        NoxCredits credits = new NoxCredits(makeAddr("cold admin"));
        NoxGame game = script.deploy(credits, address(script), address(script), operator);
        assertFalse(credits.hasRole(credits.MINTER_ROLE(), address(game)));
    }

    function test_refusesCreditsWithoutCode() public {
        vm.expectRevert("NOX_CREDITS has no code");
        script.deploy(NoxCredits(makeAddr("nothing")), address(script), address(script), operator);
    }
}
