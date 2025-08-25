// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/security/ReentrancyGuard.sol";
import "@kaiachain/contracts/token/ERC20/IERC20.sol";
import "@kaiachain/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDinRegistry.sol";

/**
 * @title DinoOracle (DIN Oracle)
 * @notice Optimistic oracle system using DIN token governance with zero fees
 * @dev Community-driven oracle with dispute resolution via DIN token staking
 */
contract DinoOracle is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant DISPUTER_ROLE = keccak256("DISPUTER_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    // ============ Enums ============
    enum ProposalState {
        PROPOSED,    // Initial proposal submitted
        ACCEPTED,    // No disputes, automatically accepted
        DISPUTED,    // Under dispute, waiting for resolution
        RESOLVED,    // Dispute resolved by governance
        EXPIRED      // Proposal expired without acceptance
    }

    enum DisputeState {
        ACTIVE,      // Dispute is active, collecting votes
        RESOLVED,    // Dispute resolved
        EXPIRED      // Dispute expired without resolution
    }

    // ============ Structs ============
    struct PriceProposal {
        bytes32 identifier;     // Price identifier (e.g., "BTC-USDT")
        uint256 timestamp;      // Price timestamp
        uint256 value;          // Proposed price value
        address proposer;       // Address that proposed the price
        uint256 proposedAt;     // When the proposal was made
        ProposalState state;    // Current state of proposal
        uint256 disputeId;      // Associated dispute ID (if any)
        uint256 bond;           // DIN tokens bonded for this proposal
        string description;     // Human-readable description
    }

    struct Dispute {
        uint256 proposalId;     // Associated proposal ID
        address disputer;       // Address that initiated dispute
        uint256 disputedAt;     // When dispute was initiated
        DisputeState state;     // Current state of dispute
        uint256 disputeBond;    // DIN tokens bonded for disputing
        uint256 votingDeadline; // Deadline for community voting
        uint256 votesFor;       // Votes supporting original proposal
        uint256 votesAgainst;   // Votes supporting dispute
        mapping(address => bool) hasVoted; // Track who has voted
        mapping(address => uint256) voterStakes; // Stake amounts per voter
        string reason;          // Reason for dispute
    }

    struct VoterInfo {
        uint256 stakedAmount;   // Total DIN staked for voting
        uint256 lockedUntil;    // Locked until timestamp
        uint256 totalVotes;     // Total votes cast
        uint256 successfulVotes; // Successful vote count
    }

    // ============ Storage ============
    IDinRegistry public immutable registry;
    IERC20 public immutable dinToken;

    // Proposal management
    mapping(uint256 => PriceProposal) public proposals;
    mapping(uint256 => Dispute) public disputes;
    uint256 public nextProposalId = 1;
    uint256 public nextDisputeId = 1;

    // Price data storage
    mapping(bytes32 => mapping(uint256 => uint256)) public verifiedPrices; // identifier => timestamp => price
    mapping(bytes32 => uint256) public latestTimestamp; // identifier => latest timestamp
    mapping(bytes32 => uint256) public latestPrice; // identifier => latest price

    // Governance parameters
    uint256 public proposalBond = 1000 * 10**18;        // 1000 DIN required to propose
    uint256 public disputeBond = 2000 * 10**18;         // 2000 DIN required to dispute
    uint256 public livenessWindow = 2 hours;            // Time for disputes after proposal
    uint256 public votingWindow = 24 hours;             // Time for community voting on disputes
    uint256 public minVoterStake = 100 * 10**18;       // Minimum DIN to participate in voting

    // Staking and rewards
    mapping(address => VoterInfo) public voters;
    mapping(address => uint256) public proposerReputations; // Track proposer success rates
    uint256 public totalStaked;

    // Supported price identifiers
    mapping(bytes32 => bool) public supportedIdentifiers;
    bytes32[] public identifierList;

    // ============ Events ============
    event PriceProposed(
        uint256 indexed proposalId,
        bytes32 indexed identifier,
        uint256 timestamp,
        uint256 value,
        address indexed proposer,
        uint256 bond
    );

    event ProposalAccepted(
        uint256 indexed proposalId,
        bytes32 indexed identifier,
        uint256 timestamp,
        uint256 value
    );

    event ProposalDisputed(
        uint256 indexed proposalId,
        uint256 indexed disputeId,
        address indexed disputer,
        uint256 bond,
        string reason
    );

    event DisputeResolved(
        uint256 indexed disputeId,
        uint256 indexed proposalId,
        bool disputeSuccessful,
        uint256 votesFor,
        uint256 votesAgainst
    );

    event VoteCast(
        uint256 indexed disputeId,
        address indexed voter,
        bool supportsDispute,
        uint256 stake
    );

    event StakeDeposited(address indexed user, uint256 amount);
    event StakeWithdrawn(address indexed user, uint256 amount);

    event IdentifierAdded(bytes32 indexed identifier, string description);
    event IdentifierRemoved(bytes32 indexed identifier);

    event BondSlashed(address indexed user, uint256 amount, string reason);
    event RewardsDistributed(uint256 totalRewards, uint256 numRecipients);

    // ============ Custom Errors ============
    error ZeroAddress();
    error InvalidProposalId(uint256 proposalId);
    error InvalidDisputeId(uint256 disputeId);
    error ProposalNotActive(uint256 proposalId);
    error DisputeNotActive(uint256 disputeId);
    error InsufficientBond(uint256 required, uint256 provided);
    error IdentifierNotSupported(bytes32 identifier);
    error ProposalAlreadyDisputed(uint256 proposalId);
    error DisputeWindowClosed(uint256 proposalId);
    error VotingWindowClosed(uint256 disputeId);
    error AlreadyVoted(uint256 disputeId);
    error InsufficientStake(uint256 required, uint256 available);
    error NoStakeToWithdraw();
    error StakeLocked(uint256 lockedUntil);
    error InvalidTimestamp(uint256 timestamp);
    error PriceAlreadyExists(bytes32 identifier, uint256 timestamp);

    // ============ Constructor ============
    constructor(
        address _registry,
        address _admin
    ) {
        if (_registry == address(0) || _admin == address(0)) revert ZeroAddress();
        
        registry = IDinRegistry(_registry);
        dinToken = IERC20(registry.getDINToken());
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PROPOSER_ROLE, _admin);
        _grantRole(DISPUTER_ROLE, _admin);
        _grantRole(RESOLVER_ROLE, _admin);
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Add supported price identifier
     * @param identifier Price identifier (e.g., "BTC-USDT")
     * @param description Human-readable description
     */
    function addIdentifier(bytes32 identifier, string calldata description) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        require(!supportedIdentifiers[identifier], "Identifier already supported");
        
        supportedIdentifiers[identifier] = true;
        identifierList.push(identifier);
        
        emit IdentifierAdded(identifier, description);
    }
    
    /**
     * @notice Remove supported price identifier
     * @param identifier Price identifier to remove
     */
    function removeIdentifier(bytes32 identifier) external onlyRole(ADMIN_ROLE) {
        require(supportedIdentifiers[identifier], "Identifier not supported");
        
        supportedIdentifiers[identifier] = false;
        
        // Remove from array
        for (uint256 i = 0; i < identifierList.length; i++) {
            if (identifierList[i] == identifier) {
                identifierList[i] = identifierList[identifierList.length - 1];
                identifierList.pop();
                break;
            }
        }
        
        emit IdentifierRemoved(identifier);
    }
    
    /**
     * @notice Update governance parameters
     */
    function updateGovernanceParameters(
        uint256 _proposalBond,
        uint256 _disputeBond,
        uint256 _livenessWindow,
        uint256 _votingWindow,
        uint256 _minVoterStake
    ) external onlyRole(ADMIN_ROLE) {
        proposalBond = _proposalBond;
        disputeBond = _disputeBond;
        livenessWindow = _livenessWindow;
        votingWindow = _votingWindow;
        minVoterStake = _minVoterStake;
    }

    // ============ Proposal Functions ============
    
    /**
     * @notice Propose a price for a given identifier and timestamp
     * @param identifier Price identifier
     * @param timestamp Price timestamp
     * @param value Proposed price value
     * @param description Human-readable description
     */
    function proposePrice(
        bytes32 identifier,
        uint256 timestamp,
        uint256 value,
        string calldata description
    ) external whenNotPaused nonReentrant returns (uint256 proposalId) {
        if (!supportedIdentifiers[identifier]) revert IdentifierNotSupported(identifier);
        if (timestamp > block.timestamp) revert InvalidTimestamp(timestamp);
        if (verifiedPrices[identifier][timestamp] != 0) {
            revert PriceAlreadyExists(identifier, timestamp);
        }
        
        // Transfer proposal bond
        dinToken.safeTransferFrom(msg.sender, address(this), proposalBond);
        
        proposalId = nextProposalId++;
        
        proposals[proposalId] = PriceProposal({
            identifier: identifier,
            timestamp: timestamp,
            value: value,
            proposer: msg.sender,
            proposedAt: block.timestamp,
            state: ProposalState.PROPOSED,
            disputeId: 0,
            bond: proposalBond,
            description: description
        });
        
        emit PriceProposed(proposalId, identifier, timestamp, value, msg.sender, proposalBond);
    }
    
    /**
     * @notice Settle a proposal after liveness window (if no disputes)
     * @param proposalId The proposal to settle
     */
    function settleProposal(uint256 proposalId) external {
        PriceProposal storage proposal = proposals[proposalId];
        if (proposal.proposer == address(0)) revert InvalidProposalId(proposalId);
        if (proposal.state != ProposalState.PROPOSED) revert ProposalNotActive(proposalId);
        
        // Check if liveness window has passed
        require(
            block.timestamp >= proposal.proposedAt + livenessWindow,
            "Liveness window not passed"
        );
        
        // Accept proposal
        proposal.state = ProposalState.ACCEPTED;
        verifiedPrices[proposal.identifier][proposal.timestamp] = proposal.value;
        
        // Update latest price if this is newer
        if (proposal.timestamp > latestTimestamp[proposal.identifier]) {
            latestTimestamp[proposal.identifier] = proposal.timestamp;
            latestPrice[proposal.identifier] = proposal.value;
        }
        
        // Return bond to proposer
        dinToken.safeTransfer(proposal.proposer, proposal.bond);
        
        // Update proposer reputation
        proposerReputations[proposal.proposer]++;
        
        emit ProposalAccepted(proposalId, proposal.identifier, proposal.timestamp, proposal.value);
    }

    // ============ Dispute Functions ============
    
    /**
     * @notice Dispute a price proposal
     * @param proposalId The proposal to dispute
     * @param reason Reason for the dispute
     */
    function disputeProposal(uint256 proposalId, string calldata reason) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 disputeId) 
    {
        PriceProposal storage proposal = proposals[proposalId];
        if (proposal.proposer == address(0)) revert InvalidProposalId(proposalId);
        if (proposal.state != ProposalState.PROPOSED) revert ProposalNotActive(proposalId);
        if (proposal.disputeId != 0) revert ProposalAlreadyDisputed(proposalId);
        
        // Check if still within dispute window
        if (block.timestamp > proposal.proposedAt + livenessWindow) {
            revert DisputeWindowClosed(proposalId);
        }
        
        // Transfer dispute bond
        dinToken.safeTransferFrom(msg.sender, address(this), disputeBond);
        
        disputeId = nextDisputeId++;
        proposal.disputeId = disputeId;
        proposal.state = ProposalState.DISPUTED;
        
        Dispute storage dispute = disputes[disputeId];
        dispute.proposalId = proposalId;
        dispute.disputer = msg.sender;
        dispute.disputedAt = block.timestamp;
        dispute.state = DisputeState.ACTIVE;
        dispute.disputeBond = disputeBond;
        dispute.votingDeadline = block.timestamp + votingWindow;
        dispute.reason = reason;
        
        emit ProposalDisputed(proposalId, disputeId, msg.sender, disputeBond, reason);
    }
    
    /**
     * @notice Vote on a dispute
     * @param disputeId The dispute to vote on
     * @param supportsDispute True if supporting the dispute, false if supporting original proposal
     * @param stakeAmount Amount of DIN to stake for this vote
     */
    function voteOnDispute(uint256 disputeId, bool supportsDispute, uint256 stakeAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.disputer == address(0)) revert InvalidDisputeId(disputeId);
        if (dispute.state != DisputeState.ACTIVE) revert DisputeNotActive(disputeId);
        if (block.timestamp > dispute.votingDeadline) revert VotingWindowClosed(disputeId);
        if (dispute.hasVoted[msg.sender]) revert AlreadyVoted(disputeId);
        if (stakeAmount < minVoterStake) revert InsufficientStake(minVoterStake, stakeAmount);
        
        // Transfer voting stake
        dinToken.safeTransferFrom(msg.sender, address(this), stakeAmount);
        
        dispute.hasVoted[msg.sender] = true;
        dispute.voterStakes[msg.sender] = stakeAmount;
        
        if (supportsDispute) {
            dispute.votesAgainst += stakeAmount;
        } else {
            dispute.votesFor += stakeAmount;
        }
        
        // Update voter info
        VoterInfo storage voter = voters[msg.sender];
        voter.stakedAmount += stakeAmount;
        voter.lockedUntil = block.timestamp + votingWindow; // Lock stake during voting
        voter.totalVotes++;
        
        totalStaked += stakeAmount;
        
        emit VoteCast(disputeId, msg.sender, supportsDispute, stakeAmount);
    }
    
    /**
     * @notice Resolve a dispute after voting window
     * @param disputeId The dispute to resolve
     */
    function resolveDispute(uint256 disputeId) external {
        Dispute storage dispute = disputes[disputeId];
        if (dispute.disputer == address(0)) revert InvalidDisputeId(disputeId);
        if (dispute.state != DisputeState.ACTIVE) revert DisputeNotActive(disputeId);
        
        require(block.timestamp > dispute.votingDeadline, "Voting window not closed");
        
        dispute.state = DisputeState.RESOLVED;
        
        PriceProposal storage proposal = proposals[dispute.proposalId];
        bool disputeSuccessful = dispute.votesAgainst > dispute.votesFor;
        
        if (disputeSuccessful) {
            // Dispute won - reject original proposal
            proposal.state = ProposalState.RESOLVED;
            
            // Slash proposer bond and reward disputer
            dinToken.safeTransfer(dispute.disputer, proposal.bond + dispute.disputeBond);
            
            emit BondSlashed(proposal.proposer, proposal.bond, "Proposal disputed successfully");
        } else {
            // Dispute lost - accept original proposal
            proposal.state = ProposalState.ACCEPTED;
            verifiedPrices[proposal.identifier][proposal.timestamp] = proposal.value;
            
            // Update latest price if this is newer
            if (proposal.timestamp > latestTimestamp[proposal.identifier]) {
                latestTimestamp[proposal.identifier] = proposal.timestamp;
                latestPrice[proposal.identifier] = proposal.value;
            }
            
            // Return bonds to original proposer and slash disputer
            dinToken.safeTransfer(proposal.proposer, proposal.bond + dispute.disputeBond);
            
            // Update proposer reputation
            proposerReputations[proposal.proposer]++;
            
            emit BondSlashed(dispute.disputer, dispute.disputeBond, "Dispute unsuccessful");
        }
        
        // Reward successful voters
        _distributeVotingRewards(disputeId, disputeSuccessful);
        
        emit DisputeResolved(disputeId, dispute.proposalId, disputeSuccessful, dispute.votesFor, dispute.votesAgainst);
    }

    // ============ Staking Functions ============
    
    /**
     * @notice Stake DIN tokens for voting rights
     * @param amount Amount of DIN to stake
     */
    function stakeForVoting(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert InsufficientStake(1, 0);
        
        dinToken.safeTransferFrom(msg.sender, address(this), amount);
        
        VoterInfo storage voter = voters[msg.sender];
        voter.stakedAmount += amount;
        totalStaked += amount;
        
        emit StakeDeposited(msg.sender, amount);
    }
    
    /**
     * @notice Withdraw staked DIN tokens
     * @param amount Amount of DIN to withdraw
     */
    function withdrawStake(uint256 amount) external nonReentrant {
        VoterInfo storage voter = voters[msg.sender];
        if (voter.stakedAmount < amount) revert InsufficientStake(amount, voter.stakedAmount);
        if (block.timestamp < voter.lockedUntil) revert StakeLocked(voter.lockedUntil);
        
        voter.stakedAmount -= amount;
        totalStaked -= amount;
        
        dinToken.safeTransfer(msg.sender, amount);
        
        emit StakeWithdrawn(msg.sender, amount);
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Distribute rewards to successful voters
     */
    function _distributeVotingRewards(uint256 /* disputeId */, bool /* disputeSuccessful */) internal {
        // Implementation for distributing rewards to successful voters
        // This is a simplified version - could be enhanced with more sophisticated rewards
        emit RewardsDistributed(0, 0); // Placeholder
    }

    // ============ View Functions ============
    
    /**
     * @notice Get verified price for identifier at timestamp
     */
    function getPrice(bytes32 identifier, uint256 timestamp) 
        external 
        view 
        returns (uint256 price) 
    {
        price = verifiedPrices[identifier][timestamp];
        require(price != 0, "Price not available");
    }
    
    /**
     * @notice Get latest verified price for identifier
     */
    function getLatestPrice(bytes32 identifier) 
        external 
        view 
        returns (uint256 price, uint256 timestamp) 
    {
        timestamp = latestTimestamp[identifier];
        price = latestPrice[identifier];
        require(price != 0, "No price available");
    }
    
    /**
     * @notice Check if price is available for identifier at timestamp
     */
    function hasPrice(bytes32 identifier, uint256 timestamp) 
        external 
        view 
        returns (bool) 
    {
        return verifiedPrices[identifier][timestamp] != 0;
    }
    
    /**
     * @notice Get all supported identifiers
     */
    function getSupportedIdentifiers() external view returns (bytes32[] memory) {
        return identifierList;
    }
    
    /**
     * @notice Get voter information
     */
    function getVoterInfo(address voter) 
        external 
        view 
        returns (VoterInfo memory) 
    {
        return voters[voter];
    }

    // ============ Emergency Functions ============
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
