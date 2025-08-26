// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "./TranchePoolCore.sol";
import "./InsuranceToken.sol";
import "./interfaces/IDinRegistry.sol";
import "./interfaces/IProductCatalog.sol";

/**
 * @title TranchePoolFactory
 * @notice Factory contract for deploying TranchePoolCore instances per tranche
 * @dev Creates isolated pools for each tranche with proper registry integration
 */
contract TranchePoolFactory is AccessControl, Pausable {
    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Storage ============
    IDinRegistry public immutable registry;
    InsuranceToken public immutable insuranceToken;
    
    // Mapping from tranche ID to pool address
    mapping(uint256 => address) public tranchePools;
    
    // Array of all created pools
    address[] public allPools;
    
    // Pool creation tracking
    mapping(address => bool) public isValidPool;

    // ============ Events ============
    event TranchePoolCreated(
        uint256 indexed trancheId,
        uint256 indexed productId,
        address indexed pool,
        address creator,
        uint256 timestamp
    );
    
    // ============ Custom Errors ============
    error ZeroAddress();
    error TrancheNotFound();
    error PoolAlreadyExists(uint256 trancheId);
    error PoolNotFound(uint256 trancheId);
    error TrancheNotActive();
    error UnauthorizedPool();

    // ============ Constructor ============
    constructor(
        address _registry,
        address _insuranceToken,
        address _admin
    ) {
        if (_registry == address(0) || _insuranceToken == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        
        registry = IDinRegistry(_registry);
        insuranceToken = InsuranceToken(_insuranceToken);
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // ============ Pool Creation Functions ============
    
    /**
     * @notice Create a new TranchePool for a specific tranche
     * @param trancheId The tranche ID from ProductCatalog
     * @return pool The address of the created pool
     */
    function createTranchePool(uint256 trancheId) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (address pool) {
        // Check if pool already exists
        if (tranchePools[trancheId] != address(0)) {
            revert PoolAlreadyExists(trancheId);
        }
        
        // Get tranche details from ProductCatalog
        IProductCatalog catalog = IProductCatalog(registry.getProductCatalog());
        IProductCatalog.TrancheSpec memory tranche = catalog.getTranche(trancheId);
        
        // Validate tranche exists and is active
        if (tranche.trancheId == 0) revert TrancheNotFound();
        if (!tranche.active) revert TrancheNotActive();
        
        // Create TrancheInfo struct
        TranchePoolCore.TrancheInfo memory trancheInfo = TranchePoolCore.TrancheInfo({
            trancheId: trancheId,
            productId: tranche.productId,
            productCatalog: address(catalog),
            active: tranche.active
        });
        
        // Deploy new TranchePoolCore with msg.sender as admin
        pool = address(new TranchePoolCore(
            address(registry),
            trancheInfo,
            address(insuranceToken),
            msg.sender // Deployer as admin (gets ADMIN_ROLE and PAUSER_ROLE automatically)
        ));
        
        // Pool is created with msg.sender as admin
        // Additional roles (OPERATOR_ROLE, KEEPER_ROLE) can be granted by the admin later
        // Pool authorization should be done by the deployer separately
        
        // Store pool reference
        tranchePools[trancheId] = pool;
        allPools.push(pool);
        isValidPool[pool] = true;
        
        emit TranchePoolCreated(trancheId, tranche.productId, pool, msg.sender, block.timestamp);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get pool address for a tranche
     * @param trancheId The tranche ID
     * @return pool The pool address (zero if not exists)
     */
    function getTranchePool(uint256 trancheId) external view returns (address pool) {
        return tranchePools[trancheId];
    }
    
    /**
     * @notice Get pool info for a tranche (essential function)
     * @param trancheId The tranche ID
     * @return pool Pool address
     * @return trancheInfo Tranche information
     * @return poolAccounting Pool accounting details
     */
    function getPoolInfo(uint256 trancheId) external view returns (
        address pool,
        TranchePoolCore.TrancheInfo memory trancheInfo,
        TranchePoolCore.PoolAccounting memory poolAccounting
    ) {
        pool = tranchePools[trancheId];
        if (pool != address(0)) {
            TranchePoolCore poolContract = TranchePoolCore(pool);
            trancheInfo = poolContract.getTrancheInfo();
            poolAccounting = poolContract.getPoolAccounting();
        }
    }
        
    /**
     * @notice Get number of created pools (useful for monitoring)
     * @return count Number of pools
     */
    function getPoolCount() external view returns (uint256 count) {
        return allPools.length;
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Emergency pause all operations
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
    
    // Role management functions removed to reduce contract size
    // Use OpenZeppelin AccessControl functions directly: grantRole(), revokeRole()
}
