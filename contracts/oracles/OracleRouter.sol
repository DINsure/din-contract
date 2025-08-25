// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "./OraklPriceFeed.sol";
import "./DinoOracle.sol";

/**
 * @title OracleRouter
 * @notice Routes oracle requests to appropriate oracle systems (Orakl Network or DINO)
 * @dev Provides unified interface for accessing both external and internal oracles
 */
contract OracleRouter is AccessControl, Pausable {
    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ Enums ============
    enum OracleType {
        ORAKL_NETWORK,  // External oracle via Orakl Network
        DINO_ORACLE,    // Internal optimistic oracle
        FALLBACK        // Use fallback strategy
    }

    enum FallbackStrategy {
        PREFER_ORAKL,   // Prefer Orakl, fallback to DINO
        PREFER_DINO,    // Prefer DINO, fallback to Orakl
        REQUIRE_BOTH,   // Require both oracles to agree
        MANUAL_ONLY     // Only manual override allowed
    }

    // ============ Structs ============
    struct OracleConfig {
        OracleType primaryType;
        FallbackStrategy fallbackStrategy;
        uint256 maxPriceDeviationBps; // Maximum allowed deviation between oracles (in basis points)
        uint256 maxStaleness;         // Maximum acceptable price staleness in seconds
        bool active;
        string description;
    }

    struct PriceResult {
        uint256 price;
        uint256 timestamp;
        OracleType source;
        bool valid;
        string error;
    }

    // ============ Storage ============
    OraklPriceFeed public immutable oraklFeed;
    DinoOracle public immutable dinoOracle;

    // Oracle configurations by identifier
    mapping(bytes32 => OracleConfig) public oracleConfigs;
    bytes32[] public configuredIdentifiers;

    // Manual price overrides (emergency use)
    mapping(bytes32 => mapping(uint256 => uint256)) public manualPrices;
    mapping(bytes32 => bool) public emergencyMode;

    // Price deviation tracking
    mapping(bytes32 => uint256) public lastOraklPrice;
    mapping(bytes32 => uint256) public lastDinoPrice;
    mapping(bytes32 => uint256) public lastPriceUpdate;

    // ============ Events ============
    event OracleConfigured(
        bytes32 indexed identifier,
        OracleType primaryType,
        FallbackStrategy fallbackStrategy,
        uint256 maxDeviationBps,
        uint256 maxStaleness
    );

    event PriceRequested(
        bytes32 indexed identifier,
        uint256 timestamp,
        OracleType requestedType
    );

    event PriceRetrieved(
        bytes32 indexed identifier,
        uint256 price,
        uint256 timestamp,
        OracleType source
    );

    event FallbackTriggered(
        bytes32 indexed identifier,
        OracleType failedType,
        OracleType fallbackType,
        string reason
    );

    event PriceDeviationAlert(
        bytes32 indexed identifier,
        uint256 oraklPrice,
        uint256 dinoPrice,
        uint256 deviationBps
    );

    event ManualPriceSet(
        bytes32 indexed identifier,
        uint256 timestamp,
        uint256 price,
        address setter
    );

    event EmergencyModeToggled(
        bytes32 indexed identifier,
        bool enabled
    );

    // ============ Custom Errors ============
    error ZeroAddress();
    error IdentifierNotConfigured(bytes32 identifier);
    error OracleNotAvailable(OracleType oracleType);
    error PriceDeviationTooHigh(uint256 deviation, uint256 maxDeviation);
    error PriceTooStale(uint256 lastUpdate, uint256 maxStaleness);
    error NoValidPrice(bytes32 identifier);
    error EmergencyModeActive(bytes32 identifier);
    error InvalidConfiguration();

    // ============ Constructor ============
    constructor(
        address _oraklFeed,
        address _dinoOracle,
        address _admin
    ) {
        if (_oraklFeed == address(0) || _dinoOracle == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }

        oraklFeed = OraklPriceFeed(_oraklFeed);
        dinoOracle = DinoOracle(_dinoOracle);

        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
    }

    // ============ Configuration Functions ============

    /**
     * @notice Configure oracle routing for an identifier
     * @param identifier Price identifier (e.g., "BTC-USDT")
     * @param primaryType Primary oracle type to use
     * @param fallbackStrategy Fallback strategy if primary fails
     * @param maxDeviationBps Maximum price deviation between oracles (basis points)
     * @param maxStaleness Maximum acceptable staleness in seconds
     * @param description Human-readable description
     */
    function configureOracle(
        bytes32 identifier,
        OracleType primaryType,
        FallbackStrategy fallbackStrategy,
        uint256 maxDeviationBps,
        uint256 maxStaleness,
        string calldata description
    ) external onlyRole(ADMIN_ROLE) {
        if (maxDeviationBps > 10000) revert InvalidConfiguration(); // Max 100%
        if (maxStaleness == 0) revert InvalidConfiguration();

        // Add to configured identifiers if new
        if (!oracleConfigs[identifier].active) {
            configuredIdentifiers.push(identifier);
        }

        oracleConfigs[identifier] = OracleConfig({
            primaryType: primaryType,
            fallbackStrategy: fallbackStrategy,
            maxPriceDeviationBps: maxDeviationBps,
            maxStaleness: maxStaleness,
            active: true,
            description: description
        });

        emit OracleConfigured(
            identifier,
            primaryType,
            fallbackStrategy,
            maxDeviationBps,
            maxStaleness
        );
    }

    /**
     * @notice Deactivate oracle configuration for an identifier
     * @param identifier Price identifier to deactivate
     */
    function deactivateOracle(bytes32 identifier) external onlyRole(ADMIN_ROLE) {
        oracleConfigs[identifier].active = false;

        // Remove from configured identifiers
        for (uint256 i = 0; i < configuredIdentifiers.length; i++) {
            if (configuredIdentifiers[i] == identifier) {
                configuredIdentifiers[i] = configuredIdentifiers[configuredIdentifiers.length - 1];
                configuredIdentifiers.pop();
                break;
            }
        }
    }

    // ============ Price Retrieval Functions ============

    /**
     * @notice Get latest price for identifier using configured routing
     * @param identifier Price identifier
     * @return result Price result with metadata
     */
    function getPrice(bytes32 identifier) 
        external 
        view 
        whenNotPaused 
        returns (PriceResult memory result) 
    {
        OracleConfig memory config = oracleConfigs[identifier];
        if (!config.active) revert IdentifierNotConfigured(identifier);

        // Check emergency mode
        if (emergencyMode[identifier]) {
            return _getManualPrice(identifier, block.timestamp);
        }

        // Try primary oracle
        result = _getPriceFromOracle(identifier, config.primaryType, config.maxStaleness);
        
        if (result.valid) {
            return result;
        }

        // Try fallback if primary failed
        return _tryFallback(identifier, config, result.error);
    }

    /**
     * @notice Get price at specific timestamp
     * @param identifier Price identifier
     * @param timestamp Specific timestamp
     * @return result Price result with metadata
     */
    function getPriceAtTimestamp(bytes32 identifier, uint256 timestamp) 
        external 
        view 
        whenNotPaused 
        returns (PriceResult memory result) 
    {
        OracleConfig memory config = oracleConfigs[identifier];
        if (!config.active) revert IdentifierNotConfigured(identifier);

        // Check emergency mode first
        if (emergencyMode[identifier]) {
            return _getManualPrice(identifier, timestamp);
        }

        // For historical prices, try DINO first (as it stores historical data)
        if (config.primaryType == OracleType.DINO_ORACLE || 
            config.fallbackStrategy == FallbackStrategy.PREFER_DINO) {
            
            result = _getDinoPrice(identifier, timestamp);
            if (result.valid) {
                return result;
            }
        }

        // Fallback to latest available price if exact timestamp not found
        return _getPriceFromOracle(identifier, config.primaryType, config.maxStaleness);
    }

    /**
     * @notice Get prices from both oracles for comparison
     * @param identifier Price identifier
     * @return oraklResult Result from Orakl Network
     * @return dinoResult Result from DINO Oracle
     * @return deviation Price deviation in basis points
     */
    function comparePrices(bytes32 identifier) 
        external 
        view 
        returns (
            PriceResult memory oraklResult,
            PriceResult memory dinoResult,
            uint256 deviation
        ) 
    {
        oraklResult = _getOraklPrice(identifier, 3600); // 1 hour staleness
        dinoResult = _getDinoPrice(identifier, 0); // Latest available

        if (oraklResult.valid && dinoResult.valid) {
            deviation = _calculateDeviation(oraklResult.price, dinoResult.price);
        }
    }

    // ============ Internal Functions ============

    /**
     * @notice Get price from specific oracle type
     */
    function _getPriceFromOracle(
        bytes32 identifier, 
        OracleType oracleType, 
        uint256 maxStaleness
    ) internal view returns (PriceResult memory result) {
        if (oracleType == OracleType.ORAKL_NETWORK) {
            return _getOraklPrice(identifier, maxStaleness);
        } else if (oracleType == OracleType.DINO_ORACLE) {
            return _getDinoPrice(identifier, 0); // Get latest
        } else {
            result.error = "Invalid oracle type";
        }
    }

    /**
     * @notice Get price from Orakl Network
     */
    function _getOraklPrice(bytes32 identifier, uint256 maxStaleness) 
        internal 
        view 
        returns (PriceResult memory result) 
    {
        string memory symbol = _identifierToString(identifier);
        
        try oraklFeed.getLatestPrice(symbol) returns (OraklPriceFeed.PriceData memory priceData) {
            if (priceData.valid && 
                (maxStaleness == 0 || block.timestamp <= priceData.timestamp + maxStaleness)) {
                
                result = PriceResult({
                    price: priceData.price,
                    timestamp: priceData.timestamp,
                    source: OracleType.ORAKL_NETWORK,
                    valid: true,
                    error: ""
                });
            } else {
                result.error = "Orakl price too stale";
            }
        } catch Error(string memory reason) {
            result.error = string(abi.encodePacked("Orakl error: ", reason));
        } catch {
            result.error = "Orakl call failed";
        }
    }

    /**
     * @notice Get price from DINO Oracle
     */
    function _getDinoPrice(bytes32 identifier, uint256 specificTimestamp) 
        internal 
        view 
        returns (PriceResult memory result) 
    {
        try dinoOracle.getLatestPrice(identifier) returns (uint256 price, uint256 timestamp) {
            if (price > 0 && (specificTimestamp == 0 || timestamp == specificTimestamp)) {
                result = PriceResult({
                    price: price,
                    timestamp: timestamp,
                    source: OracleType.DINO_ORACLE,
                    valid: true,
                    error: ""
                });
            } else if (specificTimestamp > 0) {
                // Try specific timestamp
                try dinoOracle.getPrice(identifier, specificTimestamp) returns (uint256 historicalPrice) {
                    result = PriceResult({
                        price: historicalPrice,
                        timestamp: specificTimestamp,
                        source: OracleType.DINO_ORACLE,
                        valid: true,
                        error: ""
                    });
                } catch {
                    result.error = "DINO price not available for timestamp";
                }
            } else {
                result.error = "DINO price not available";
            }
        } catch Error(string memory reason) {
            result.error = string(abi.encodePacked("DINO error: ", reason));
        } catch {
            result.error = "DINO call failed";
        }
    }

    /**
     * @notice Try fallback strategy when primary oracle fails
     */
    function _tryFallback(
        bytes32 identifier, 
        OracleConfig memory config, 
        string memory primaryError
    ) internal view returns (PriceResult memory result) {
        if (config.fallbackStrategy == FallbackStrategy.PREFER_ORAKL) {
            if (config.primaryType != OracleType.ORAKL_NETWORK) {
                return _getOraklPrice(identifier, config.maxStaleness);
            } else {
                return _getDinoPrice(identifier, 0);
            }
        } else if (config.fallbackStrategy == FallbackStrategy.PREFER_DINO) {
            if (config.primaryType != OracleType.DINO_ORACLE) {
                return _getDinoPrice(identifier, 0);
            } else {
                return _getOraklPrice(identifier, config.maxStaleness);
            }
        } else if (config.fallbackStrategy == FallbackStrategy.REQUIRE_BOTH) {
            // Both oracles must agree - already failed if we're here
            result.error = "Both oracles required but primary failed";
        } else {
            // MANUAL_ONLY
            result.error = "Manual override required";
        }
    }

    /**
     * @notice Get manual price override
     */
    function _getManualPrice(bytes32 identifier, uint256 timestamp) 
        internal 
        view 
        returns (PriceResult memory result) 
    {
        uint256 manualPrice = manualPrices[identifier][timestamp];
        if (manualPrice > 0) {
            result = PriceResult({
                price: manualPrice,
                timestamp: timestamp,
                source: OracleType.FALLBACK,
                valid: true,
                error: ""
            });
        } else {
            result.error = "No manual price set";
        }
    }

    /**
     * @notice Calculate price deviation in basis points
     */
    function _calculateDeviation(uint256 price1, uint256 price2) 
        internal 
        pure 
        returns (uint256 deviation) 
    {
        if (price1 == 0 || price2 == 0) return 10000; // 100% deviation if either is zero
        
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 average = (price1 + price2) / 2;
        
        deviation = (diff * 10000) / average;
    }

    /**
     * @notice Convert bytes32 identifier to string for Orakl
     */
    function _identifierToString(bytes32 identifier) internal pure returns (string memory) {
        // For known identifiers, return direct mapping to symbol strings
        // This is more reliable than converting bytes32 back to string
        if (identifier == keccak256("BTC-USDT")) return "BTC-USDT";
        if (identifier == keccak256("ETH-USDT")) return "ETH-USDT";
        if (identifier == keccak256("KAIA-USDT")) return "KAIA-USDT";
        
        // Fallback: convert bytes32 to string (may not work for all cases)
        bytes memory bytesArray = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            bytesArray[i] = identifier[i];
        }
        
        // Find actual length by locating last non-zero byte
        uint256 length = 0;
        for (uint256 i = 0; i < 32; i++) {
            if (bytesArray[i] != 0) {
                length = i + 1;
            }
        }
        
        // Return empty string if no valid chars found
        if (length == 0) return "";
        
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = bytesArray[i];
        }
        
        return string(result);
    }

    // ============ Emergency Functions ============

    /**
     * @notice Set manual price override (emergency use)
     * @param identifier Price identifier
     * @param timestamp Price timestamp
     * @param price Manual price value
     */
    function setManualPrice(
        bytes32 identifier,
        uint256 timestamp,
        uint256 price
    ) external onlyRole(ADMIN_ROLE) {
        manualPrices[identifier][timestamp] = price;
        emit ManualPriceSet(identifier, timestamp, price, msg.sender);
    }

    /**
     * @notice Toggle emergency mode for identifier
     * @param identifier Price identifier
     * @param enabled Whether emergency mode is enabled
     */
    function setEmergencyMode(bytes32 identifier, bool enabled) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        emergencyMode[identifier] = enabled;
        emit EmergencyModeToggled(identifier, enabled);
    }

    // ============ View Functions ============

    /**
     * @notice Get all configured identifiers
     */
    function getConfiguredIdentifiers() external view returns (bytes32[] memory) {
        return configuredIdentifiers;
    }

    /**
     * @notice Check if identifier is configured
     */
    function isConfigured(bytes32 identifier) external view returns (bool) {
        return oracleConfigs[identifier].active;
    }

    /**
     * @notice Get oracle configuration for identifier
     */
    function getOracleConfig(bytes32 identifier) 
        external 
        view 
        returns (OracleConfig memory) 
    {
        return oracleConfigs[identifier];
    }

    // ============ Admin Functions ============

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
