// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoxAgentRegistry} from "../src/NoxAgentRegistry.sol";
import {NoxPayments} from "../src/NoxPayments.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock QUSDC", "QUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NoxAgentsPaymentsTest is Test {
    NoxAgentRegistry registry;
    NoxPayments payments;
    MockUSDC usdc;
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address owner = makeAddr("agentOwner");
    address host = makeAddr("host");
    address client = makeAddr("client");
    uint8 constant HOST_PASS = 1;
    address constant NATIVE = address(0);

    function setUp() public {
        registry = new NoxAgentRegistry(admin, operator);
        payments = new NoxPayments(admin, operator, registry);
        usdc = new MockUSDC();
        vm.startPrank(admin);
        payments.setTokenAllowed(address(usdc), true);
        payments.configurePass(HOST_PASS, NATIVE, 1 ether, 30 days);
        payments.configurePass(HOST_PASS, address(usdc), 5e6, 30 days);
        vm.stopPrank();
        vm.deal(host, 10 ether);
        vm.deal(client, 100 ether);
        usdc.mint(host, 100e6);
        usdc.mint(client, 1_000e6);
    }

    function _register() internal returns (uint256 id) {
        vm.prank(operator);
        id = registry.registerAgent(owner, NoxAgentRegistry.Mode.HostedPersona, keccak256("persona v1"));
    }

    // ------------------------------------------------------------ registry

    function test_registry_defaultShareIs30Percent_andAdjustable() public {
        uint256 id = _register();
        assertEq(id, 1);
        assertEq(registry.shareOf(id), 3_000);
        assertTrue(registry.isActive(id));

        vm.prank(admin);
        registry.setAgentShareBps(id, 4_500);
        assertEq(registry.shareOf(id), 4_500);
        vm.prank(admin);
        registry.setDefaultShareBps(2_500);
        assertEq(registry.shareOf(id), 4_500); // custom share survives a default change
        vm.prank(admin);
        registry.clearAgentShare(id);
        assertEq(registry.shareOf(id), 2_500);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NoxAgentRegistry.InvalidShare.selector, uint16(10_001)));
        registry.setDefaultShareBps(10_001);
    }

    function test_registry_onlyOperatorRegisters_onlyAdminSetsShare() public {
        vm.expectRevert();
        registry.registerAgent(owner, NoxAgentRegistry.Mode.HostedPersona, bytes32(0));
        uint256 id = _register();
        vm.prank(operator);
        vm.expectRevert();
        registry.setAgentShareBps(id, 9_000);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxAgentRegistry.UnknownAgent.selector, 99));
        registry.setStatus(99, NoxAgentRegistry.Status.Suspended);
    }

    // ------------------------------------------------------------ passes

    function test_pass_nativeAndToken_extendExpiry() public {
        vm.prank(host);
        payments.buyPass{value: 2 ether}(HOST_PASS, 2, NATIVE);
        assertEq(payments.passExpiry(host, HOST_PASS), block.timestamp + 60 days);
        assertTrue(payments.hasPass(host, HOST_PASS));

        vm.startPrank(host);
        usdc.approve(address(payments), 5e6);
        payments.buyPass(HOST_PASS, 1, address(usdc));
        vm.stopPrank();
        assertEq(payments.passExpiry(host, HOST_PASS), block.timestamp + 90 days); // stacked on top
        assertEq(payments.treasuryBalance(NATIVE), 2 ether);
        assertEq(payments.treasuryBalance(address(usdc)), 5e6);

        vm.warp(block.timestamp + 91 days);
        assertFalse(payments.hasPass(host, HOST_PASS));
    }

    function test_pass_buyForAnotherWallet() public {
        address gameWallet = makeAddr("host game wallet");
        vm.expectEmit(true, true, true, true);
        emit NoxPayments.PassPaidBy(host, gameWallet, HOST_PASS);
        vm.prank(host);
        payments.buyPassFor{value: 2 ether}(gameWallet, HOST_PASS, 2, NATIVE);
        assertTrue(payments.hasPass(gameWallet, HOST_PASS));
        assertFalse(payments.hasPass(host, HOST_PASS)); // the payer gets nothing
        assertEq(payments.passExpiry(gameWallet, HOST_PASS), block.timestamp + 60 days);
        assertEq(payments.treasuryBalance(NATIVE), 2 ether);

        // Renewals stack, whoever pays; paying for yourself emits no PassPaidBy.
        vm.prank(gameWallet);
        vm.deal(gameWallet, 1 ether);
        payments.buyPassFor{value: 1 ether}(gameWallet, HOST_PASS, 1, NATIVE);
        assertEq(payments.passExpiry(gameWallet, HOST_PASS), block.timestamp + 90 days);

        vm.prank(host);
        vm.expectRevert(NoxPayments.InvalidInput.selector);
        payments.buyPassFor{value: 1 ether}(address(0), HOST_PASS, 1, NATIVE);
    }

    function test_pass_wrongValueOrUnlistedReverts() public {
        vm.prank(host);
        vm.expectRevert(abi.encodeWithSelector(NoxPayments.WrongAmount.selector, 1 ether, 0.5 ether));
        payments.buyPass{value: 0.5 ether}(HOST_PASS, 1, NATIVE);
        vm.prank(host);
        vm.expectRevert(NoxPayments.NotForSale.selector);
        payments.buyPass{value: 1 ether}(7, 1, NATIVE);
    }

    function test_pass_fiatRecordedWithoutFunds() public {
        vm.prank(operator);
        payments.recordFiatPass(host, HOST_PASS, 1, keccak256("psp receipt 123"));
        assertTrue(payments.hasPass(host, HOST_PASS));
        assertEq(payments.treasuryBalance(NATIVE), 0);
        assertTrue(payments.receiptUsed(keccak256("psp receipt 123")));
    }

    function test_fiat_receiptCannotBeReused() public {
        bytes32 receipt = keccak256("bank transfer 42");
        vm.startPrank(operator);
        payments.recordFiatPass(host, HOST_PASS, 1, receipt);
        uint64 expiry = payments.passExpiry(host, HOST_PASS);
        // The same receipt again would extend the pass for free: refused, for passes and nights alike.
        vm.expectRevert(NoxPayments.ReceiptUsed.selector);
        payments.recordFiatPass(host, HOST_PASS, 1, receipt);
        vm.expectRevert(NoxPayments.ReceiptUsed.selector);
        payments.recordFiatGameNight(keccak256("booking-9"), 0, receipt);
        assertFalse(payments.bookingPaid(keccak256("booking-9")));
        vm.expectRevert(NoxPayments.InvalidInput.selector);
        payments.recordFiatPass(host, HOST_PASS, 1, bytes32(0));
        vm.stopPrank();
        assertEq(payments.passExpiry(host, HOST_PASS), expiry);
    }

    // ------------------------------------------------------------ Game Night

    function test_gameNight_ownerGets30Percent_noxGets70() public {
        uint256 id = _register();
        vm.prank(client);
        payments.payGameNight{value: 10 ether}(keccak256("booking-1"), id, NATIVE, 10 ether);
        assertEq(payments.ownerBalance(owner, NATIVE), 3 ether);
        assertEq(payments.treasuryBalance(NATIVE), 7 ether);

        vm.prank(client);
        vm.expectRevert(NoxPayments.AlreadyPaid.selector);
        payments.payGameNight{value: 10 ether}(keccak256("booking-1"), id, NATIVE, 10 ether);

        uint256 before = owner.balance;
        vm.prank(owner);
        payments.withdraw(NATIVE);
        assertEq(owner.balance - before, 3 ether);
        vm.prank(owner);
        vm.expectRevert(NoxPayments.NothingToWithdraw.selector);
        payments.withdraw(NATIVE);
    }

    function test_gameNight_withoutAgent_allToTreasury_suspendedAgentRejected() public {
        vm.startPrank(client);
        usdc.approve(address(payments), 200e6);
        payments.payGameNight(keccak256("b-2"), 0, address(usdc), 200e6);
        vm.stopPrank();
        assertEq(payments.treasuryBalance(address(usdc)), 200e6);

        uint256 id = _register();
        vm.prank(operator);
        registry.setStatus(id, NoxAgentRegistry.Status.Suspended);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(NoxPayments.AgentNotActive.selector, id));
        payments.payGameNight{value: 1 ether}(keccak256("b-3"), id, NATIVE, 1 ether);
    }

    function testFuzz_gameNight_splitNeverLeaksOrMints(uint96 amount, uint16 bps) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        bps = uint16(bound(bps, 0, 10_000));
        uint256 id = _register();
        vm.prank(admin);
        registry.setAgentShareBps(id, bps);
        vm.prank(client);
        payments.payGameNight{value: amount}(keccak256(abi.encode(amount, bps)), id, NATIVE, amount);
        uint256 owed = payments.ownerBalance(owner, NATIVE);
        assertEq(owed, uint256(amount) * bps / 10_000);
        assertEq(owed + payments.treasuryBalance(NATIVE), amount);
        assertEq(address(payments).balance, amount);
    }

    // ------------------------------------------------------------ agent pool

    function test_agentPool_settlesOncePerPeriod_withinTreasury() public {
        uint256 a = _register();
        vm.prank(operator);
        uint256 b =
            registry.registerAgent(makeAddr("owner2"), NoxAgentRegistry.Mode.ExternalEndpoint, keccak256("https://x"));
        vm.prank(host);
        payments.buyPass{value: 3 ether}(HOST_PASS, 3, NATIVE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.6 ether;
        amounts[1] = 0.3 ether;

        vm.prank(operator);
        payments.allocateAgentPool(202611, NATIVE, ids, amounts, keccak256("usage"));
        assertEq(payments.ownerBalance(owner, NATIVE), 0.6 ether);
        assertEq(payments.treasuryBalance(NATIVE), 2.1 ether);

        vm.prank(operator);
        vm.expectRevert(NoxPayments.AlreadyAllocated.selector);
        payments.allocateAgentPool(202611, NATIVE, ids, amounts, keccak256("usage"));

        amounts[0] = 5 ether;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NoxPayments.ExceedsTreasury.selector, 5.3 ether, 2.1 ether));
        payments.allocateAgentPool(202612, NATIVE, ids, amounts, keccak256("usage"));
    }

    function test_treasury_onlyAdminWithdraws() public {
        vm.prank(host);
        payments.buyPass{value: 1 ether}(HOST_PASS, 1, NATIVE);
        vm.prank(operator);
        vm.expectRevert();
        payments.withdrawTreasury(NATIVE, operator, 1 ether);
        address safe = makeAddr("treasurySafe");
        vm.prank(admin);
        payments.withdrawTreasury(NATIVE, safe, 1 ether);
        assertEq(safe.balance, 1 ether);
    }
}
