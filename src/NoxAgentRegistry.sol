// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title NoxAgentRegistry
/// @notice Third-party AI Game Masters (Agent Marketplace). An agent is registered by the operator
///         after moderation, points to its owner's payout wallet, and carries the owner's revenue
///         share in basis points (default 30%). The persona text or endpoint lives off-chain; only
///         its hash is stored here.
contract NoxAgentRegistry is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint16 public constant MAX_BPS = 10_000;

    enum Mode {
        None,
        HostedPersona,
        ExternalEndpoint
    }

    enum Status {
        None,
        Active,
        Suspended,
        Revoked
    }

    struct Agent {
        address owner;
        Mode mode;
        Status status;
        bool customShare;
        uint16 shareBps;
        bytes32 metadataHash;
    }

    uint16 public defaultShareBps = 3_000;
    uint256 public agentCount;
    mapping(uint256 agentId => Agent) internal _agents;

    event AgentRegistered(uint256 indexed agentId, address indexed owner, Mode mode, bytes32 metadataHash);
    event AgentStatusChanged(uint256 indexed agentId, Status status);
    event AgentMetadataUpdated(uint256 indexed agentId, bytes32 metadataHash);
    event AgentOwnerChanged(uint256 indexed agentId, address indexed owner);
    /// @dev agentId 0 = the default share for every agent without its own share.
    event ShareChanged(uint256 indexed agentId, uint16 shareBps);

    error UnknownAgent(uint256 agentId);
    error InvalidShare(uint16 bps);
    error InvalidInput();

    constructor(address admin, address operator) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // ------------------------------------------------------------ operator

    function registerAgent(address owner, Mode mode, bytes32 metadataHash)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256 agentId)
    {
        if (owner == address(0) || mode == Mode.None) revert InvalidInput();
        agentId = ++agentCount;
        _agents[agentId] = Agent(owner, mode, Status.Active, false, 0, metadataHash);
        emit AgentRegistered(agentId, owner, mode, metadataHash);
    }

    function setStatus(uint256 agentId, Status status) external onlyRole(OPERATOR_ROLE) {
        if (status == Status.None) revert InvalidInput();
        _agent(agentId).status = status;
        emit AgentStatusChanged(agentId, status);
    }

    /// @notice A re-moderated persona or a moved endpoint gets a new hash.
    function updateMetadata(uint256 agentId, bytes32 metadataHash) external onlyRole(OPERATOR_ROLE) {
        _agent(agentId).metadataHash = metadataHash;
        emit AgentMetadataUpdated(agentId, metadataHash);
    }

    function setOwner(uint256 agentId, address owner) external onlyRole(OPERATOR_ROLE) {
        if (owner == address(0)) revert InvalidInput();
        _agent(agentId).owner = owner;
        emit AgentOwnerChanged(agentId, owner);
    }

    // ------------------------------------------------------------ admin: revenue share

    /// @notice Applies from the next settlement; already credited revenue is not touched.
    function setDefaultShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_BPS) revert InvalidShare(bps);
        defaultShareBps = bps;
        emit ShareChanged(0, bps);
    }

    function setAgentShareBps(uint256 agentId, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_BPS) revert InvalidShare(bps);
        Agent storage a = _agent(agentId);
        a.customShare = true;
        a.shareBps = bps;
        emit ShareChanged(agentId, bps);
    }

    /// @notice Back to the default share.
    function clearAgentShare(uint256 agentId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _agent(agentId).customShare = false;
        emit ShareChanged(agentId, defaultShareBps);
    }

    // ------------------------------------------------------------ views

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return _agents[agentId];
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _agents[agentId].owner;
    }

    function isActive(uint256 agentId) external view returns (bool) {
        return _agents[agentId].status == Status.Active;
    }

    function shareOf(uint256 agentId) public view returns (uint16) {
        Agent storage a = _agents[agentId];
        return a.customShare ? a.shareBps : defaultShareBps;
    }

    function _agent(uint256 agentId) internal view returns (Agent storage a) {
        a = _agents[agentId];
        if (a.status == Status.None) revert UnknownAgent(agentId);
    }
}
