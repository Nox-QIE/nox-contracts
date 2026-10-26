// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {NoxBadges} from "../src/NoxBadges.sol";

contract NoxBadgesTest is Test {
    NoxBadges badges;
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    bytes32 constant SPOTTER = keccak256("SCAM_SPOTTER");
    bytes32 constant GAME = keccak256("game-1");

    function setUp() public {
        badges = new NoxBadges(admin, operator);
        vm.prank(admin);
        badges.defineBadge(SPOTTER, "Scam Spotter", true);
    }

    function _players(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    function test_awardsEachPlayerOncePerGame_countsAcrossGames() public {
        address[] memory ps = _players(4);
        vm.expectEmit(true, true, true, true);
        emit NoxBadges.BadgeAwarded(ps[0], SPOTTER, GAME, 1);
        vm.prank(operator);
        badges.award(SPOTTER, GAME, ps);
        for (uint256 i; i < 4; ++i) {
            assertEq(badges.countOf(ps[i], SPOTTER), 1);
        }

        // A retried transaction for the same game adds nothing and emits nothing.
        vm.recordLogs();
        vm.prank(operator);
        badges.award(SPOTTER, GAME, ps);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(badges.countOf(ps[0], SPOTTER), 1);

        vm.prank(operator);
        badges.award(SPOTTER, keccak256("game-2"), ps);
        assertEq(badges.countOf(ps[0], SPOTTER), 2);
    }

    function test_onlyOperatorAwards_onlyAdminDefines() public {
        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert();
        badges.award(SPOTTER, GAME, _players(1));
        vm.prank(operator);
        vm.expectRevert();
        badges.defineBadge(keccak256("X"), "X", true);
    }

    function test_rejectsUnknownOrRetiredBadges_andBadInput() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxBadges.UnknownBadge.selector, keccak256("NOPE")));
        badges.award(keccak256("NOPE"), GAME, _players(1));
        vm.expectRevert(NoxBadges.InvalidInput.selector);
        badges.award(SPOTTER, bytes32(0), _players(1));
        vm.expectRevert(NoxBadges.InvalidInput.selector);
        badges.award(SPOTTER, GAME, _players(13));
        vm.expectRevert(NoxBadges.InvalidInput.selector);
        badges.award(SPOTTER, GAME, new address[](1)); // zero address
        vm.stopPrank();

        vm.prank(admin);
        badges.defineBadge(SPOTTER, "Scam Spotter", false); // retired
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxBadges.UnknownBadge.selector, SPOTTER));
        badges.award(SPOTTER, GAME, _players(1));
    }

    function test_badgesCannotMove() public view {
        // No transfer, approve or burn: the contract has no such functions.
        bytes4[3] memory moves = [
            bytes4(keccak256("transfer(address,uint256)")),
            bytes4(keccak256("approve(address,uint256)")),
            bytes4(keccak256("transferFrom(address,address,uint256)"))
        ];
        for (uint256 i; i < moves.length; ++i) {
            (bool ok,) = address(badges).staticcall(abi.encodeWithSelector(moves[i], address(1), 1));
            assertFalse(ok);
        }
    }
}

import {DeployBadges} from "../script/DeployBadges.s.sol";

contract DeployBadgesTest is Test {
    function test_definesScamSpotterWhenTheDeployerIsAdmin() public {
        DeployBadges script = new DeployBadges();
        NoxBadges b = script.deploy(address(script), address(script), makeAddr("operator"));
        (string memory name, bool active) = b.badges(keccak256("SCAM_SPOTTER"));
        assertEq(name, "Scam Spotter");
        assertTrue(active);
        NoxBadges cold = script.deploy(address(script), makeAddr("cold admin"), makeAddr("operator"));
        (, bool coldActive) = cold.badges(keccak256("SCAM_SPOTTER"));
        assertFalse(coldActive); // a separate admin defines it
    }
}
