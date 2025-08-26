// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/security/ReentrancyGuard.sol";
import "@kaiachain/contracts/token/ERC20/IERC20.sol";
import "@kaiachain/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDinRegistry.sol";

interface ITranchePoolCore {
    function getAvailableForYield() external view returns (uint256);
    function withdrawForYield(uint256 amount) external returns (bool);
    function depositFromYield(uint256 principalAmount, uint256 yieldAmount) external returns (bool);
    function getTrancheInfo() external view returns (uint256 trancheId, uint256 productId, address productCatalog, bool active);
}

/**
 * @title YieldRouter
 * @notice Central controller for yield generation across all TranchePoolCore contracts
 * @dev Manages funds from multiple pools, handles external investments, and distributes yield
 */
contract YieldRouter is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Structs ============
    struct PoolInfo {
        address poolAddress;
        uint256 trancheId;
        uint256 fundsInYield;
        uint256 totalYieldEarned;
        bool registered;
        uint256 registrationTimestamp;
    }

    struct YieldRecord {
        uint256 totalDeposited;
        uint256 totalReturned;
        uint256 totalYieldGenerated;
        uint256 lastUpdateTimestamp;
    }

    // ============ Storage ============
    IDinRegistry public immutable registry;
    IERC20 public immutable usdtToken;

    // Pool management
    mapping(address => PoolInfo) public poolInfo;
    address[] public registeredPools;

    YieldRecord public yieldRecord;

    // ============ Events ============
    event PoolRegistered(address indexed poolAddress, uint256 indexed trancheId, uint256 timestamp);
    event FundsMovedToYield(address indexed poolAddress, uint256 amount, uint256 timestamp);
    event FundsReturnedToPool(address indexed poolAddress, uint256 principalAmount, uint256 yieldAmount, uint256 timestamp);
    event AdminWithdrawal(address indexed admin, uint256 amount, uint256 timestamp, string purpose);
    event AdminDeposit(address indexed admin, uint256 amount, uint256 timestamp, string purpose);
    event YieldGenerated(uint256 totalAmount, uint256 yieldAmount, uint256 timestamp);

    // ============ Custom Errors ============
    error ZeroAddress();
    error ZeroAmount();
    error PoolNotRegistered(address pool);
    error PoolAlreadyRegistered(address pool);
    error InsufficientFunds(uint256 requested, uint256 available);
    error InsufficientPoolFunds(address pool, uint256 requested, uint256 available);
    error PoolCallFailed(address pool);
    error Unauthorized(address caller);

    // ============ Constructor ============
    constructor(address _registry, address _admin) {
        if (_registry == address(0) || _admin == address(0)) revert ZeroAddress();
        
        registry = IDinRegistry(_registry);
        usdtToken = IERC20(registry.getUSDTToken());
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        yieldRecord.lastUpdateTimestamp = block.timestamp;
    }

    // ============ Pool Registration ============
    
    /**
     * @notice Register a TranchePoolCore contract for yield management
     * @param poolAddress The address of the TranchePoolCore contract
     * @dev Called automatically by TranchePoolCore constructor
     */
    function registerPool(address poolAddress) external whenNotPaused {
        if (poolAddress == address(0)) revert ZeroAddress();
        if (poolInfo[poolAddress].registered) revert PoolAlreadyRegistered(poolAddress);

        // Get tranche info from the pool
        try ITranchePoolCore(poolAddress).getTrancheInfo() returns (
            uint256 trancheId, 
            uint256, // productId (not needed here)
            address, // productCatalog (not needed here)
            bool     // active (not needed here)
        ) {
            // Register the pool
            poolInfo[poolAddress] = PoolInfo({
                poolAddress: poolAddress,
                trancheId: trancheId,
                fundsInYield: 0,
                totalYieldEarned: 0,
                registered: true,
                registrationTimestamp: block.timestamp
            });

            registeredPools.push(poolAddress);

            emit PoolRegistered(poolAddress, trancheId, block.timestamp);
        } catch {
            revert PoolCallFailed(poolAddress);
        }
    }

    // ============ Yield Management Functions (OPERATOR_ROLE) ============

    /**
     * @notice Move funds from a pool to yield generation
     * @param poolAddress The pool to move funds from
     * @param amount The amount of USDT to move
     */
    function moveFromPool(address poolAddress, uint256 amount) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (amount == 0) revert ZeroAmount();
        if (!poolInfo[poolAddress].registered) revert PoolNotRegistered(poolAddress);

        // Check pool has sufficient available funds
        uint256 availableInPool = ITranchePoolCore(poolAddress).getAvailableForYield();
        if (amount > availableInPool) {
            revert InsufficientPoolFunds(poolAddress, amount, availableInPool);
        }

        // Call pool to withdraw funds
        bool success = ITranchePoolCore(poolAddress).withdrawForYield(amount);
        if (!success) revert PoolCallFailed(poolAddress);

        // Update tracking
        poolInfo[poolAddress].fundsInYield += amount;
        yieldRecord.totalDeposited += amount;
        yieldRecord.lastUpdateTimestamp = block.timestamp;

        emit FundsMovedToYield(poolAddress, amount, block.timestamp);
    }

    /**
     * @notice Return funds to a pool with yield
     * @param poolAddress The pool to return funds to
     * @param yieldAmount Additional yield amount to return (can be 0)
     */
    function returnToPool(address poolAddress, uint256 yieldAmount) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (!poolInfo[poolAddress].registered) revert PoolNotRegistered(poolAddress);
        
        PoolInfo storage pool = poolInfo[poolAddress];
        if (pool.fundsInYield == 0) revert ZeroAmount();

        uint256 principalAmount = pool.fundsInYield;
        uint256 totalReturnAmount = principalAmount + yieldAmount;

        // Check YieldRouter has sufficient balance
        uint256 routerBalance = usdtToken.balanceOf(address(this));
        if (totalReturnAmount > routerBalance) {
            revert InsufficientFunds(totalReturnAmount, routerBalance);
        }

        // Call pool to deposit the funds back
        bool success = ITranchePoolCore(poolAddress).depositFromYield(principalAmount, yieldAmount);
        if (!success) revert PoolCallFailed(poolAddress);

        // Update tracking
        pool.fundsInYield = 0;
        pool.totalYieldEarned += yieldAmount;
        yieldRecord.totalReturned += totalReturnAmount;
        yieldRecord.totalYieldGenerated += yieldAmount;
        yieldRecord.lastUpdateTimestamp = block.timestamp;

        emit FundsReturnedToPool(poolAddress, principalAmount, yieldAmount, block.timestamp);

        if (yieldAmount > 0) {
            emit YieldGenerated(totalReturnAmount, yieldAmount, block.timestamp);
        }
    }

    // ============ Admin Functions (ADMIN_ROLE) ============

    /**
     * @notice Admin withdraws USDT for external investment
     * @param amount The amount of USDT to withdraw
     * @param purpose A description of the withdrawal purpose
     */
    function adminWithdraw(uint256 amount, string memory purpose) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        if (amount == 0) revert ZeroAmount();
        
        uint256 availableForWithdrawal = getAvailableForWithdrawal();
        if (amount > availableForWithdrawal) {
            revert InsufficientFunds(amount, availableForWithdrawal);
        }

        usdtToken.safeTransfer(msg.sender, amount);

        emit AdminWithdrawal(msg.sender, amount, block.timestamp, purpose);
    }

    /**
     * @notice Admin deposits USDT (e.g., returns from external investments)
     * @param amount The amount of USDT to deposit
     * @param purpose A description of the deposit purpose
     */
    function adminDeposit(uint256 amount, string memory purpose) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        if (amount == 0) revert ZeroAmount();

        usdtToken.safeTransferFrom(msg.sender, address(this), amount);

        emit AdminDeposit(msg.sender, amount, block.timestamp, purpose);
    }

    // ============ View Functions ============

    /**
     * @notice Get the total USDT balance held by the YieldRouter
     */
    function getTotalBalance() public view returns (uint256) {
        return usdtToken.balanceOf(address(this));
    }

    /**
     * @notice Get the total value at risk (funds committed to pools)
     */
    function getTotalValueAtRisk() public view returns (uint256) {
        uint256 totalAtRisk = 0;
        for (uint256 i = 0; i < registeredPools.length; i++) {
            totalAtRisk += poolInfo[registeredPools[i]].fundsInYield;
        }
        return totalAtRisk;
    }

    /**
     * @notice Get the amount available for admin withdrawal
     */
    function getAvailableForWithdrawal() public view returns (uint256) {
        uint256 totalBalance = getTotalBalance();
        uint256 valueAtRisk = getTotalValueAtRisk();
        return totalBalance > valueAtRisk ? totalBalance - valueAtRisk : 0;
    }

    /**
     * @notice Get information about a registered pool
     */
    function getPoolInfo(address poolAddress) external view returns (PoolInfo memory) {
        return poolInfo[poolAddress];
    }

    /**
     * @notice Get all registered pool addresses
     */
    function getRegisteredPools() external view returns (address[] memory) {
        return registeredPools;
    }

    /**
     * @notice Get the yield record
     */
    function getYieldRecord() external view returns (YieldRecord memory) {
        return yieldRecord;
    }

    /**
     * @notice Get comprehensive yield status
     */
    function getYieldStatus() external view returns (
        uint256 totalBalance,
        uint256 totalValueAtRisk,
        uint256 availableForWithdrawal,
        uint256 totalPoolsRegistered,
        uint256 totalActiveDeposits,
        YieldRecord memory record
    ) {
        totalBalance = getTotalBalance();
        totalValueAtRisk = getTotalValueAtRisk();
        availableForWithdrawal = getAvailableForWithdrawal();
        totalPoolsRegistered = registeredPools.length;
        
        // Count active deposits
        for (uint256 i = 0; i < registeredPools.length; i++) {
            if (poolInfo[registeredPools[i]].fundsInYield > 0) {
                totalActiveDeposits++;
            }
        }
        
        record = yieldRecord;
    }

    // ============ Emergency Controls ============

    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency return all funds to their respective pools
     * @dev Only callable when paused
     */
    function emergencyReturnAllFunds() external onlyRole(ADMIN_ROLE) whenPaused {
        for (uint256 i = 0; i < registeredPools.length; i++) {
            address poolAddress = registeredPools[i];
            PoolInfo storage pool = poolInfo[poolAddress];
            
            if (pool.fundsInYield > 0) {
                uint256 amount = pool.fundsInYield;
                
                // Try to return funds to pool (no yield in emergency)
                try ITranchePoolCore(poolAddress).depositFromYield(amount, 0) returns (bool success) {
                    if (success) {
                        pool.fundsInYield = 0;
                        emit FundsReturnedToPool(poolAddress, amount, 0, block.timestamp);
                    }
                } catch {
                    // Pool call failed, but continue with other pools
                    continue;
                }
            }
        }
    }
}