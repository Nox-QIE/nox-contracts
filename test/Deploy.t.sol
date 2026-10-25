// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";

contract DeployTest is Test {
    function test_deploy_handsAdminOverAndWiresMinter() public {
        address admin = makeAddr("multisig");
        address operator = makeAddr("operator");
        vm.setEnv("NOX_ADMIN", vm.toString(admin));
        vm.setEnv("NOX_OPERATOR", vm.toString(operator));
        (NoxCredits credits, NoxGame game) = new Deploy().run();

        assertTrue(credits.hasRole(credits.MINTER_ROLE(), address(game)));
        assertTrue(credits.hasRole(credits.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(game.hasRole(game.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(game.hasRole(game.OPERATOR_ROLE(), operator));
        assertEq(address(game.credits()), address(credits));
        // The deployer keeps no admin power over credits.
        (, address deployer,) = vm.readCallers();
        assertFalse(credits.hasRole(credits.DEFAULT_ADMIN_ROLE(), deployer));
    }
}
