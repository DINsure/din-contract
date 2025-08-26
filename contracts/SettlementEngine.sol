// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "./interfaces/IDinRegistry.sol";
import "./interfaces/IProductCatalog.sol";
import "./oracles/OracleRouter.sol";
import "./TranchePoolCore.sol";

/**
 * @title SettlementEngine
 * @notice Handles oracle-based settlement, outcome resolution, and payouts for insurance rounds
 * @dev Orchestrates settlement at maturity with oracle integration and dispute handling
 */
contract SettlementEngine is AccessControl, Pausable {
    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Enums ============
    enum TriggerType { PRICE_BELOW, PRICE_ABOVE, RELATIVE, BOOLEAN, CUSTOM }
    enum OracleStatus { NONE, REQUESTED, RESOLVED, DISPUTED }
    enum RoundState { ANNOUNCED, OPEN, MATCHED, ACTIVE, MATURED, SETTLED, CANCELED }

    // ============ Structs ============
    struct SettlementInfo {
        uint256 roundId;
        address tranchePool;
        uint256 trancheId;
        OracleStatus oracleStatus;
        uint256 observationTimestamp;
        uint256 oracleResult;
        bool triggered;
        bool settled;
        uint256 totalPayouts;
        uint256 livenessDeadline;
        address resolver;
    }

    // Legacy oracle route struct - kept for backward compatibility
    struct OracleRoute {
        address primaryOracle;
        address[] fallbackOracles;
        uint256 heartbeatThreshold;
        uint8 decimals;
        bool active;
    }

    // ============ Storage ============
    IDinRegistry public immutable registry;
    OracleRouter public immutable oracleRouter;
    
    // Settlement tracking
    mapping(uint256 => SettlementInfo) public settlements; // roundId => settlement info
    mapping(uint256 => OracleRoute) public oracleRoutes; // routeId => oracle route
    
    // Parameters
    uint256 public livenessWindow = 10 minutes; // Dispute window after observation. Settelement is available after this window.
    uint256 public disputeWindow = 24 hours; // How long disputes are open
    
    // ============ Events ============
    event OracleObservationRequested(
        uint256 indexed roundId,
        uint256 indexed trancheId,
        uint256 indexed oracleRouteId,
        address tranchePool,
        uint256 timestamp
    );
    
    event OracleResultReceived(
        uint256 indexed roundId,
        uint256 result,
        uint256 timestamp,
        address indexed oracle,
        bool triggered
    );
    
    event SettlementFinalized(
        uint256 indexed roundId,
        uint256 indexed trancheId,
        bool triggered,
        uint256 totalPayouts,
        uint256 timestamp
    );
    
    event BuyerPaid(uint256 indexed roundId, address indexed buyer, uint256 payout);
    event CollateralReleased(uint256 indexed roundId, address indexed seller, uint256 amount);
    event SettlementDisputed(uint256 indexed roundId, address indexed disputer, uint256 timestamp);
    event OracleRouteConfigured(uint256 indexed routeId, address primaryOracle, uint8 decimals);

    // ============ Custom Errors ============
    error ZeroAddress();
    error InvalidRound(uint256 roundId);
    error SettlementNotReady();
    error AlreadySettled();
    error OracleNotConfigured();
    error InvalidOracleResult();
    error LivenessWindowNotPassed();
    error DisputeWindowClosed();
    error UnauthorizedOracle();
    error OracleRequestFailed();

    // ============ Constructor ============
    constructor(address _registry, address _oracleRouter, address _admin) {
        if (_registry == address(0) || _oracleRouter == address(0) || _admin == address(0)) revert ZeroAddress();
        
        registry = IDinRegistry(_registry);
        oracleRouter = OracleRouter(_oracleRouter);
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _admin);
    }

    // ============ Oracle Route Management ============
    
    /**
     * @notice Configure oracle route for price feeds
     * @param routeId The route identifier
     * @param primaryOracle Primary oracle address
     * @param fallbackOracles Array of fallback oracle addresses
     * @param heartbeatThreshold Maximum staleness threshold (seconds)
     * @param decimals Price decimals
     */
    function configureOracleRoute(
        uint256 routeId,
        address primaryOracle,
        address[] calldata fallbackOracles,
        uint256 heartbeatThreshold,
        uint8 decimals
    ) external onlyRole(ADMIN_ROLE) {
        require(primaryOracle != address(0), "Invalid primary oracle");
        
        oracleRoutes[routeId] = OracleRoute({
            primaryOracle: primaryOracle,
            fallbackOracles: fallbackOracles,
            heartbeatThreshold: heartbeatThreshold,
            decimals: decimals,
            active: true
        });
        
        emit OracleRouteConfigured(routeId, primaryOracle, decimals);
    }

    // ============ Settlement Functions ============
    
    /**
     * @notice Request oracle observation at maturity using unified Oracle Router
     * @param roundId The round requesting settlement
     * @param tranchePool The tranche pool contract address
     * @param priceIdentifier The price identifier for oracle lookup (e.g., keccak256("BTC-USDT"))
     */
    function requestOracleObservation(
        uint256 roundId,
        address tranchePool,
        bytes32 priceIdentifier
    ) external onlyRole(KEEPER_ROLE) whenNotPaused {
        require(tranchePool != address(0), "Invalid tranche pool");
        
        // Get tranche information
        TranchePoolCore pool = TranchePoolCore(tranchePool);
        TranchePoolCore.TrancheInfo memory trancheInfo = pool.getTrancheInfo();
        
        // Get tranche details from ProductCatalog
        IProductCatalog catalog = IProductCatalog(trancheInfo.productCatalog);
        IProductCatalog.TrancheSpec memory tranche = catalog.getTranche(trancheInfo.trancheId);
        
        // Check if at maturity
        require(block.timestamp >= tranche.maturityTimestamp, "Not at maturity yet");
        
        // Check if already requested
        if (settlements[roundId].oracleStatus != OracleStatus.NONE) {
            revert SettlementNotReady();
        }

        // Emit observation request event
        emit OracleObservationRequested(
            roundId,
            trancheInfo.trancheId,
            uint256(priceIdentifier), // Use priceIdentifier as route identifier
            tranchePool,
            block.timestamp
        );
        
        // Get price from OracleRouter
        try oracleRouter.getPrice(priceIdentifier) returns (OracleRouter.PriceResult memory result) {
            if (!result.valid) {
                revert OracleRequestFailed();
            }
            
            // Evaluate trigger condition
            bool triggered = _evaluateTrigger(TriggerType(uint256(tranche.triggerType)), tranche.threshold, result.price);
            
            // Initialize settlement info with oracle result
            settlements[roundId] = SettlementInfo({
                roundId: roundId,
                tranchePool: tranchePool,
                trancheId: trancheInfo.trancheId,
                oracleStatus: OracleStatus.RESOLVED,
                observationTimestamp: result.timestamp,
                oracleResult: result.price,
                triggered: triggered,
                settled: false,
                totalPayouts: 0,
                livenessDeadline: block.timestamp + livenessWindow,
                resolver: msg.sender
            });
            
            // Mark round MATURED in the ProductCatalog (SSoT)
            catalog.updateRoundState(roundId, IProductCatalog.RoundState.MATURED);
            
            // Emit oracle result received event
            emit OracleResultReceived(roundId, result.price, result.timestamp, msg.sender, triggered);
            
        } catch {
            revert OracleRequestFailed();
        }
    }
    
    /**
     * @notice Submit oracle result (called by authorized oracles)
     * @param roundId The round to submit result for
     * @param result The oracle result (price/value)
     */
    function submitOracleResult(
        uint256 roundId,
        uint256 result
    ) external onlyRole(ORACLE_ROLE) whenNotPaused {
        SettlementInfo storage settlement = settlements[roundId];
        
        if (settlement.oracleStatus != OracleStatus.REQUESTED) {
            revert SettlementNotReady();
        }
        
        // Get tranche information to evaluate trigger
        TranchePoolCore pool = TranchePoolCore(settlement.tranchePool);
        TranchePoolCore.TrancheInfo memory trancheInfo = pool.getTrancheInfo();
        
        IProductCatalog catalog = IProductCatalog(trancheInfo.productCatalog);
        IProductCatalog.TrancheSpec memory tranche = catalog.getTranche(settlement.trancheId);
        
        // Store oracle result
        settlement.oracleResult = result;
        settlement.oracleStatus = OracleStatus.RESOLVED;
        
        // Evaluate trigger condition
        bool triggered = _evaluateTrigger(TriggerType(uint256(tranche.triggerType)), tranche.threshold, result);
        settlement.triggered = triggered;
        
        emit OracleResultReceived(roundId, result, block.timestamp, msg.sender, triggered);
    }
    
    /**
     * @notice Finalize settlement after liveness window
     * @param roundId The round to settle
     */
    function finalizeSettlement(uint256 roundId) external onlyRole(KEEPER_ROLE) whenNotPaused {
        SettlementInfo storage settlement = settlements[roundId];
        
        if (settlement.oracleStatus != OracleStatus.RESOLVED) {
            revert SettlementNotReady();
        }
        if (settlement.settled) {
            revert AlreadySettled();
        }
        if (block.timestamp < settlement.livenessDeadline) {
            revert LivenessWindowNotPassed();
        }
        
        settlement.settled = true;
        
        TranchePoolCore pool = TranchePoolCore(settlement.tranchePool);
        uint256 totalPayouts = 0;
        
        if (settlement.triggered) {
            // Execute buyer payouts (buyers get their purchase amounts)
            // Sellers lose their collateral but KEEP premiums and yield benefits via NAV
            totalPayouts = pool.executeBuyerPayouts(roundId);
            settlement.totalPayouts = totalPayouts;
        } else {
            // Release collateral to sellers (sellers get collateral + premiums + any yield)
            pool.releaseSellerCollateral(roundId);
        }
        
        // Update catalog round state → SETTLED
        TranchePoolCore.TrancheInfo memory trancheInfo = pool.getTrancheInfo();
        IProductCatalog catalog = IProductCatalog(trancheInfo.productCatalog);
        catalog.updateRoundState(roundId, IProductCatalog.RoundState.SETTLED);
        
        emit SettlementFinalized(
            roundId,
            settlement.trancheId,
            settlement.triggered,
            totalPayouts,
            block.timestamp
        );
    }

    // ============ Dispute Functions ============
    
    /**
     * @notice Dispute an oracle result (within dispute window)
     * @param roundId The round to dispute
     */
    function disputeOracleResult(uint256 roundId) external whenNotPaused {
        SettlementInfo storage settlement = settlements[roundId];
        
        if (settlement.oracleStatus != OracleStatus.RESOLVED) {
            revert SettlementNotReady();
        }
        if (settlement.settled) {
            revert AlreadySettled();
        }
        if (block.timestamp > settlement.livenessDeadline + disputeWindow) {
            revert DisputeWindowClosed();
        }
        
        settlement.oracleStatus = OracleStatus.DISPUTED;
        
        emit SettlementDisputed(roundId, msg.sender, block.timestamp);
    }
    
    /**
     * @notice Resolve dispute (admin only)
     * @param roundId The round to resolve
     * @param newResult The corrected oracle result
     */
    function resolveDispute(
        uint256 roundId,
        uint256 newResult
    ) external onlyRole(ADMIN_ROLE) {
        SettlementInfo storage settlement = settlements[roundId];
        
        require(settlement.oracleStatus == OracleStatus.DISPUTED, "No active dispute");
        require(!settlement.settled, "Already settled");
        
        // Update result and re-evaluate trigger
        settlement.oracleResult = newResult;
        settlement.oracleStatus = OracleStatus.RESOLVED;
        
        // Get tranche info to re-evaluate trigger
        TranchePoolCore pool = TranchePoolCore(settlement.tranchePool);
        TranchePoolCore.TrancheInfo memory trancheInfo = pool.getTrancheInfo();
        
        IProductCatalog catalog = IProductCatalog(trancheInfo.productCatalog);
        IProductCatalog.TrancheSpec memory tranche = catalog.getTranche(settlement.trancheId);
        
        bool triggered = _evaluateTrigger(TriggerType(uint256(tranche.triggerType)), tranche.threshold, newResult);
        settlement.triggered = triggered;
        
        // Reset liveness deadline
        settlement.livenessDeadline = block.timestamp + livenessWindow;
        
        emit OracleResultReceived(roundId, newResult, block.timestamp, msg.sender, triggered);
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Evaluate trigger condition based on oracle result
     * @param triggerType The type of trigger condition
     * @param threshold The trigger threshold
     * @param oracleResult The oracle result
     * @return triggered Whether the condition is triggered
     */
    function _evaluateTrigger(
        TriggerType triggerType,
        uint256 threshold,
        uint256 oracleResult
    ) internal pure returns (bool triggered) {
        if (triggerType == TriggerType.PRICE_BELOW) {
            // Convert threshold from 18 decimals to 8 decimals for comparison with oracle price
            // threshold is stored as ETH format (18 decimals), both Orakl and DINO oracles use 8 decimals
            uint256 normalizedThreshold = threshold / 1e10; // Convert 18 decimals to 8 decimals
            return oracleResult < normalizedThreshold;
        } else if (triggerType == TriggerType.PRICE_ABOVE) {
            // Convert threshold from 18 decimals to 8 decimals for comparison with oracle price
            uint256 normalizedThreshold = threshold / 1e10; // Convert 18 decimals to 8 decimals
            return oracleResult > normalizedThreshold;
        } else if (triggerType == TriggerType.RELATIVE) {
            // For relative triggers, custom logic would go here
            return false; // Placeholder - implement later
        } else if (triggerType == TriggerType.BOOLEAN) {
            // For boolean triggers, oracle result is 0 or 1
            return oracleResult == 1;
        } else {
            // Custom trigger type
            return false; // Placeholder - implement later
        }
    }

    // ============ View Functions ============
    
    /**
     * @notice Get settlement information
     * @param roundId The round ID
     */
    function getSettlementInfo(uint256 roundId) external view returns (SettlementInfo memory) {
        return settlements[roundId];
    }
    
    /**
     * @notice Get oracle route information
     * @param routeId The route ID
     */
    function getOracleRoute(uint256 routeId) external view returns (OracleRoute memory) {
        return oracleRoutes[routeId];
    }
    
    /**
     * @notice Check if settlement is ready for finalization
     * @param roundId The round ID
     */
    function canFinalize(uint256 roundId) external view returns (bool) {
        SettlementInfo storage settlement = settlements[roundId];
        return settlement.oracleStatus == OracleStatus.RESOLVED &&
               !settlement.settled &&
               block.timestamp >= settlement.livenessDeadline;
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set liveness window (admin only)
     * @param newWindow New liveness window in seconds
     */
    function setLivenessWindow(uint256 newWindow) external onlyRole(ADMIN_ROLE) {
        require(newWindow >= 1 minutes && newWindow <= 2 days, "Invalid window");
        livenessWindow = newWindow;
    }
    
    /**
     * @notice Set dispute window (admin only)
     * @param newWindow New dispute window in seconds
     */
    function setDisputeWindow(uint256 newWindow) external onlyRole(ADMIN_ROLE) {
        require(newWindow >= 1 minutes && newWindow <= 7 days, "Invalid window");
        disputeWindow = newWindow;
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Emergency unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
