// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/security/ReentrancyGuard.sol";
import "@kaiachain/contracts/token/ERC20/IERC20.sol";
import "@kaiachain/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDinRegistry.sol";
import "./interfaces/IProductCatalog.sol";
import "./interfaces/IInsuranceToken.sol";

interface IYieldRouter {
    function registerPool(address poolAddress) external;
}

/**
 * @title TranchePoolCore
 * @notice Core pool contract managing rounds, orders, collateral, and premium distribution
 * @dev Integrates RoundManager + PremiumEngine + TranchePool functionality for a specific tranche
 */
contract TranchePoolCore is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Enums ============
    enum RoundState { ANNOUNCED, OPEN, ACTIVE, MATURED, SETTLED, CANCELED }

    // ============ Structs ============
    struct TrancheInfo {
        uint256 trancheId;
        uint256 productId;
        address productCatalog;
        bool active;
    }

    struct RoundEconomics {
        uint256 totalBuyerPurchases;
        uint256 totalSellerCollateral;
        uint256 matchedAmount;
        uint256 lockedCollateral;
        uint256 premiumPool;
        uint256 protocolFees;
    }

    struct BuyerOrder {
        address buyer;
        uint256 purchaseAmount;
        uint256 premiumPaid;
        uint256 insuranceTokenId;
        bool filled;
        bool refunded;
        uint256 timestamp;
        uint256 refundAmount; // Amount to refund (for partial fills)
    }

    struct SellerPosition {
        address seller;
        uint256 collateralAmount;
        uint256 sharesMinted;
        uint256 premiumEarned;
        uint256 filledCollateral; // portion of collateral that was matched
        uint256 lockedSharesAssigned; // shares locked corresponding to filledCollateral
        bool filled;
        bool refunded;
        uint256 timestamp;
        uint256 refundAmount; // Amount to refund (for partial fills)
        uint256 sharesToBurn; // Shares to burn (for partial fills)
    }

    struct PoolAccounting {
        uint256 totalAssets;        // Total USDT in pool
        uint256 totalShares;        // Total seller shares
        uint256 lockedAssets;       // Assets locked in active rounds
        uint256 premiumReserve;     // Accumulated premiums
        uint256 navPerShare;        // Net Asset Value per share (18 decimals)
        uint256 lastUpdateTime;
        uint256 yieldDeposited;     // Amount deposited to YieldRouter
        uint256 yieldEarned;        // Total yield earned from YieldRouter
    }

    // ============ Storage ============
    
    // Core references
    IDinRegistry public immutable registry;
    TrancheInfo public trancheInfo;
    PoolAccounting public poolAccounting;
    
    // Contracts
    IERC20 public immutable usdtToken;
    IInsuranceToken public insuranceToken;
    address public settlementEngine;
    address public feeTreasury;
    address public yieldRouter;
    
    // Round economics (no lifecycle/state; lifecycle is in ProductCatalog)
    mapping(uint256 => RoundEconomics) private roundEconomics;
    mapping(uint256 => mapping(address => BuyerOrder)) public buyerOrders;
    mapping(uint256 => mapping(address => SellerPosition)) public sellerPositions;
    mapping(uint256 => address[]) public roundBuyers;
    mapping(uint256 => address[]) public roundSellers;
    mapping(uint256 => bool) public frozen; // optional local safety brake
    
    // Seller shares
    mapping(address => uint256) public shareBalances;
    mapping(address => uint256) public lockedShares; // Shares locked in active rounds
    
    uint256 public protocolFeeBps = 1000; // 10% default

    // ============ Events ============
    
    // Round Management Events
    event BuyerOrderPlaced(uint256 indexed roundId, address indexed buyer, uint256 purchaseAmount, uint256 premiumPaid, uint256 tokenId);
    event SellerPositionCreated(uint256 indexed roundId, address indexed seller, uint256 collateralAmount, uint256 sharesMinted);
    event RoundMatched(uint256 indexed roundId, uint256 matchedAmount, uint256 totalBuyers, uint256 totalSellers);
    event RefundProcessed(uint256 indexed roundId, address indexed user, uint256 amount, bool isBuyer);
    
    // Premium and Pool Events
    event PremiumCalculated(uint256 indexed roundId, address indexed buyer, uint256 purchaseAmount, uint256 premium);
    event PremiumDistributed(uint256 indexed roundId, uint256 sellerShare, uint256 protocolFee);
    event CollateralDeposited(address indexed seller, uint256 amount, uint256 sharesMinted);

    event NAVUpdated(uint256 oldNavPerShare, uint256 newNavPerShare, uint256 timestamp);
    event PremiumTransferred(uint256 indexed roundId, address indexed seller, uint256 amount);
    event CollateralReleased(uint256 indexed roundId, address indexed seller, uint256 amount);
    
    // Freeze/Unfreeze Events
    event RoundFrozen(uint256 indexed roundId, address indexed admin, uint256 timestamp);
    event RoundUnfrozen(uint256 indexed roundId, address indexed admin, uint256 timestamp);
    
    // Parameter Update Events
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps, address indexed admin, uint256 timestamp);
    event FeeTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury, address indexed admin, uint256 timestamp);
    
    // Yield Management Events
    event FundsMovedToYield(uint256 amount, address indexed yieldRouter, uint256 timestamp);
    event FundsReturnedFromYield(uint256 returnedAmount, uint256 yieldEarned, uint256 timestamp);
    event YieldRouterUpdated(address indexed oldRouter, address indexed newRouter, address indexed admin);

    // ============ Custom Errors ============
    error ZeroAddress();
    error InvalidAmount();
    error InvalidRound(uint256 roundId);
    error InvalidRoundState(RoundState current, RoundState required);
    error SalesWindowNotOpen();
    error InsufficientCollateral();
    error InsufficientShares();
    error OrderAlreadyExists();
    error AccountLimitExceeded();
    error TrancheLimitExceeded();
    error TrancheNotActive();
    error UnauthorizedSettlement();
    error Unauthorized();
    error RoundIsFrozen();
    error YieldRouterNotSet();
    error InsufficientAvailableFunds();
    error InvalidYieldReturn();

    // ============ Constructor ============
    
    constructor(
        address _registry,
        TrancheInfo memory _trancheInfo,
        address _insuranceToken,
        address _admin
    ) {
        if (_registry == address(0) || _insuranceToken == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        
        registry = IDinRegistry(_registry);
        trancheInfo = _trancheInfo;
        insuranceToken = IInsuranceToken(_insuranceToken);
        
        // Get USDT token from registry
        usdtToken = IERC20(registry.getUSDTToken());
        feeTreasury = registry.getFeeTreasury();
        
        // Initialize pool accounting
        poolAccounting = PoolAccounting({
            totalAssets: 0,
            totalShares: 0,
            lockedAssets: 0,
            premiumReserve: 0,
            navPerShare: 1e18, // Start at 1:1 ratio
            lastUpdateTime: block.timestamp,
            yieldDeposited: 0,
            yieldEarned: 0
        });
        
        // Auto-register with YieldRouter if available
        address yieldRouterAddress = registry.getYieldRouter();
        if (yieldRouterAddress != address(0)) {
            yieldRouter = yieldRouterAddress;
            try IYieldRouter(yieldRouterAddress).registerPool(address(this)) {
                // Registration successful
            } catch {
                // Registration failed, but don't revert deployment
                // YieldRouter can be set later via setYieldRouter
            }
        }
        
        // Grant roles
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // ============ Modifiers ============
    
    modifier onlyTrancheActive() {
        if (!trancheInfo.active) revert TrancheNotActive();
        _;
    }

    modifier onlySettlementEngine() {
        if (msg.sender != settlementEngine) revert UnauthorizedSettlement();
        _;
    }
    
    modifier onlyUnfrozenRound(uint256 roundId) {
        if (frozen[roundId]) revert RoundIsFrozen();
        _;
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set settlement engine address (admin only)
     * @param _settlementEngine Address of the settlement engine
     */
    function setSettlementEngine(address _settlementEngine) external onlyRole(ADMIN_ROLE) {
        settlementEngine = _settlementEngine;
        _grantRole(SETTLEMENT_ROLE, _settlementEngine);
    }

    /**
     * @notice Update protocol fee basis points (admin only)
     * @param newFeeBps New protocol fee in basis points (max 5000 = 50%)
     */
    function updateProtocolFeeBps(uint256 newFeeBps) external onlyRole(ADMIN_ROLE) {
        require(newFeeBps <= 5000, "Fee too high"); // Max 50%
        uint256 oldFeeBps = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        
        emit ProtocolFeeUpdated(oldFeeBps, newFeeBps, msg.sender, block.timestamp);
    }

    /**
     * @notice Update fee treasury address (admin only)
     * @param newFeeTreasury New fee treasury address
     */
    function setFeeTreasury(address newFeeTreasury) external onlyRole(ADMIN_ROLE) {
        if (newFeeTreasury == address(0)) revert ZeroAddress();
        address oldFeeTreasury = feeTreasury;
        feeTreasury = newFeeTreasury;
        
        emit FeeTreasuryUpdated(oldFeeTreasury, newFeeTreasury, msg.sender, block.timestamp);
    }

    /**
     * @notice Set yield router address (admin only)
     * @param newYieldRouter New yield router address
     */
    function setYieldRouter(address newYieldRouter) external onlyRole(ADMIN_ROLE) {
        if (newYieldRouter == address(0)) revert ZeroAddress();
        address oldYieldRouter = yieldRouter;
        yieldRouter = newYieldRouter;
        
        emit YieldRouterUpdated(oldYieldRouter, newYieldRouter, msg.sender);
    }

    // No round lifecycle functions here; lifecycle is managed in ProductCatalog

    // ============ Catalog Guards ============

    function _requireOpenSales(uint256 roundId) internal view {
        IProductCatalog.Round memory r = IProductCatalog(trancheInfo.productCatalog).getRound(roundId);
        if (r.trancheId != trancheInfo.trancheId) revert InvalidRound(roundId);
        if (r.state != IProductCatalog.RoundState.OPEN) revert InvalidRoundState(RoundState(uint256(r.state)), RoundState.OPEN);
        if (block.timestamp < r.salesStartTime || block.timestamp > r.salesEndTime) revert SalesWindowNotOpen();
    }

    // ============ Buyer Order Functions (RoundManager + PremiumEngine) ============
    
    /**
     * @notice Place a buyer order for insurance coverage
     * @param roundId The round to buy coverage in
     * @param purchaseAmount Amount of coverage to purchase
     */
    function placeBuyerOrder(
        uint256 roundId,
        uint256 purchaseAmount
    ) external onlyUnfrozenRound(roundId) nonReentrant {
        _requireOpenSales(roundId);
        if (purchaseAmount == 0) revert InvalidAmount();
        // Enforce tranche limits from catalog
        IProductCatalog.TrancheSpec memory t = IProductCatalog(trancheInfo.productCatalog).getTranche(trancheInfo.trancheId);
        if (purchaseAmount < t.perAccountMin || purchaseAmount > t.perAccountMax) revert AccountLimitExceeded();
        if (buyerOrders[roundId][msg.sender].buyer != address(0)) {
            revert OrderAlreadyExists();
        }
        // Check tranche cap
        RoundEconomics storage econ = roundEconomics[roundId];
        if (econ.totalBuyerPurchases + purchaseAmount > t.trancheCap) revert TrancheLimitExceeded();
        
        // Calculate premium from catalog tranche spec
        uint256 premium = (purchaseAmount * t.premiumRateBps) / 10000;
        
        // Transfer premium from buyer
        usdtToken.safeTransferFrom(msg.sender, address(this), premium);
        
        // Mint insurance token
        uint256 tokenId = insuranceToken.mintInsuranceToken(
            msg.sender,
            trancheInfo.trancheId,
            roundId,
            purchaseAmount
        );
        
        // Record buyer order
        buyerOrders[roundId][msg.sender] = BuyerOrder({
            buyer: msg.sender,
            purchaseAmount: purchaseAmount,
            premiumPaid: premium,
            insuranceTokenId: tokenId,
            filled: false,
            refunded: false,
            timestamp: block.timestamp,
            refundAmount: 0
        });
        
        roundBuyers[roundId].push(msg.sender);
        econ.totalBuyerPurchases += purchaseAmount;
        econ.premiumPool += premium;
        
        emit BuyerOrderPlaced(roundId, msg.sender, purchaseAmount, premium, tokenId);
        emit PremiumCalculated(roundId, msg.sender, purchaseAmount, premium);
    }
    
    /**
     * @notice Calculate premium for a purchase amount
     * @param purchaseAmount The amount to purchase coverage for
     * @return premium The premium to pay
     */
    function calculatePremium(uint256 purchaseAmount) public view returns (uint256 premium) {
        IProductCatalog.TrancheSpec memory t = IProductCatalog(trancheInfo.productCatalog).getTranche(trancheInfo.trancheId);
        return (purchaseAmount * t.premiumRateBps) / 10000;
    }

    // ============ Seller Position Functions (TranchePool) ============
    
    /**
     * @notice Deposit collateral as a seller to back insurance
     * @param roundId The round to provide collateral for
     * @param collateralAmount Amount of USDT to deposit
     */
    function depositCollateral(
        uint256 roundId,
        uint256 collateralAmount
    ) external onlyUnfrozenRound(roundId) nonReentrant {
        _requireOpenSales(roundId);
        if (collateralAmount == 0) revert InvalidAmount();
        if (sellerPositions[roundId][msg.sender].seller != address(0)) {
            revert OrderAlreadyExists();
        }
        
        // Transfer collateral from seller
        usdtToken.safeTransferFrom(msg.sender, address(this), collateralAmount);
        
        // Calculate shares to mint (based on current NAV)
        uint256 sharesMinted = (collateralAmount * 1e18) / poolAccounting.navPerShare;
        
        // Update pool accounting
        poolAccounting.totalAssets += collateralAmount;
        poolAccounting.totalShares += sharesMinted;
        shareBalances[msg.sender] += sharesMinted;
        
        // Record seller position
        sellerPositions[roundId][msg.sender] = SellerPosition({
            seller: msg.sender,
            collateralAmount: collateralAmount,
            sharesMinted: sharesMinted,
            premiumEarned: 0,
            filledCollateral: 0,
            lockedSharesAssigned: 0,
            filled: false,
            refunded: false,
            timestamp: block.timestamp,
            refundAmount: 0,
            sharesToBurn: 0
        });
        
        roundSellers[roundId].push(msg.sender);
        roundEconomics[roundId].totalSellerCollateral += collateralAmount;
        
        emit SellerPositionCreated(roundId, msg.sender, collateralAmount, sharesMinted);
        emit CollateralDeposited(msg.sender, collateralAmount, sharesMinted);
    }
    


    // ============ Round Matching Functions ============
    
    /**
     * @notice Compute match and perform distributions. Returns matched amount.
     * @param roundId The round to compute match for
     */
    function computeMatchAndDistribute(uint256 roundId)
        external
        onlyRole(OPERATOR_ROLE)
        onlyUnfrozenRound(roundId)
        returns (uint256 matchedAmount)
    {
        // Read lifecycle from catalog
        IProductCatalog.Round memory r = IProductCatalog(trancheInfo.productCatalog).getRound(roundId);
        if (r.trancheId != trancheInfo.trancheId) revert InvalidRound(roundId);
        if (r.state != IProductCatalog.RoundState.OPEN) revert InvalidRoundState(RoundState(uint256(r.state)), RoundState.OPEN);
        if (block.timestamp <= r.salesEndTime) revert SalesWindowNotOpen();
        
        RoundEconomics storage econ = roundEconomics[roundId];
        matchedAmount = econ.totalBuyerPurchases < econ.totalSellerCollateral
            ? econ.totalBuyerPurchases
            : econ.totalSellerCollateral;
        
        econ.matchedAmount = matchedAmount;
        econ.lockedCollateral = matchedAmount;
        
        // Lock collateral in pool accounting
        poolAccounting.lockedAssets += matchedAmount;
        
        // Process matching, refunds, then premium distribution
        _processMatching(roundId, matchedAmount);
        _processRefunds(roundId);
        _distributePremiums(roundId);
        
        emit RoundMatched(roundId, matchedAmount, roundBuyers[roundId].length, roundSellers[roundId].length);
        return matchedAmount;
    }
    
    /**
     * @notice Activate a matched round for settlement countdown (called by SettlementEngine)
     * @param roundId The round to activate
     */
    // No local state transitions for activation/maturity/settlement

    /**
     * @notice Update round state (called by SettlementEngine)
     * @param roundId The round ID
     * @param newState The new state
     */
    // No local updateRoundState; use ProductCatalog as SSoT

    // ============ Settlement Functions (called by SettlementEngine) ============
    
    /**
     * @notice Execute buyer payouts when triggered (called by SettlementEngine)
     * @param roundId The round to pay out
     * @return totalPayouts Total amount paid to buyers
     */
    function executeBuyerPayouts(uint256 roundId) external onlySettlementEngine returns (uint256 totalPayouts) {
        address[] memory buyers = roundBuyers[roundId];
        address[] memory sellers = roundSellers[roundId];
        
        // 1. Update NAV to include any yield that was already returned before settlement
        _updateNAV();
        
        // 2. Pay buyers their insurance claims
        for (uint256 i = 0; i < buyers.length; i++) {
            BuyerOrder storage order = buyerOrders[roundId][buyers[i]];
            if (order.filled) {
                uint256 payout = order.purchaseAmount;
                totalPayouts += payout;
                
                usdtToken.safeTransfer(order.buyer, payout);
            }
        }
        
        // 3. Pay sellers their yield portion (they lose collateral but keep yield earnings)
        uint256 totalSellerYieldPayout = 0;
        for (uint256 i = 0; i < sellers.length; i++) {
            SellerPosition storage position = sellerPositions[roundId][sellers[i]];
            if (position.filled && position.lockedSharesAssigned > 0) {
                // Calculate yield earned on locked shares
                uint256 totalValue = (position.lockedSharesAssigned * poolAccounting.navPerShare) / 1e18;
                uint256 originalCollateral = position.filledCollateral;
                
                // Yield = total value - original collateral
                if (totalValue > originalCollateral) {
                    uint256 yieldEarned = totalValue - originalCollateral;
                    if (yieldEarned > 0) {
                        usdtToken.safeTransfer(position.seller, yieldEarned);
                        totalSellerYieldPayout += yieldEarned;
                        
                        emit CollateralReleased(roundId, position.seller, yieldEarned);
                    }
                }
                
                // Burn the locked shares (sellers lose collateral portion, got yield portion)
                poolAccounting.totalShares -= position.lockedSharesAssigned;
                shareBalances[position.seller] -= position.lockedSharesAssigned;
                lockedShares[position.seller] -= position.lockedSharesAssigned;
            }
        }
        
        // 4. Update pool accounting
        poolAccounting.totalAssets -= (totalPayouts + totalSellerYieldPayout);
        poolAccounting.lockedAssets -= roundEconomics[roundId].lockedCollateral;
        
        // 5. Update NAV after all changes
        _updateNAV();
    }
    
    /**
     * @notice Release collateral to sellers when not triggered (called by SettlementEngine)
     * @param roundId The round to release collateral for
     */
    function releaseSellerCollateral(uint256 roundId) external onlySettlementEngine {
        address[] memory sellers = roundSellers[roundId];
        uint256 totalPayout = 0;
        uint256 totalSharesBurned = 0;
        
        // 1. Update NAV to include any yield that was already returned before settlement
        _updateNAV();
        
        for (uint256 i = 0; i < sellers.length; i++) {
            SellerPosition storage position = sellerPositions[roundId][sellers[i]];
            if (position.filled) {
                // Calculate shares to burn (locked shares that were committed to this round)
                uint256 sharesToBurn = position.lockedSharesAssigned > 0 ? position.lockedSharesAssigned : position.sharesMinted;
                
                // Calculate total payout based on NAV (collateral + accumulated yield)
                uint256 sellerPayout = (sharesToBurn * poolAccounting.navPerShare) / 1e18;
                
                if (sellerPayout > 0 && sharesToBurn > 0) {
                    // Transfer total amount (collateral + yield) to seller
                    usdtToken.safeTransfer(position.seller, sellerPayout);
                    totalPayout += sellerPayout;
                    
                    // Burn the shares (seller got their money, shares should be removed)
                    shareBalances[position.seller] -= sharesToBurn;
                    lockedShares[position.seller] -= sharesToBurn;
                    totalSharesBurned += sharesToBurn;
                    
                    emit CollateralReleased(roundId, position.seller, sellerPayout);
                }
            }
        }
        
        // 2. Update pool accounting: reduce both assets and shares proportionally
        poolAccounting.totalAssets -= totalPayout;
        poolAccounting.totalShares -= totalSharesBurned;
        poolAccounting.lockedAssets -= roundEconomics[roundId].lockedCollateral;
        
        // 3. Update NAV after proper accounting changes
        _updateNAV();
    }

    // ============ Yield Management Functions ============
    
    /**
     * @notice Withdraw funds for yield generation (called by YieldRouter)
     * @param amount Amount to withdraw
     * @return success Whether the withdrawal was successful
     */
    function withdrawForYield(uint256 amount) external nonReentrant returns (bool) {
        if (msg.sender != yieldRouter) revert Unauthorized();
        if (amount == 0) return false;
        
        uint256 availableForYield = this.getAvailableForYield();
        if (amount > availableForYield) return false;
        
        // Transfer USDT to YieldRouter
        usdtToken.safeTransfer(yieldRouter, amount);
        
        // Update accounting
        poolAccounting.yieldDeposited += amount;
        
        emit FundsMovedToYield(amount, yieldRouter, block.timestamp);
        return true;
    }
    
    /**
     * @notice Deposit funds from yield generation (called by YieldRouter)
     * @param principalAmount Original amount that was moved to yield
     * @param yieldAmount Additional yield earned
     * @return success Whether the deposit was successful
     */
    function depositFromYield(uint256 principalAmount, uint256 yieldAmount) external nonReentrant returns (bool) {
        if (msg.sender != yieldRouter) revert Unauthorized();
        if (principalAmount != poolAccounting.yieldDeposited) return false;
        
        // Update accounting
        poolAccounting.totalAssets += yieldAmount; // Add yield to total assets (principal was already counted)
        poolAccounting.yieldEarned += yieldAmount;
        poolAccounting.yieldDeposited = 0; // Reset deposited amount
        
        // Update NAV to reflect yield
        _updateNAV();
        
        emit FundsReturnedFromYield(principalAmount + yieldAmount, yieldAmount, block.timestamp);
        return true;
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Process round matching logic (pure matching, no refunds)
     */
    function _processMatching(uint256 roundId, uint256 matchedAmount) internal {
        address[] memory buyers = roundBuyers[roundId];
        address[] memory sellers = roundSellers[roundId];
        RoundEconomics storage econ = roundEconomics[roundId];
        
        // Process buyer matching with partial fill support (FCFS)
        uint256 buyerTotal = 0;
        
        for (uint256 i = 0; i < buyers.length && buyerTotal < matchedAmount; i++) {
            BuyerOrder storage order = buyerOrders[roundId][buyers[i]];
            uint256 remainingCapacity = matchedAmount - buyerTotal;

            if (order.purchaseAmount == 0) {
                continue;
            }

            if (order.purchaseAmount <= remainingCapacity) {
                // Fully fill this buyer
                order.filled = true;
                buyerTotal += order.purchaseAmount;
            } else {
                // Partial fill - update order to matched portion and store refund amount
                order.filled = true;
                
                uint256 matchedPortion = remainingCapacity;
                uint256 unmatchedPortion = order.purchaseAmount - matchedPortion;
                uint256 unmatchedPremium = (order.premiumPaid * unmatchedPortion) / order.purchaseAmount;
                uint256 matchedPremium = order.premiumPaid - unmatchedPremium;
                
                // Store refund amount for _processRefunds
                order.refundAmount = unmatchedPremium;
                
                // Update round economics to reflect reduced buyer demand
                econ.totalBuyerPurchases -= unmatchedPortion;
                
                // Update order to matched portion immediately
                order.purchaseAmount = matchedPortion;
                order.premiumPaid = matchedPremium;
                
                buyerTotal = matchedAmount;
            }
        }
        
        // Process seller matching (FCFS)
        uint256 sellerTotal = 0;
        for (uint256 i = 0; i < sellers.length && sellerTotal < matchedAmount; i++) {
            SellerPosition storage position = sellerPositions[roundId][sellers[i]];
            uint256 remainingNeeded = matchedAmount - sellerTotal;

            if (position.collateralAmount == 0) {
                continue;
            }

            if (position.collateralAmount <= remainingNeeded) {
                // Fully fill this seller
                position.filled = true;
                position.filledCollateral = position.collateralAmount;
                position.lockedSharesAssigned = position.sharesMinted;
                lockedShares[sellers[i]] += position.lockedSharesAssigned;
                sellerTotal += position.collateralAmount;
            } else {
                // Partial fill - update position to matched portion and store refund amounts
                position.filled = true;
                position.filledCollateral = remainingNeeded;
                uint256 sharesToLock = (position.sharesMinted * remainingNeeded) / position.collateralAmount;
                position.lockedSharesAssigned = sharesToLock;
                lockedShares[sellers[i]] += sharesToLock;

                // Store refund amounts for _processRefunds
                uint256 refundAmount = position.collateralAmount - remainingNeeded;
                uint256 sharesToBurn = position.sharesMinted - sharesToLock;
                position.refundAmount = refundAmount;
                position.sharesToBurn = sharesToBurn;

                // Update round economics to reflect reduced seller supply
                econ.totalSellerCollateral -= refundAmount;
                
                // Update position to filled portion immediately
                position.collateralAmount = remainingNeeded;
                position.sharesMinted = sharesToLock;

                sellerTotal = matchedAmount;
            }
        }
    }
    
    /**
     * @notice Distribute premiums to sellers and protocol
     */
    function _distributePremiums(uint256 roundId) internal {
        RoundEconomics storage econ = roundEconomics[roundId];
        uint256 totalPremiums = econ.premiumPool;
        
        // Calculate protocol fee
        uint256 protocolFee = (totalPremiums * protocolFeeBps) / 10000;
        uint256 sellerShare = totalPremiums - protocolFee;
        
        econ.protocolFees = protocolFee;
        
        // Transfer protocol fee to treasury
        if (protocolFee > 0) {
            usdtToken.safeTransfer(feeTreasury, protocolFee);
        }
        
        // Distribute premiums directly to filled sellers (immediate transfer)
        address[] memory sellers = roundSellers[roundId];
        uint256 totalFilledCollateral = 0;
        
        for (uint256 i = 0; i < sellers.length; i++) {
            if (sellerPositions[roundId][sellers[i]].filled) {
                // After partial fills, collateralAmount reflects filled portion
                totalFilledCollateral += sellerPositions[roundId][sellers[i]].collateralAmount;
            }
        }
        
        if (totalFilledCollateral > 0 && sellerShare > 0) {
            for (uint256 i = 0; i < sellers.length; i++) {
                SellerPosition storage position = sellerPositions[roundId][sellers[i]];
                if (position.filled) {
                    uint256 sellerPremium = (sellerShare * position.collateralAmount) / totalFilledCollateral;
                    position.premiumEarned = sellerPremium;
                    
                    // Transfer premium directly to seller (just like refunds)
                    if (sellerPremium > 0) {
                        usdtToken.safeTransfer(position.seller, sellerPremium);
                        emit PremiumTransferred(roundId, position.seller, sellerPremium);
                    }
                }
            }
        }
        
        // Update NAV (no need to add seller share to pool since it was transferred out)
        _updateNAV();
        
        emit PremiumDistributed(roundId, sellerShare, protocolFee);
    }
    
    /**
     * @notice Process all refunds (order amounts already updated to matched portions in _processMatching)
     */
    function _processRefunds(uint256 roundId) internal {
        address[] memory buyers = roundBuyers[roundId];
        address[] memory sellers = roundSellers[roundId];
        RoundEconomics storage econ = roundEconomics[roundId];
        
        // Process buyer refunds
        for (uint256 i = 0; i < buyers.length; i++) {
            BuyerOrder storage order = buyerOrders[roundId][buyers[i]];
            
            if (!order.filled) {
                // Completely unfilled - refund full premium
                order.refunded = true;
                usdtToken.safeTransfer(order.buyer, order.premiumPaid);
                emit RefundProcessed(roundId, order.buyer, order.premiumPaid, true);
                
                // Remove from round economics
                econ.totalBuyerPurchases -= order.purchaseAmount;
                econ.premiumPool -= order.premiumPaid;
                
            } else if (order.refundAmount > 0) {
                // Partially filled - refund unmatched premium (order & economics already updated)
                order.refunded = true;
                usdtToken.safeTransfer(order.buyer, order.refundAmount);
                emit RefundProcessed(roundId, order.buyer, order.refundAmount, true);
                
                // Only update premium pool (totalBuyerPurchases already updated in matching)
                econ.premiumPool -= order.refundAmount;
                order.refundAmount = 0; // Clear refund amount after processing
            }
        }
        
        // Process seller refunds
        for (uint256 i = 0; i < sellers.length; i++) {
            SellerPosition storage position = sellerPositions[roundId][sellers[i]];
            
            if (!position.filled) {
                // Completely unfilled - refund full collateral
                position.refunded = true;
                
                poolAccounting.totalAssets -= position.collateralAmount;
                poolAccounting.totalShares -= position.sharesMinted;
                shareBalances[position.seller] -= position.sharesMinted;
                
                usdtToken.safeTransfer(position.seller, position.collateralAmount);
                emit RefundProcessed(roundId, position.seller, position.collateralAmount, false);
                
                // Remove from round economics
                econ.totalSellerCollateral -= position.collateralAmount;
                
            } else if (position.refundAmount > 0) {
                // Partially filled - refund unmatched collateral (position & economics already updated)
                position.refunded = true;
                
                poolAccounting.totalAssets -= position.refundAmount;
                poolAccounting.totalShares -= position.sharesToBurn;
                shareBalances[position.seller] -= position.sharesToBurn;
                
                usdtToken.safeTransfer(position.seller, position.refundAmount);
                emit RefundProcessed(roundId, position.seller, position.refundAmount, false);
                
                // Clear refund amounts after processing (totalSellerCollateral already updated in matching)
                position.refundAmount = 0;
                position.sharesToBurn = 0;
            }
        }
    }
    
    /**
     * @notice Update NAV per share
     */
    function _updateNAV() internal {
        uint256 oldNav = poolAccounting.navPerShare;
        if (poolAccounting.totalShares > 0) {
            poolAccounting.navPerShare = (poolAccounting.totalAssets * 1e18) / poolAccounting.totalShares;
        }
        poolAccounting.lastUpdateTime = block.timestamp;
        
        emit NAVUpdated(oldNav, poolAccounting.navPerShare, block.timestamp);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get round details
     */
    function getRoundEconomics(uint256 roundId) external view returns (
        uint256 totalBuyerPurchases,
        uint256 totalSellerCollateral,
        uint256 matchedAmount,
        uint256 lockedCollateral,
        uint256 premiumPool,
        uint256 protocolFees
    ) {
        RoundEconomics storage econ = roundEconomics[roundId];
        return (
            econ.totalBuyerPurchases,
            econ.totalSellerCollateral,
            econ.matchedAmount,
            econ.lockedCollateral,
            econ.premiumPool,
            econ.protocolFees
        );
    }
    
    /**
     * @notice Get buyer order details
     */
    function getBuyerOrder(uint256 roundId, address buyer) external view returns (BuyerOrder memory) {
        return buyerOrders[roundId][buyer];
    }
    
    /**
     * @notice Get seller position details
     */
    function getSellerPosition(uint256 roundId, address seller) external view returns (SellerPosition memory) {
        return sellerPositions[roundId][seller];
    }
    
    /**
     * @notice Get pool accounting details
     */
    function getPoolAccounting() external view returns (PoolAccounting memory) {
        return poolAccounting;
    }
    
    /**
     * @notice Get available collateral for withdrawal
     */
    function getAvailableCollateral(address seller) external view returns (uint256) {
        uint256 totalShares = shareBalances[seller];
        uint256 lockedSharesAmount = lockedShares[seller];
        uint256 availableShares = totalShares - lockedSharesAmount;
        
        return (availableShares * poolAccounting.navPerShare) / 1e18;
    }
    
    /**
     * @notice Get available funds for yield generation
     */
    function getAvailableForYield() external view returns (uint256) {
        uint256 availableFunds = poolAccounting.totalAssets - poolAccounting.lockedAssets - poolAccounting.yieldDeposited;
        return availableFunds;
    }
    
    /**
     * @notice Get yield information
     */
    function getYieldInfo() external view returns (
        uint256 yieldDeposited,
        uint256 yieldEarned,
        address yieldRouterAddress
    ) {
        return (
            poolAccounting.yieldDeposited,
            poolAccounting.yieldEarned,
            yieldRouter
        );
    }
    
    /**
     * @notice Get round participants
     */
    function getRoundParticipants(uint256 roundId) external view returns (address[] memory buyers, address[] memory sellers) {
        return (roundBuyers[roundId], roundSellers[roundId]);
    }
    
    /**
     * @notice Get tranche information
     */
    function getTrancheInfo() external view returns (TrancheInfo memory) {
        return trancheInfo;
    }

    // ============ Admin Functions ============
    
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
    
    /**
     * @notice Emergency cancel round
     */
    // No emergency cancel of round state in pool
    
    /**
     * @notice Freeze a round to prevent new orders and operations
     * @param roundId The round to freeze
     */
    function freezeRound(uint256 roundId) external onlyRole(ADMIN_ROLE) {
        require(!frozen[roundId], "Round already frozen");
        frozen[roundId] = true;
        emit RoundFrozen(roundId, msg.sender, block.timestamp);
    }
    
    /**
     * @notice Unfreeze a round to resume operations
     * @param roundId The round to unfreeze
     */
    function unfreezeRound(uint256 roundId) external onlyRole(ADMIN_ROLE) {
        require(frozen[roundId], "Round not frozen");
        frozen[roundId] = false;
        emit RoundUnfrozen(roundId, msg.sender, block.timestamp);
    }
}
