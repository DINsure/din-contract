// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import { IFeedProxy } from "@bisonai/orakl-contracts/v0.2/src/interfaces/IFeedProxy.sol";

/**
 * @title OraklPriceFeed
 * @notice Interface to Orakl Network Data Feed for price information
 * @dev Integrates with Orakl Network's decentralized oracle system on Kaia
 */
contract OraklPriceFeed is AccessControl, Pausable {
    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Structs ============
    struct PriceFeedConfig {
        address feedProxyAddress;
        uint8 decimals;
        uint32 heartbeatSeconds;
        string description;
        bool active;
    }

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint80 roundId;
        bool valid;
    }

    // ============ Storage ============
    
    // Feed configurations by feed ID
    mapping(bytes32 => PriceFeedConfig) public priceFeeds;
    bytes32[] public activeFeedIds;
    
    // Feed ID mappings (symbol -> feed ID)
    mapping(string => bytes32) public symbolToFeedId;
    
    // Price validation parameters
    uint256 public constant MAX_STALENESS = 3600; // 1 hour default staleness
    uint256 public priceDeviationThresholdBps = 1000; // 10% price deviation threshold

    // ============ Events ============
    event PriceFeedAdded(
        bytes32 indexed feedId,
        string symbol,
        address feedProxyAddress,
        uint8 decimals,
        uint32 heartbeat
    );
    
    event PriceFeedUpdated(
        bytes32 indexed feedId,
        address oldFeedAddress,
        address newFeedAddress,
        uint32 newHeartbeat,
        uint8 newDecimals,
        string newDescription
    );
    
    event PriceFeedDeactivated(bytes32 indexed feedId, string symbol);
    
    event PriceRetrieved(
        bytes32 indexed feedId,
        string symbol,
        uint256 price,
        uint256 timestamp,
        uint80 roundId
    );
    
    event StalePriceDetected(
        bytes32 indexed feedId,
        string symbol,
        uint256 lastUpdate,
        uint256 staleness
    );
    
    event PriceDeviationDetected(
        bytes32 indexed feedId,
        string symbol,
        uint256 currentPrice,
        uint256 previousPrice,
        uint256 deviation
    );

    // ============ Custom Errors ============
    error ZeroAddress();
    error FeedNotFound(bytes32 feedId);
    error FeedNotActive(bytes32 feedId);
    error InvalidFeedAddress(address feedProxyAddress);
    error StalePriceData(uint256 lastUpdate, uint256 maxStaleness);
    error InvalidPriceData(int256 price);

    error FeedAlreadyExists(bytes32 feedId);
    error InvalidHeartbeat(uint32 heartbeat);
    error InvalidDecimals(uint8 decimals);

    // ============ Constructor ============
    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Add a new Orakl price feed
     * @param symbol The price pair symbol (e.g., "BTC-USDT")
     * @param feedProxyAddress The Orakl feed proxy contract address
     * @param heartbeatSeconds Expected update frequency in seconds
     */
    function addPriceFeed(
        string calldata symbol,
        address feedProxyAddress,
        uint32 heartbeatSeconds
    ) external onlyRole(ADMIN_ROLE) {
        if (feedProxyAddress == address(0)) revert ZeroAddress();
        if (heartbeatSeconds == 0) revert InvalidHeartbeat(heartbeatSeconds);
        
        bytes32 feedId = keccak256(abi.encodePacked(symbol));
        if (priceFeeds[feedId].feedProxyAddress != address(0)) {
            revert FeedAlreadyExists(feedId);
        }
        
        // Validate feed by calling it
        IFeedProxy feed = IFeedProxy(feedProxyAddress);
        try feed.decimals() returns (uint8 decimals) {
            if (decimals == 0 || decimals > 18) revert InvalidDecimals(decimals);
            
            try feed.latestRoundData() returns (uint64, int256 price, uint256) {
                if (price <= 0) revert InvalidPriceData(price);
            } catch {
                revert InvalidFeedAddress(feedProxyAddress);
            }
            
            priceFeeds[feedId] = PriceFeedConfig({
                feedProxyAddress: feedProxyAddress,
                decimals: decimals,
                heartbeatSeconds: heartbeatSeconds,
                description: symbol,
                active: true
            });
            
            activeFeedIds.push(feedId);
            symbolToFeedId[symbol] = feedId;
            
            emit PriceFeedAdded(feedId, symbol, feedProxyAddress, decimals, heartbeatSeconds);
            
        } catch {
            revert InvalidFeedAddress(feedProxyAddress);
        }
    }
    
    /**
     * @notice Update an existing price feed configuration
     * @param symbol The price pair symbol
     * @param newFeedAddress The new Orakl feed proxy contract address
     * @param newHeartbeat Expected update frequency in seconds
     * @param newDescription Optional new description (empty to keep existing)
     */
    function updatePriceFeed(
        string calldata symbol,
        address newFeedAddress,
        uint32 newHeartbeat,
        string calldata newDescription
    ) external onlyRole(ADMIN_ROLE) {
        if (newFeedAddress == address(0)) revert ZeroAddress();
        if (newHeartbeat == 0) revert InvalidHeartbeat(newHeartbeat);
        
        bytes32 feedId = symbolToFeedId[symbol];
        if (priceFeeds[feedId].feedProxyAddress == address(0)) revert FeedNotFound(feedId);
        
        // Validate new feed
        IFeedProxy feed = IFeedProxy(newFeedAddress);
        try feed.decimals() returns (uint8 decimals) {
            try feed.latestRoundData() returns (uint64, int256 price, uint256) {
                if (price <= 0) revert InvalidPriceData(price);
            } catch {
                revert InvalidFeedAddress(newFeedAddress);
            }
            
            // Store old values for event
            address oldFeedAddress = priceFeeds[feedId].feedProxyAddress;
            
            // Update all configuration
            priceFeeds[feedId].feedProxyAddress = newFeedAddress;
            priceFeeds[feedId].decimals = decimals;
            priceFeeds[feedId].heartbeatSeconds = newHeartbeat;
            
            // Update description only if provided
            if (bytes(newDescription).length > 0) {
                priceFeeds[feedId].description = newDescription;
            }
            
            // Get description to emit
            string memory descriptionToEmit;
            if (bytes(newDescription).length > 0) {
                descriptionToEmit = newDescription;
            } else {
                descriptionToEmit = priceFeeds[feedId].description;
            }
            
            emit PriceFeedUpdated(
                feedId,
                oldFeedAddress,
                newFeedAddress,
                newHeartbeat,
                decimals,
                descriptionToEmit
            );
            
        } catch {
            revert InvalidFeedAddress(newFeedAddress);
        }
    }
    
    /**
     * @notice Deactivate a price feed
     * @param symbol The price pair symbol
     */
    function deactivatePriceFeed(string calldata symbol) external onlyRole(ADMIN_ROLE) {
        bytes32 feedId = symbolToFeedId[symbol];
        if (priceFeeds[feedId].feedProxyAddress == address(0)) revert FeedNotFound(feedId);
        
        priceFeeds[feedId].active = false;
        
        // Remove from active feeds array
        for (uint256 i = 0; i < activeFeedIds.length; i++) {
            if (activeFeedIds[i] == feedId) {
                activeFeedIds[i] = activeFeedIds[activeFeedIds.length - 1];
                activeFeedIds.pop();
                break;
            }
        }
        
        emit PriceFeedDeactivated(feedId, symbol);
    }

    // ============ Price Retrieval Functions ============
    
    /**
     * @notice Get the latest price for a symbol
     * @param symbol The price pair symbol (e.g., "BTC-USDT")
     * @return priceData Structured price information
     */
    function getLatestPrice(string calldata symbol) 
        external 
        view 
        whenNotPaused 
        returns (PriceData memory priceData) 
    {
        bytes32 feedId = symbolToFeedId[symbol];
        if (priceFeeds[feedId].feedProxyAddress == address(0)) revert FeedNotFound(feedId);
        if (!priceFeeds[feedId].active) revert FeedNotActive(feedId);
        
        PriceFeedConfig memory config = priceFeeds[feedId];
        IFeedProxy feed = IFeedProxy(config.feedProxyAddress);
        
        (uint64 roundId, int256 price, uint256 updatedAt) = feed.latestRoundData();
        
        // Validate price data
        if (price <= 0) revert InvalidPriceData(price);
        if (block.timestamp > updatedAt + config.heartbeatSeconds + MAX_STALENESS) {
            revert StalePriceData(updatedAt, config.heartbeatSeconds + MAX_STALENESS);
        }
        
        uint256 normalizedPrice = uint256(price);
        
        // Trust oracle data - no artificial price bounds
        priceData = PriceData({
            price: normalizedPrice,
            timestamp: updatedAt,
            roundId: roundId,
            valid: true
        });
    }

    // ============ View Functions ============
    
    /**
     * @notice Get all active feed symbols
     * @return symbols Array of active symbol strings
     */
    function getActiveFeedSymbols() external view returns (string[] memory symbols) {
        symbols = new string[](activeFeedIds.length);
        
        for (uint256 i = 0; i < activeFeedIds.length; i++) {
            symbols[i] = priceFeeds[activeFeedIds[i]].description;
        }
    }
    
    /**
     * @notice Check if a feed is supported and active
     * @param symbol The price pair symbol
     * @return supported Whether the feed is supported and active
     */
    function isFeedSupported(string calldata symbol) external view returns (bool supported) {
        bytes32 feedId = symbolToFeedId[symbol];
        supported = priceFeeds[feedId].feedProxyAddress != address(0) && priceFeeds[feedId].active;
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
}