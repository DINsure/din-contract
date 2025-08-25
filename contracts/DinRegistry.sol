// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";

/**
 * @title DinRegistry
 * @notice Central registry for DIN protocol addresses and global parameters
 * @dev Single source of truth for contract addresses and bounded parameters
 */
contract DinRegistry is AccessControl, Pausable {
    // Role definitions
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant ORACLE_OPERATOR_ROLE = keccak256("ORACLE_OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Contract address identifiers
    bytes32 public constant USDT_TOKEN = keccak256("USDT_TOKEN");
    bytes32 public constant DIN_TOKEN = keccak256("DIN_TOKEN");
    bytes32 public constant PRODUCT_CATALOG = keccak256("PRODUCT_CATALOG");
    bytes32 public constant ROUND_MANAGER = keccak256("ROUND_MANAGER");
    bytes32 public constant TRANCHE_POOL_FACTORY = keccak256("TRANCHE_POOL_FACTORY");
    bytes32 public constant PREMIUM_ENGINE = keccak256("PREMIUM_ENGINE");
    bytes32 public constant SETTLEMENT_ENGINE = keccak256("SETTLEMENT_ENGINE");
    bytes32 public constant ORACLE_ROUTER = keccak256("ORACLE_ROUTER");
    bytes32 public constant ORAKL_PRICE_FEED = keccak256("ORAKL_PRICE_FEED");
    bytes32 public constant DINO_ORACLE = keccak256("DINO_ORACLE");
    bytes32 public constant YIELD_ROUTER = keccak256("YIELD_ROUTER");
    bytes32 public constant FEE_TREASURY = keccak256("FEE_TREASURY");
    bytes32 public constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");

    // Global parameter identifiers
    bytes32 public constant MAX_PREMIUM_BPS = keccak256("MAX_PREMIUM_BPS");
    bytes32 public constant MIN_MATURITY_SECONDS = keccak256("MIN_MATURITY_SECONDS");
    bytes32 public constant MAX_MATURITY_SECONDS = keccak256("MAX_MATURITY_SECONDS");
    bytes32 public constant RESTAKE_RATIO_CAP = keccak256("RESTAKE_RATIO_CAP");
    bytes32 public constant PER_ACCOUNT_MIN_DEFAULT = keccak256("PER_ACCOUNT_MIN_DEFAULT");
    bytes32 public constant PER_ACCOUNT_MAX_DEFAULT = keccak256("PER_ACCOUNT_MAX_DEFAULT");
    bytes32 public constant DISPUTE_WINDOW_SECONDS = keccak256("DISPUTE_WINDOW_SECONDS");
    bytes32 public constant LIVENESS_WINDOW_SECONDS = keccak256("LIVENESS_WINDOW_SECONDS");
    bytes32 public constant PROTOCOL_FEE_BPS = keccak256("PROTOCOL_FEE_BPS");

    // Storage
    mapping(bytes32 => address) private _addresses;
    mapping(bytes32 => uint256) private _parameters;
    mapping(bytes32 => uint256) private _parameterBounds; // Upper bounds for parameters

    // System metadata
    string public version;
    mapping(string => bytes32) public deploymentHashes;

    // Events
    event AddressSet(bytes32 indexed identifier, address indexed newAddress, address indexed oldAddress);
    event ParameterSet(bytes32 indexed identifier, uint256 newValue, uint256 oldValue);
    event ParameterBoundSet(bytes32 indexed identifier, uint256 newBound, uint256 oldBound);
    event VersionSet(string newVersion, string oldVersion);
    event DeploymentHashSet(string indexed name, bytes32 hash);

    // Custom errors
    error ZeroAddress();
    error UnauthorizedAccess(bytes32 role, address account);
    error ParameterExceedsBound(bytes32 identifier, uint256 value, uint256 bound);
    error InvalidParameterBound(bytes32 identifier, uint256 bound);

    /**
     * @dev Constructor sets up roles and initial parameters
     * @param _admin Address to grant admin role
     * @param _version Initial version string
     */
    constructor(address _admin, string memory _version) {
        if (_admin == address(0)) revert ZeroAddress();
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        version = _version;

        // Set default parameter bounds (10000 bps = 100%)
        _parameterBounds[MAX_PREMIUM_BPS] = 5000; // 50% max premium
        _parameterBounds[RESTAKE_RATIO_CAP] = 8000; // 80% max restake
        _parameterBounds[PROTOCOL_FEE_BPS] = 1000; // 10% max protocol fee
        _parameterBounds[MIN_MATURITY_SECONDS] = 1 hours;
        _parameterBounds[MAX_MATURITY_SECONDS] = 365 days;
        _parameterBounds[DISPUTE_WINDOW_SECONDS] = 7 days;
        _parameterBounds[LIVENESS_WINDOW_SECONDS] = 2 hours;
        _parameterBounds[PER_ACCOUNT_MIN_DEFAULT] = 100e6; // 100 USDT (6 decimals)
        _parameterBounds[PER_ACCOUNT_MAX_DEFAULT] = 1000000e6; // 1M USDT

        // Set sensible defaults
        _parameters[MAX_PREMIUM_BPS] = 1000; // 10%
        _parameters[MIN_MATURITY_SECONDS] = 1 days;
        _parameters[MAX_MATURITY_SECONDS] = 90 days;
        _parameters[RESTAKE_RATIO_CAP] = 5000; // 50%
        _parameters[DISPUTE_WINDOW_SECONDS] = 1 days;
        _parameters[LIVENESS_WINDOW_SECONDS] = 30 minutes;
        _parameters[PROTOCOL_FEE_BPS] = 200; // 2%
        _parameters[PER_ACCOUNT_MIN_DEFAULT] = 1000e6; // 1000 USDT
        _parameters[PER_ACCOUNT_MAX_DEFAULT] = 100000e6; // 100k USDT
    }

    // ============ Address Management ============

    /**
     * @notice Set a contract address
     * @param identifier The contract identifier
     * @param newAddress The new contract address
     */
    function setAddress(bytes32 identifier, address newAddress) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        if (newAddress == address(0)) revert ZeroAddress();
        
        address oldAddress = _addresses[identifier];
        _addresses[identifier] = newAddress;
        
        emit AddressSet(identifier, newAddress, oldAddress);
    }

    /**
     * @notice Get a contract address
     * @param identifier The contract identifier
     * @return The contract address
     */
    function getContractAddress(bytes32 identifier) external view returns (address) {
        return _addresses[identifier];
    }

    /**
     * @notice Batch set multiple addresses
     * @param identifiers Array of contract identifiers
     * @param addresses Array of contract addresses
     */
    function setAddresses(bytes32[] calldata identifiers, address[] calldata addresses) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        if (identifiers.length != addresses.length) {
            revert("Arrays length mismatch");
        }
        
        for (uint256 i = 0; i < identifiers.length; i++) {
            if (addresses[i] == address(0)) revert ZeroAddress();
            
            address oldAddress = _addresses[identifiers[i]];
            _addresses[identifiers[i]] = addresses[i];
            
            emit AddressSet(identifiers[i], addresses[i], oldAddress);
        }
    }

    // ============ Parameter Management ============

    /**
     * @notice Set a global parameter
     * @param identifier The parameter identifier
     * @param value The new parameter value
     */
    function setParameter(bytes32 identifier, uint256 value) 
        external 
        whenNotPaused 
    {
        // Admin can set any parameter, operator can set operational parameters only
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedAccess(OPERATOR_ROLE, msg.sender);
        }

        // Validate against bounds
        uint256 bound = _parameterBounds[identifier];
        if (bound > 0 && value > bound) {
            revert ParameterExceedsBound(identifier, value, bound);
        }

        uint256 oldValue = _parameters[identifier];
        _parameters[identifier] = value;
        
        emit ParameterSet(identifier, value, oldValue);
    }

    /**
     * @notice Get a global parameter
     * @param identifier The parameter identifier
     * @return The parameter value
     */
    function getParameter(bytes32 identifier) external view returns (uint256) {
        return _parameters[identifier];
    }

    /**
     * @notice Set parameter bound (admin only)
     * @param identifier The parameter identifier
     * @param bound The new upper bound
     */
    function setParameterBound(bytes32 identifier, uint256 bound) 
        external 
        onlyRole(ADMIN_ROLE) 
        whenNotPaused 
    {
        uint256 oldBound = _parameterBounds[identifier];
        _parameterBounds[identifier] = bound;
        
        emit ParameterBoundSet(identifier, bound, oldBound);
    }

    /**
     * @notice Get parameter bound
     * @param identifier The parameter identifier
     * @return The parameter bound
     */
    function getParameterBound(bytes32 identifier) external view returns (uint256) {
        return _parameterBounds[identifier];
    }

    // ============ System Status & Metadata ============

    /**
     * @notice Set system version
     * @param newVersion The new version string
     */
    function setVersion(string calldata newVersion) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        string memory oldVersion = version;
        version = newVersion;
        
        emit VersionSet(newVersion, oldVersion);
    }

    /**
     * @notice Set deployment hash for a component
     * @param name Component name
     * @param hash Deployment hash
     */
    function setDeploymentHash(string calldata name, bytes32 hash) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        deploymentHashes[name] = hash;
        emit DeploymentHashSet(name, hash);
    }

    /**
     * @notice Check if system is paused
     * @return Whether the system is paused
     */
    function isSystemPaused() external view returns (bool) {
        return paused();
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause the system
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the system
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============ Convenience Getters ============

    /**
     * @notice Get USDT token address
     */
    function getUSDTToken() external view returns (address) {
        return _addresses[USDT_TOKEN];
    }

    /**
     * @notice Get DIN token address
     */
    function getDINToken() external view returns (address) {
        return _addresses[DIN_TOKEN];
    }

    /**
     * @notice Get ProductCatalog address
     */
    function getProductCatalog() external view returns (address) {
        return _addresses[PRODUCT_CATALOG];
    }

    /**
     * @notice Get RoundManager address
     */
    function getRoundManager() external view returns (address) {
        return _addresses[ROUND_MANAGER];
    }

    /**
     * @notice Get TranchePoolFactory address
     */
    function getTranchePoolFactory() external view returns (address) {
        return _addresses[TRANCHE_POOL_FACTORY];
    }

    /**
     * @notice Get PremiumEngine address
     */
    function getPremiumEngine() external view returns (address) {
        return _addresses[PREMIUM_ENGINE];
    }

    /**
     * @notice Get SettlementEngine address
     */
    function getSettlementEngine() external view returns (address) {
        return _addresses[SETTLEMENT_ENGINE];
    }

    /**
     * @notice Get OracleRouter address
     */
    function getOracleRouter() external view returns (address) {
        return _addresses[ORACLE_ROUTER];
    }

    /**
     * @notice Get OraklPriceFeed address
     */
    function getOraklPriceFeed() external view returns (address) {
        return _addresses[ORAKL_PRICE_FEED];
    }

    /**
     * @notice Get DinoOracle address
     */
    function getDinoOracle() external view returns (address) {
        return _addresses[DINO_ORACLE];
    }

    /**
     * @notice Get YieldRouter address
     */
    function getYieldRouter() external view returns (address) {
        return _addresses[YIELD_ROUTER];
    }

    /**
     * @notice Get FeeTreasury address
     */
    function getFeeTreasury() external view returns (address) {
        return _addresses[FEE_TREASURY];
    }

    /**
     * @notice Get maximum premium in basis points
     */
    function getMaxPremiumBps() external view returns (uint256) {
        return _parameters[MAX_PREMIUM_BPS];
    }

    /**
     * @notice Get minimum maturity in seconds
     */
    function getMinMaturitySeconds() external view returns (uint256) {
        return _parameters[MIN_MATURITY_SECONDS];
    }

    /**
     * @notice Get maximum maturity in seconds
     */
    function getMaxMaturitySeconds() external view returns (uint256) {
        return _parameters[MAX_MATURITY_SECONDS];
    }

    /**
     * @notice Get protocol fee in basis points
     */
    function getProtocolFeeBps() external view returns (uint256) {
        return _parameters[PROTOCOL_FEE_BPS];
    }
}
