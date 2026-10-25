// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {NoxCredits} from "../src/NoxCredits.sol";
import {NoxGame} from "../src/NoxGame.sol";

/// @dev Uses test/vectors/crypto-spec-v1.json, copied from @nox/shared crypto-spec, so the
///      TypeScript (server/browser) and Solidity hashing are proven identical.
contract NoxGameTest is Test {
    using stdJson for string;

    NoxCredits credits;
    NoxGame game;
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    string vectors;
    bytes32 gameId;
    address[] players;
    uint8[] roles;
    bytes32[] salts;

    function setUp() public {
        credits = new NoxCredits(admin);
        game = new NoxGame(admin, operator, credits);
        vm.startPrank(admin);
        credits.grantRole(credits.MINTER_ROLE(), address(game));
        vm.stopPrank();

        vectors = vm.readFile("test/vectors/crypto-spec-v1.json");
        gameId = vectors.readBytes32(".gameId");
        for (uint256 i; i < 5; ++i) {
            string memory p = string.concat(".roleLeaves[", vm.toString(i), "]");
            players.push(vectors.readAddress(string.concat(p, ".player")));
            roles.push(_roleCode(vectors.readString(string.concat(p, ".role"))));
            salts.push(vectors.readBytes32(string.concat(p, ".salt")));
        }
    }

    // ------------------------------------------------------------ crypto-spec parity

    function test_vectors_roleLeavesAndProofsMatchTypeScript() public view {
        bytes32 root = vectors.readBytes32(".rolesRoot");
        for (uint256 i; i < 5; ++i) {
            string memory p = string.concat(".roleLeaves[", vm.toString(i), "]");
            bytes32 leaf = game.roleLeaf(gameId, players[i], roles[i], salts[i]);
            assertEq(leaf, vectors.readBytes32(string.concat(p, ".leaf")));
            assertTrue(MerkleProof.verify(vectors.readBytes32Array(string.concat(p, ".proof")), root, leaf));
        }
    }

    function test_vectors_actionHashMatchesTypeScript() public view {
        bytes32 h = game.actionHash(
            gameId,
            uint16(vectors.readUint(".action.round")),
            vectors.readAddress(".action.player"),
            1, // kill
            vectors.readAddress(".action.target"),
            vectors.readBytes32(".action.nonce")
        );
        assertEq(h, vectors.readBytes32(".action.hash"));
    }

    // ------------------------------------------------------------ full game

    function test_fullGame_villageWins_creditsMinted() public {
        _startGame();

        // Night 1: the werewolf (players[0]) commits a kill on players[3] from its own wallet.
        bytes32 nonce = vectors.readBytes32(".action.nonce");
        vm.prank(players[0]);
        game.commitNightAction(gameId, 1, vectors.readBytes32(".action.hash"));

        // Day 1: everyone alive votes the werewolf.
        for (uint256 i; i < 5; ++i) {
            if (i == 3) continue;
            vm.prank(players[i]);
            game.castVote(gameId, 1, players[0]);
        }
        vm.prank(operator);
        game.recordRound(gameId, 1, keccak256("round 1 result"));

        NoxGame.NightReveal[] memory nights = new NoxGame.NightReveal[](1);
        nights[0] = NoxGame.NightReveal(1, players[0], 1, players[3], nonce);

        uint8 village = game.TEAM_VILLAGE(); // read before prank: an external call would consume it
        NoxGame.RoleReveal[] memory reveals = _reveals();
        vm.expectEmit(true, false, false, true);
        emit NoxGame.GameFinalized(gameId, keccak256("final"), village);
        vm.prank(operator);
        game.revealAndFinalize(gameId, reveals, nights, keccak256("final"), village);

        (NoxGame.Status status,,,,,,,) = game.games(gameId);
        assertEq(uint8(status), uint8(NoxGame.Status.Finalized));
        assertEq(credits.balanceOf(players[0]), 10); // werewolf lost: participation only
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(credits.balanceOf(players[i]), 30);
        }
        assertEq(game.revealedRoleOf(gameId, players[1]), 3); // seer
    }

    // ------------------------------------------------------------ rejections

    function test_reveal_wrongSaltReverts() public {
        _startGame();
        NoxGame.RoleReveal[] memory r = _reveals();
        r[2].salt = keccak256("forged");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.BadReveal.selector, players[2]));
        game.revealAndFinalize(gameId, r, new NoxGame.NightReveal[](0), bytes32(0), 1);
    }

    function test_reveal_swappedRoleReverts() public {
        _startGame();
        NoxGame.RoleReveal[] memory r = _reveals();
        r[3].role = 2; // claim the villager was a werewolf
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.BadReveal.selector, players[3]));
        game.revealAndFinalize(gameId, r, new NoxGame.NightReveal[](0), bytes32(0), 1);
    }

    function test_reveal_mustCoverEveryNightCommit() public {
        _startGame();
        vm.prank(players[0]);
        game.commitNightAction(gameId, 1, vectors.readBytes32(".action.hash"));
        vm.prank(operator);
        vm.expectRevert(NoxGame.RevealCountMismatch.selector);
        game.revealAndFinalize(gameId, _reveals(), new NoxGame.NightReveal[](0), bytes32(0), 1);
    }

    function test_reveal_forgedNightActionReverts() public {
        _startGame();
        vm.prank(players[0]);
        game.commitNightAction(gameId, 1, vectors.readBytes32(".action.hash"));
        NoxGame.NightReveal[] memory nights = new NoxGame.NightReveal[](1);
        nights[0] = NoxGame.NightReveal(1, players[0], 1, players[4], vectors.readBytes32(".action.nonce")); // other target
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.BadNightReveal.selector, players[0], uint16(1)));
        game.revealAndFinalize(gameId, _reveals(), nights, bytes32(0), 1);
    }

    function test_reveal_duplicatePlayerReverts() public {
        _startGame();
        NoxGame.RoleReveal[] memory r = _reveals();
        r[4] = r[3];
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.BadReveal.selector, players[3]));
        game.revealAndFinalize(gameId, r, new NoxGame.NightReveal[](0), bytes32(0), 1);
    }

    function test_vote_oncePerRound_playersOnly() public {
        _startGame();
        vm.prank(players[1]);
        game.castVote(gameId, 1, players[0]);
        vm.prank(players[1]);
        vm.expectRevert(NoxGame.AlreadyVoted.selector);
        game.castVote(gameId, 1, players[2]);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.NotAPlayer.selector, stranger));
        game.castVote(gameId, 1, players[0]);

        vm.prank(players[2]);
        vm.expectRevert(abi.encodeWithSelector(NoxGame.WrongRound.selector, uint16(1), uint16(2)));
        game.castVote(gameId, 2, players[0]);
    }

    function test_lobby_rules() public {
        vm.prank(operator);
        game.createGame(gameId, bytes32(0));
        vm.prank(operator);
        vm.expectRevert(NoxGame.AlreadyExists.selector);
        game.createGame(gameId, bytes32(0));

        vm.prank(players[0]);
        game.joinGame(gameId);
        vm.prank(players[0]);
        vm.expectRevert(NoxGame.AlreadyJoined.selector);
        game.joinGame(gameId);

        vm.prank(operator);
        vm.expectRevert(NoxGame.NotEnoughPlayers.selector);
        game.commitRoles(gameId, bytes32(0));

        for (uint256 i = 1; i < 12; ++i) {
            vm.prank(address(uint160(0xA000 + i)));
            game.joinGame(gameId);
        }
        vm.prank(makeAddr("thirteenth"));
        vm.expectRevert(NoxGame.GameFull.selector);
        game.joinGame(gameId);
    }

    function test_onlyOperatorWrites() public {
        address mallory = makeAddr("mallory");
        bytes32 role = game.OPERATOR_ROLE();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, role));
        game.createGame(gameId, bytes32(0));
    }

    function test_cancelledGameRejectsActions() public {
        _startGame();
        vm.prank(operator);
        game.cancelGame(gameId, "players left");
        vm.prank(players[1]);
        vm.expectRevert();
        game.castVote(gameId, 1, players[0]);
    }

    // ------------------------------------------------------------ credits

    function test_credits_nonTransferable() public {
        _startGame();
        vm.prank(operator);
        game.revealAndFinalize(gameId, _reveals(), new NoxGame.NightReveal[](0), bytes32(0), 2);
        assertEq(credits.balanceOf(players[0]), 30); // wolves won
        vm.prank(players[0]);
        vm.expectRevert(NoxCredits.NonTransferable.selector);
        credits.transfer(players[1], 1);
        vm.prank(players[0]);
        vm.expectRevert(NoxCredits.NonTransferable.selector);
        credits.approve(players[1], 1);
        assertEq(credits.decimals(), 0);
    }

    function test_credits_onlyMinter() public {
        vm.expectRevert();
        credits.mint(address(this), 1, bytes32(0));
    }

    // ------------------------------------------------------------ gas, worst case

    /// @dev 12 players (3 wolves, seer, doctor), 5 rounds of night actions from every special role.
    function test_gas_finalize12Players() public {
        bytes32 id = keccak256("gas-12");
        address[] memory ps = new address[](12);
        uint8[] memory rs = new uint8[](12);
        bytes32[] memory ss = new bytes32[](12);
        bytes32[] memory leaves = new bytes32[](12);
        for (uint256 i; i < 12; ++i) {
            ps[i] = address(uint160(0xB000 + i));
            rs[i] = i < 3 ? 2 : i == 3 ? 3 : i == 4 ? 4 : 1;
            ss[i] = keccak256(abi.encode("salt", i));
            leaves[i] = game.roleLeaf(id, ps[i], rs[i], ss[i]);
        }
        bytes32 root = _root(leaves);

        vm.prank(operator);
        game.createGame(id, bytes32(0));
        for (uint256 i; i < 12; ++i) {
            vm.prank(ps[i]);
            game.joinGame(id);
        }
        vm.prank(operator);
        game.commitRoles(id, root);

        NoxGame.NightReveal[] memory nights = _playFiveNights(id, ps);

        NoxGame.RoleReveal[] memory reveals = new NoxGame.RoleReveal[](12);
        for (uint256 i; i < 12; ++i) {
            reveals[i] = NoxGame.RoleReveal(ps[i], rs[i], ss[i], _proof(leaves, i));
        }
        bytes memory data = abi.encodeCall(NoxGame.revealAndFinalize, (id, reveals, nights, bytes32(0), 1));
        vm.prank(operator);
        uint256 g = gasleft();
        game.revealAndFinalize(id, reveals, nights, bytes32(0), 1);
        uint256 used = g - gasleft();
        emit log_named_uint("revealAndFinalize gas (12 players, 25 night actions)", used);
        emit log_named_uint("calldata bytes", data.length);
        assertLt(used, 3_000_000); // far below a block's gas limit
    }

    /// @dev Wolves (0-2) kill, seer (3) inspects, doctor (4) protects, every round; operator records each round.
    function _playFiveNights(bytes32 id, address[] memory ps) internal returns (NoxGame.NightReveal[] memory nights) {
        nights = new NoxGame.NightReveal[](25);
        uint256 k;
        for (uint16 round = 1; round <= 5; ++round) {
            for (uint256 i; i < 5; ++i) {
                nights[k] = NoxGame.NightReveal(
                    round, ps[i], i < 3 ? 1 : i == 3 ? 2 : 3, ps[11], keccak256(abi.encode(round, i))
                );
                NoxGame.NightReveal memory n = nights[k++];
                bytes32 h = game.actionHash(id, n.round, n.player, n.action, n.target, n.nonce);
                vm.prank(n.player);
                game.commitNightAction(id, round, h);
            }
            vm.prank(operator);
            game.recordRound(id, round, keccak256(abi.encode(round)));
        }
    }

    /// @dev Sorted-pair Merkle tree, odd node carried up (same as @nox/shared crypto-spec).
    function _layer(bytes32[] memory nodes) internal pure returns (bytes32[] memory next) {
        next = new bytes32[]((nodes.length + 1) / 2);
        for (uint256 i; i < nodes.length; i += 2) {
            if (i + 1 == nodes.length) {
                next[i / 2] = nodes[i];
            } else {
                next[i / 2] = nodes[i] < nodes[i + 1]
                    ? keccak256(abi.encode(nodes[i], nodes[i + 1]))
                    : keccak256(abi.encode(nodes[i + 1], nodes[i]));
            }
        }
    }

    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory nodes = leaves;
        while (nodes.length > 1) nodes = _layer(nodes);
        return nodes[0];
    }

    function _proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tmp = new bytes32[](8);
        uint256 n;
        bytes32[] memory nodes = leaves;
        while (nodes.length > 1) {
            uint256 sib = index % 2 == 0 ? index + 1 : index - 1;
            if (sib < nodes.length) tmp[n++] = nodes[sib];
            nodes = _layer(nodes);
            index /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            proof[i] = tmp[i];
        }
    }

    // ------------------------------------------------------------ helpers

    function _startGame() internal {
        vm.prank(operator);
        game.createGame(gameId, vectors.readBytes32(".config.hash"));
        for (uint256 i; i < 5; ++i) {
            vm.prank(players[i]);
            game.joinGame(gameId);
        }
        vm.prank(operator);
        game.commitRoles(gameId, vectors.readBytes32(".rolesRoot"));
    }

    function _reveals() internal view returns (NoxGame.RoleReveal[] memory r) {
        r = new NoxGame.RoleReveal[](5);
        for (uint256 i; i < 5; ++i) {
            string memory p = string.concat(".roleLeaves[", vm.toString(i), "].proof");
            r[i] = NoxGame.RoleReveal(players[i], roles[i], salts[i], vectors.readBytes32Array(p));
        }
    }

    function _roleCode(string memory role) internal pure returns (uint8) {
        bytes32 h = keccak256(bytes(role));
        if (h == keccak256("villager")) return 1;
        if (h == keccak256("werewolf")) return 2;
        if (h == keccak256("seer")) return 3;
        if (h == keccak256("doctor")) return 4;
        revert("unknown role");
    }
}
