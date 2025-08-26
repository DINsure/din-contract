// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/security/ReentrancyGuard.sol";

/**
 * @title ProductCatalog
 * @notice Manages products, tranches, and rounds for the DIN protocol
 * @dev Defines products and tranches; announce/open/close sales rounds; expose immutable specs for downstream engines
 * 
 * Payout System:
 * - Buyers purchase insurance coverage by paying a premium (% of purchase amount)
 * - Sellers provide collateral to back the insurance
 * - Only the matched amount (min of buyer demand and seller supply) becomes active coverage
 * - If triggered, the total payout equals the matched purchase amount
 * - Individual payouts are proportional to each buyer's purchase amount
 * - Example: User buys $1000 coverage with 1% premium ($10), gets $1000 payout if triggered
 */
contract ProductCatalog is AccessControl, Pausable, ReentrancyGuard {
    // Role definitions
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // Engine role is for SettlementEngine to advance states at/after maturity
    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE_ROLE");

    // Enums
    enum TriggerType { PRICE_BELOW, PRICE_ABOVE, RELATIVE, BOOLEAN, CUSTOM }
    // Simplified lifecycle: remove redundant MATCHED in favor of direct ACTIVE after matching
    enum RoundState { ANNOUNCED, OPEN, ACTIVE, MATURED, SETTLED, CANCELED }

    // Data structures
    struct Product {
        uint256 productId;
        bytes32 metadataHash; // Off-chain description pointer
        bool active;
        uint256 createdAt;
        uint256 updatedAt;
        uint256[] trancheIds; // Array of tranche IDs for this product
    }

    struct TrancheParams {
        uint256 productId;
        TriggerType triggerType;
        uint256 threshold;
        uint256 maturityTimestamp;
        uint256 premiumRateBps;
        uint256 perAccountMin;
        uint256 perAccountMax;
        uint256 trancheCap;
        uint256 oracleRouteId;
    }

    struct TrancheSpec {
        uint256 trancheId;
        uint256 productId;
        TriggerType triggerType;
        uint256 threshold; // Trigger threshold value
        uint256 maturityTimestamp;
        uint256 premiumRateBps; // Premium rate in basis points (e.g., 100 = 1%)
        uint256 perAccountMin; // Minimum purchase per account
        uint256 perAccountMax; // Maximum purchase per account
        uint256 trancheCap; // Maximum total purchases for this tranche
        uint256 oracleRouteId; // Oracle route identifier
        bool active;
        uint256 createdAt;
        uint256 updatedAt;
        uint256[] roundIds; // Array of round IDs for this tranche
    }

    struct Round {
        uint256 roundId;
        uint256 trancheId;
        uint256 salesStartTime; // When sales window opens
        uint256 salesEndTime; // When sales window closes
        RoundState state;
        uint256 totalBuyerPurchases; // Total amount buyers want to purchase
        uint256 totalSellerCollateral; // Total collateral sellers provide
        uint256 matchedAmount; // Final matched purchase amount (min of buyer demand and seller supply)
        uint256 createdAt;
        uint256 stateChangedAt;
    }

    // Storage
    mapping(uint256 => Product) public products;
    mapping(uint256 => TrancheSpec) public tranches;
    mapping(uint256 => Round) public rounds;
    
    // Counters
    uint256 public nextProductId = 1;
    uint256 public nextTrancheId = 1;
    uint256 public nextRoundId = 1;

    // Active products and tranches lists
    uint256[] public activeProductIds;
    uint256[] public activeTrancheIds;

    // Registry contract reference
    address public registry;

    // Events
    event ProductCreated(uint256 indexed productId, bytes32 metadataHash, address indexed creator);
    event ProductUpdated(uint256 indexed productId, bytes32 metadataHash, address indexed updater);
    event ProductActivated(uint256 indexed productId);
    event ProductDeactivated(uint256 indexed productId);

    event TrancheCreated(
        uint256 indexed trancheId,
        uint256 indexed productId,
        TriggerType triggerType,
        uint256 threshold,
        uint256 maturityTimestamp,
        address indexed creator
    );
    event TrancheUpdated(uint256 indexed trancheId, address indexed updater);
    event TrancheActivated(uint256 indexed trancheId);
    event TrancheDeactivated(uint256 indexed trancheId);

    event RoundAnnounced(
        uint256 indexed roundId,
        uint256 indexed trancheId,
        uint256 salesStartTime,
        uint256 salesEndTime,
        address indexed announcer
    );
    event RoundOpened(uint256 indexed roundId, uint256 indexed trancheId, uint256 timestamp);
    event RoundClosed(uint256 indexed roundId, uint256 indexed trancheId, uint256 timestamp);
    event RoundStateChanged(
        uint256 indexed roundId,
        RoundState indexed oldState,
        RoundState indexed newState,
        uint256 timestamp
    );
    event RoundSubscriptionUpdated(
        uint256 indexed roundId,
        uint256 totalBuyerPurchases,
        uint256 totalSellerCollateral
    );
    
    event RoundMatched(
        uint256 indexed roundId,
        uint256 indexed trancheId,
        uint256 matchedAmount,
        uint256 totalBuyerPurchases,
        uint256 totalSellerCollateral
    );

    // Custom errors
    error ZeroAddress();
    error ProductNotFound(uint256 productId);
    error TrancheNotFound(uint256 trancheId);
    error RoundNotFound(uint256 roundId);
    error ProductNotActive(uint256 productId);
    error TrancheNotActive(uint256 trancheId);
    error InvalidTriggerType();
    error InvalidMaturityTimestamp();
    error InvalidSalesWindow();
    error InvalidRoundState(RoundState current, RoundState required);
    error RoundAlreadyExists(uint256 trancheId);
    error InvalidPremiumRate(uint256 rate);
    error InvalidTrancheParams();
    error UnauthorizedAccess();

    /**
     * @dev Constructor
     * @param _registry Address of the DIN registry contract
     * @param _admin Address to grant admin role
     */
    constructor(address _registry, address _admin) {
        if (_registry == address(0) || _admin == address(0)) revert ZeroAddress();
        
        registry = _registry;
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // ============ Product Management ============

    /**
     * @notice Create a new product
     * @param metadataHash Off-chain metadata hash
     * @return productId The ID of the created product
     */
    function createProduct(bytes32 metadataHash) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
        returns (uint256 productId) 
    {
        require(metadataHash != bytes32(0), "Invalid metadata hash");

        productId = nextProductId++;
        
        Product storage product = products[productId];
        product.productId = productId;
        product.metadataHash = metadataHash;
        product.active = true;
        product.createdAt = block.timestamp;
        product.updatedAt = block.timestamp;

        activeProductIds.push(productId);

        emit ProductCreated(productId, metadataHash, msg.sender);
    }

    /**
     * @notice Update an existing product
     * @param productId The product ID to update
     * @param metadataHash New metadata hash
     */
    function updateProduct(uint256 productId, bytes32 metadataHash) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
    {
        if (products[productId].productId == 0) revert ProductNotFound(productId);
        require(metadataHash != bytes32(0), "Invalid metadata hash");

        Product storage product = products[productId];
        product.metadataHash = metadataHash;
        product.updatedAt = block.timestamp;

        emit ProductUpdated(productId, metadataHash, msg.sender);
    }

    /**
     * @notice Activate/deactivate a product
     * @param productId The product ID
     * @param active New active status
     */
    function setProductActive(uint256 productId, bool active) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
    {
        if (products[productId].productId == 0) revert ProductNotFound(productId);

        Product storage product = products[productId];
        bool wasActive = product.active;
        product.active = active;
        product.updatedAt = block.timestamp;

        if (active && !wasActive) {
            activeProductIds.push(productId);
            emit ProductActivated(productId);
        } else if (!active && wasActive) {
            _removeFromActiveProducts(productId);
            emit ProductDeactivated(productId);
        }
    }

    // ============ Tranche Management ============

    /**
     * @notice Create a new tranche for a product
     * @param params Tranche parameters struct
     * @return trancheId The ID of the created tranche
     */
    function createTranche(TrancheParams memory params) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
        returns (uint256 trancheId) 
    {
        if (products[params.productId].productId == 0) revert ProductNotFound(params.productId);
        if (!products[params.productId].active) revert ProductNotActive(params.productId);
        if (params.maturityTimestamp <= block.timestamp) revert InvalidMaturityTimestamp();
        if (params.premiumRateBps > 10000) revert InvalidPremiumRate(params.premiumRateBps);
        if (params.perAccountMin > params.perAccountMax) revert InvalidTrancheParams();
        if (params.perAccountMax > params.trancheCap) revert InvalidTrancheParams();

        trancheId = nextTrancheId++;

        TrancheSpec storage tranche = tranches[trancheId];
        tranche.trancheId = trancheId;
        tranche.productId = params.productId;
        tranche.triggerType = params.triggerType;
        tranche.threshold = params.threshold;
        tranche.maturityTimestamp = params.maturityTimestamp;
        tranche.premiumRateBps = params.premiumRateBps;
        tranche.perAccountMin = params.perAccountMin;
        tranche.perAccountMax = params.perAccountMax;
        tranche.trancheCap = params.trancheCap;
        tranche.oracleRouteId = params.oracleRouteId;
        tranche.active = true;
        tranche.createdAt = block.timestamp;
        tranche.updatedAt = block.timestamp;

        // Add to product's tranche list
        products[params.productId].trancheIds.push(trancheId);
        activeTrancheIds.push(trancheId);

        emit TrancheCreated(
            trancheId,
            params.productId,
            params.triggerType,
            params.threshold,
            params.maturityTimestamp,
            msg.sender
        );
    }

    /**
     * @notice Update tranche parameters (only before any round is opened)
     * @param trancheId The tranche ID to update
     * @param premiumRateBps New premium rate
     * @param perAccountMin New minimum per account
     * @param perAccountMax New maximum per account
     * @param trancheCap New tranche cap
     */
    function updateTranche(
        uint256 trancheId,
        uint256 premiumRateBps,
        uint256 perAccountMin,
        uint256 perAccountMax,
        uint256 trancheCap
    ) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);
        if (premiumRateBps > 10000) revert InvalidPremiumRate(premiumRateBps);
        if (perAccountMin > perAccountMax) revert InvalidTrancheParams();
        if (perAccountMax > trancheCap) revert InvalidTrancheParams();

        TrancheSpec storage tranche = tranches[trancheId];
        
        // Check if any round has been opened (immutable after first round)
        require(tranche.roundIds.length == 0, "Tranche immutable after first round");

        tranche.premiumRateBps = premiumRateBps;
        tranche.perAccountMin = perAccountMin;
        tranche.perAccountMax = perAccountMax;
        tranche.trancheCap = trancheCap;
        tranche.updatedAt = block.timestamp;

        emit TrancheUpdated(trancheId, msg.sender);
    }

    /**
     * @notice Activate/deactivate a tranche
     * @param trancheId The tranche ID
     * @param active New active status
     */
    function setTrancheActive(uint256 trancheId, bool active) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);

        TrancheSpec storage tranche = tranches[trancheId];
        bool wasActive = tranche.active;
        tranche.active = active;
        tranche.updatedAt = block.timestamp;

        if (active && !wasActive) {
            activeTrancheIds.push(trancheId);
            emit TrancheActivated(trancheId);
        } else if (!active && wasActive) {
            _removeFromActiveTranches(trancheId);
            emit TrancheDeactivated(trancheId);
        }
    }

    // ============ Round Management ============

    /**
     * @notice Announce a new round for a tranche
     * @param trancheId The tranche ID
     * @param salesStartTime When sales open
     * @param salesEndTime When sales close
     * @return roundId The ID of the announced round
     */
    function announceRound(
        uint256 trancheId,
        uint256 salesStartTime,
        uint256 salesEndTime
    )
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
        returns (uint256 roundId) 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);
        if (!tranches[trancheId].active) revert TrancheNotActive(trancheId);
        if (salesStartTime <= block.timestamp) revert InvalidSalesWindow();
        if (salesEndTime <= salesStartTime) revert InvalidSalesWindow();

        // Check if there's already an active round for this tranche
        TrancheSpec storage tranche = tranches[trancheId];
        if (tranche.roundIds.length > 0) {
            uint256 lastRoundId = tranche.roundIds[tranche.roundIds.length - 1];
            RoundState lastState = rounds[lastRoundId].state;
            if (lastState != RoundState.SETTLED && lastState != RoundState.CANCELED) {
                revert RoundAlreadyExists(trancheId);
            }
        }

        roundId = nextRoundId++;

        Round storage round = rounds[roundId];
        round.roundId = roundId;
        round.trancheId = trancheId;
        round.salesStartTime = salesStartTime;
        round.salesEndTime = salesEndTime;
        round.state = RoundState.ANNOUNCED;
        round.createdAt = block.timestamp;
        round.stateChangedAt = block.timestamp;

        // Add to tranche's round list
        tranche.roundIds.push(roundId);

        emit RoundAnnounced(roundId, trancheId, salesStartTime, salesEndTime, msg.sender);
    }

    /**
     * @notice Open a round for sales
     * @param roundId The round ID to open
     */
    function openRound(uint256 roundId) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        
        Round storage round = rounds[roundId];
        if (round.state != RoundState.ANNOUNCED) {
            revert InvalidRoundState(round.state, RoundState.ANNOUNCED);
        }
        if (block.timestamp < round.salesStartTime) {
            revert("Sales window not started");
        }

        round.state = RoundState.OPEN;
        round.stateChangedAt = block.timestamp;

        emit RoundOpened(roundId, round.trancheId, block.timestamp);
        emit RoundStateChanged(roundId, RoundState.ANNOUNCED, RoundState.OPEN, block.timestamp);
    }

    /**
     * @notice Atomically set matched amount and activate coverage
     * @param roundId The round ID
     * @param matchedAmount Final matched purchase amount
     */
    function closeAndMarkMatched(uint256 roundId, uint256 matchedAmount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);

        Round storage round = rounds[roundId];
        if (round.state != RoundState.OPEN) {
            revert InvalidRoundState(round.state, RoundState.OPEN);
        }
        // Ensure sales window has ended
        require(block.timestamp >= round.salesEndTime, "Sales window not ended");

        // Set matched amount and move to ACTIVE coverage immediately after matching
        round.matchedAmount = matchedAmount;
        RoundState old = round.state;
        round.state = RoundState.ACTIVE;
        round.stateChangedAt = block.timestamp;

        emit RoundClosed(roundId, round.trancheId, block.timestamp);
        emit RoundMatched(roundId, round.trancheId, matchedAmount, round.totalBuyerPurchases, round.totalSellerCollateral);
        emit RoundStateChanged(roundId, old, RoundState.ACTIVE, block.timestamp);
    }

    /**
     * @notice Update round state (called by other protocol contracts)
     * @param roundId The round ID
     * @param newState The new state
     */
    function updateRoundState(uint256 roundId, RoundState newState) 
        external 
        whenNotPaused 
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        Round storage round = rounds[roundId];
        RoundState oldState = round.state;

        if (newState == RoundState.ACTIVE) {
            if (!hasRole(OPERATOR_ROLE, msg.sender)) revert UnauthorizedAccess();
            if (oldState != RoundState.OPEN) revert InvalidRoundState(oldState, RoundState.OPEN);
        } else if (newState == RoundState.MATURED) {
            if (!hasRole(ENGINE_ROLE, msg.sender)) revert UnauthorizedAccess();
            if (oldState != RoundState.ACTIVE) revert InvalidRoundState(oldState, RoundState.ACTIVE);
        } else if (newState == RoundState.SETTLED) {
            if (!hasRole(ENGINE_ROLE, msg.sender)) revert UnauthorizedAccess();
            if (oldState != RoundState.MATURED) revert InvalidRoundState(oldState, RoundState.MATURED);
        } else {
            // Disallow other transitions via this function
            revert UnauthorizedAccess();
        }

        round.state = newState;
        round.stateChangedAt = block.timestamp;
        emit RoundStateChanged(roundId, oldState, newState, block.timestamp);
    }

    /**
     * @notice Update round subscription counters
     * @param roundId The round ID
     * @param totalBuyerPurchases Total amount buyers want to purchase
     * @param totalSellerCollateral Total seller collateral
     */
    function updateRoundSubscription(
        uint256 roundId,
        uint256 totalBuyerPurchases,
        uint256 totalSellerCollateral
    ) 
        external 
        whenNotPaused 
    {
        // TODO: Add access control for RoundManager
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        
        Round storage round = rounds[roundId];
        round.totalBuyerPurchases = totalBuyerPurchases;
        round.totalSellerCollateral = totalSellerCollateral;

        emit RoundSubscriptionUpdated(roundId, totalBuyerPurchases, totalSellerCollateral);
    }

    // ============ View Functions ============

    /**
     * @notice Get active product IDs
     * @return Array of active product IDs
     */
    function getActiveProducts() external view returns (uint256[] memory) {
        return activeProductIds;
    }

    /**
     * @notice Get active tranche IDs
     * @return Array of active tranche IDs
     */
    function getActiveTranches() external view returns (uint256[] memory) {
        return activeTrancheIds;
    }

    /**
     * @notice Get tranche IDs for a product
     * @param productId The product ID
     * @return Array of tranche IDs
     */
    function getProductTranches(uint256 productId) 
        external 
        view 
        returns (uint256[] memory) 
    {
        if (products[productId].productId == 0) revert ProductNotFound(productId);
        return products[productId].trancheIds;
    }

    /**
     * @notice Get round IDs for a tranche
     * @param trancheId The tranche ID
     * @return Array of round IDs
     */
    function getTrancheRounds(uint256 trancheId) 
        external 
        view 
        returns (uint256[] memory) 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);
        return tranches[trancheId].roundIds;
    }

    /**
     * @notice Get full product details
     * @param productId The product ID
     * @return product The product struct
     */
    function getProduct(uint256 productId) 
        external 
        view 
        returns (Product memory product) 
    {
        if (products[productId].productId == 0) revert ProductNotFound(productId);
        return products[productId];
    }

    /**
     * @notice Get full tranche details
     * @param trancheId The tranche ID
     * @return tranche The tranche struct
     */
    function getTranche(uint256 trancheId) 
        external 
        view 
        returns (TrancheSpec memory tranche) 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);
        return tranches[trancheId];
    }

    /**
     * @notice Get full round details
     * @param roundId The round ID
     * @return round The round struct
     */
    function getRound(uint256 roundId) 
        external 
        view 
        returns (Round memory round) 
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        return rounds[roundId];
    }

    /**
     * @notice Calculate premium amount for a purchase
     * @param trancheId The tranche ID
     * @param purchaseAmount The amount to purchase
     * @return premiumAmount The premium to pay (purchaseAmount * premiumRateBps / 10000)
     */
    function calculatePremium(uint256 trancheId, uint256 purchaseAmount) 
        external 
        view 
        returns (uint256 premiumAmount) 
    {
        if (tranches[trancheId].trancheId == 0) revert TrancheNotFound(trancheId);
        TrancheSpec storage tranche = tranches[trancheId];
        return (purchaseAmount * tranche.premiumRateBps) / 10000;
    }

    /**
     * @notice Calculate payout amount for a user if triggered
     * @param roundId The round ID
     * @param userPurchaseAmount The user's purchase amount
     * @return payoutAmount The user's payout (proportional to their purchase)
     */
    function calculateUserPayout(uint256 roundId, uint256 userPurchaseAmount) 
        external 
        view 
        returns (uint256 payoutAmount) 
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        Round storage round = rounds[roundId];
        
        if (round.matchedAmount == 0) {
            return 0; // No matched amount yet
        }
        
        // User gets proportional payout based on their purchase percentage
        // If total matched amount is the coverage, user gets: (userPurchase / matchedAmount) * matchedAmount = userPurchase
        // This means users get back their full purchase amount if triggered
        return userPurchaseAmount;
    }

    // ============ Internal Functions ============

    /**
     * @dev Remove product ID from active products array
     */
    function _removeFromActiveProducts(uint256 productId) internal {
        for (uint256 i = 0; i < activeProductIds.length; i++) {
            if (activeProductIds[i] == productId) {
                activeProductIds[i] = activeProductIds[activeProductIds.length - 1];
                activeProductIds.pop();
                break;
            }
        }
    }

    /**
     * @dev Remove tranche ID from active tranches array
     */
    function _removeFromActiveTranches(uint256 trancheId) internal {
        for (uint256 i = 0; i < activeTrancheIds.length; i++) {
            if (activeTrancheIds[i] == trancheId) {
                activeTrancheIds[i] = activeTrancheIds[activeTrancheIds.length - 1];
                activeTrancheIds.pop();
                break;
            }
        }
    }

    // ============ Emergency Functions ============

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency cancel a round
     * @param roundId The round ID to cancel
     */
    function emergencyCancelRound(uint256 roundId) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (rounds[roundId].roundId == 0) revert RoundNotFound(roundId);
        
        Round storage round = rounds[roundId];
        RoundState oldState = round.state;
        round.state = RoundState.CANCELED;
        round.stateChangedAt = block.timestamp;

        emit RoundStateChanged(roundId, oldState, RoundState.CANCELED, block.timestamp);
    }
}
