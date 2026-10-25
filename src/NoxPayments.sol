// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NoxAgentRegistry} from "./NoxAgentRegistry.sol";

/// @title NoxPayments
/// @notice What people pay Nox for (Host Pass, Season Pass, Game Night) and how agent owners get
///         their share. Paid in native QIE (token = address(0)) or an allow-listed ERC-20 such as
///         QUSDC. Rupiah purchases are recorded without moving funds. Nobody pays into a prize pot:
///         money only flows for services, never as stakes on a game result.
/// @dev Pull payments: agent owners and the treasury withdraw; nothing is pushed to arbitrary
///      addresses inside a purchase.
contract NoxPayments is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant NATIVE = address(0);
    uint256 internal constant BPS = 10_000;

    NoxAgentRegistry public immutable registry;

    /// @notice Price per period, per pass type and token. 0 = not for sale in that token.
    mapping(uint8 passType => mapping(address token => uint256)) public priceOf;
    /// @notice Seconds one period of a pass lasts.
    mapping(uint8 passType => uint64) public periodOf;
    mapping(address token => bool) public tokenAllowed;
    /// @notice Pass expiry (unix seconds) per buyer and pass type.
    mapping(address buyer => mapping(uint8 passType => uint64)) public passExpiry;

    /// @notice Revenue held for Nox, per token (withdrawn by the admin or allocated to agent pools).
    mapping(address token => uint256) public treasuryBalance;
    /// @notice Revenue owed to agent owners, per owner and token.
    mapping(address owner => mapping(address token => uint256)) public ownerBalance;
    /// @notice Game Night bookings already paid, so a booking is never charged twice.
    mapping(bytes32 bookingId => bool) public bookingPaid;
    mapping(uint32 period => mapping(address token => bool)) public poolAllocated;

    event PassConfigured(uint8 indexed passType, address indexed token, uint256 price, uint64 period);
    event TokenAllowed(address indexed token, bool allowed);
    event PassPurchased(
        address indexed buyer, uint8 indexed passType, uint32 periods, address token, uint256 amount, uint64 expiresAt
    );
    event FiatPassRecorded(
        address indexed buyer, uint8 indexed passType, uint32 periods, bytes32 receiptHash, uint64 expiresAt
    );
    event GameNightPaid(
        bytes32 indexed bookingId,
        address indexed payer,
        uint256 indexed agentId,
        address token,
        uint256 amount,
        uint256 ownerShare
    );
    event FiatGameNightRecorded(bytes32 indexed bookingId, uint256 indexed agentId, bytes32 receiptHash);
    event AgentPoolAllocated(uint32 indexed period, address indexed token, uint256 total, bytes32 usageRoot);
    event AgentCredited(uint256 indexed agentId, address indexed owner, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event TreasuryWithdrawn(address indexed to, address indexed token, uint256 amount);

    error NotForSale();
    error TokenNotAllowed(address token);
    error WrongAmount(uint256 expected, uint256 sent);
    error AlreadyPaid();
    error AlreadyAllocated();
    error AgentNotActive(uint256 agentId);
    error LengthMismatch();
    error ExceedsTreasury(uint256 total, uint256 available);
    error NothingToWithdraw();
    error InvalidInput();
    error NativeTransferFailed();

    constructor(address admin, address operator, NoxAgentRegistry registry_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        registry = registry_;
        tokenAllowed[NATIVE] = true;
    }

    // ------------------------------------------------------------ admin

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function configurePass(uint8 passType, address token, uint256 price, uint64 period)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (period == 0) revert InvalidInput();
        if (!tokenAllowed[token]) revert TokenNotAllowed(token);
        priceOf[passType][token] = price;
        periodOf[passType] = period;
        emit PassConfigured(passType, token, price, period);
    }

    function withdrawTreasury(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (amount == 0 || amount > treasuryBalance[token]) {
            revert ExceedsTreasury(amount, treasuryBalance[token]);
        }
        treasuryBalance[token] -= amount;
        _send(token, to, amount);
        emit TreasuryWithdrawn(to, token, amount);
    }

    // ------------------------------------------------------------ passes

    /// @notice Buy `periods` of a pass with native QIE (send exact value) or an allowed ERC-20 (approve first).
    function buyPass(uint8 passType, uint32 periods, address token) external payable nonReentrant {
        uint256 price = priceOf[passType][token];
        if (price == 0 || periods == 0) revert NotForSale();
        uint256 amount = price * periods;
        _collect(token, amount);
        treasuryBalance[token] += amount;
        uint64 expiresAt = _extend(msg.sender, passType, periods);
        emit PassPurchased(msg.sender, passType, periods, token, amount, expiresAt);
    }

    /// @notice A pass paid in rupiah through the PSP: no funds move on-chain, the receipt hash is the proof.
    function recordFiatPass(address buyer, uint8 passType, uint32 periods, bytes32 receiptHash)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (periodOf[passType] == 0 || periods == 0) revert NotForSale();
        uint64 expiresAt = _extend(buyer, passType, periods);
        emit FiatPassRecorded(buyer, passType, periods, receiptHash, expiresAt);
    }

    function hasPass(address account, uint8 passType) external view returns (bool) {
        return passExpiry[account][passType] > block.timestamp;
    }

    // ------------------------------------------------------------ Game Night

    /// @notice Pay a quoted Game Night. With an agent, its owner's share is credited at once.
    function payGameNight(bytes32 bookingId, uint256 agentId, address token, uint256 amount)
        external
        payable
        nonReentrant
    {
        if (bookingPaid[bookingId]) revert AlreadyPaid();
        if (amount == 0) revert InvalidInput();
        bookingPaid[bookingId] = true;
        _collect(token, amount);
        uint256 ownerShare;
        if (agentId != 0) {
            if (!registry.isActive(agentId)) revert AgentNotActive(agentId);
            ownerShare = amount * registry.shareOf(agentId) / BPS;
            address owner = registry.ownerOf(agentId);
            ownerBalance[owner][token] += ownerShare;
            emit AgentCredited(agentId, owner, token, ownerShare);
        }
        treasuryBalance[token] += amount - ownerShare;
        emit GameNightPaid(bookingId, msg.sender, agentId, token, amount, ownerShare);
    }

    /// @notice A Game Night paid in rupiah; the agent owner's share is paid off-chain by disbursement.
    function recordFiatGameNight(bytes32 bookingId, uint256 agentId, bytes32 receiptHash)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (bookingPaid[bookingId]) revert AlreadyPaid();
        bookingPaid[bookingId] = true;
        emit FiatGameNightRecorded(bookingId, agentId, receiptHash);
    }

    // ------------------------------------------------------------ agent pool

    /// @notice Monthly settlement of pass revenue to agent owners. Amounts are computed off-chain
    ///         (pass revenue x owner share, pro-rata to valid games per agent); `usageRoot` commits to
    ///         the per-game usage data so anyone can recheck them. Each (period, token) settles once.
    function allocateAgentPool(
        uint32 period,
        address token,
        uint256[] calldata agentIds,
        uint256[] calldata amounts,
        bytes32 usageRoot
    ) external onlyRole(OPERATOR_ROLE) {
        if (agentIds.length != amounts.length) revert LengthMismatch();
        if (poolAllocated[period][token]) revert AlreadyAllocated();
        poolAllocated[period][token] = true;
        uint256 total;
        for (uint256 i; i < agentIds.length; ++i) {
            total += amounts[i];
        }
        if (total > treasuryBalance[token]) revert ExceedsTreasury(total, treasuryBalance[token]);
        treasuryBalance[token] -= total;
        for (uint256 i; i < agentIds.length; ++i) {
            address owner = registry.ownerOf(agentIds[i]);
            if (owner == address(0)) revert AgentNotActive(agentIds[i]);
            ownerBalance[owner][token] += amounts[i];
            emit AgentCredited(agentIds[i], owner, token, amounts[i]);
        }
        emit AgentPoolAllocated(period, token, total, usageRoot);
    }

    /// @notice Agent owners pull what they are owed.
    function withdraw(address token) external nonReentrant {
        uint256 amount = ownerBalance[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        ownerBalance[msg.sender][token] = 0;
        _send(token, msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ------------------------------------------------------------ internal

    function _collect(address token, uint256 amount) internal {
        if (!tokenAllowed[token]) revert TokenNotAllowed(token);
        if (token == NATIVE) {
            if (msg.value != amount) revert WrongAmount(amount, msg.value);
        } else {
            if (msg.value != 0) revert WrongAmount(0, msg.value);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _extend(address buyer, uint8 passType, uint32 periods) internal returns (uint64 expiresAt) {
        uint64 start =
            passExpiry[buyer][passType] > block.timestamp ? passExpiry[buyer][passType] : uint64(block.timestamp);
        expiresAt = start + periodOf[passType] * periods;
        passExpiry[buyer][passType] = expiresAt;
    }
}
