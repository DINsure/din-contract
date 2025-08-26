// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/security/ReentrancyGuard.sol";
import "@kaiachain/contracts/token/ERC20/IERC20.sol";
import "@kaiachain/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FeeTreasury
 * @notice Manages protocol fee collection, distribution, and transparent accounting
 * @dev Receives protocol fees from various DIN protocol components and distributes to recipients
 */
contract FeeTreasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Structs ============
    struct Recipient {
        address recipient;
        uint256 basisPoints; // Allocation in basis points (10000 = 100%)
        bool active;
        string description;
    }

    struct TokenBalance {
        address token;
        uint256 totalReceived;
        uint256 totalDistributed;
        uint256 currentBalance;
        uint256 lastSweepTime;
    }

    struct FeeSource {
        address source;
        string description;
        uint256 totalFeesReceived;
        bool active;
    }

    // ============ Storage ============
    
    // Recipients configuration
    mapping(uint256 => Recipient) public recipients;
    uint256[] public recipientIds;
    uint256 public nextRecipientId = 1;
    uint256 public totalAllocationBps; // Total basis points allocated (should be <= 10000)
    
    // Token balances tracking
    mapping(address => TokenBalance) public tokenBalances;
    address[] public trackedTokens;
    
    // Fee sources tracking
    mapping(address => FeeSource) public feeSources;
    address[] public activeSources;
    
    // Sweep configuration
    uint256 public minimumSweepInterval = 1 hours;
    uint256 public lastGlobalSweep;
    
    // Emergency settings
    address public emergencyRecipient;
    bool public emergencyMode = false;

    // ============ Events ============
    event FeeReceived(
        address indexed source,
        address indexed token,
        uint256 amount,
        string sourceDescription
    );
    
    event FeesSwept(
        address indexed token,
        uint256 totalAmount,
        uint256 timestamp
    );
    
    event RecipientPaid(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        uint256 recipientId,
        string description
    );
    
    event RecipientAdded(
        uint256 indexed recipientId,
        address indexed recipient,
        uint256 basisPoints,
        string description
    );
    
    event RecipientUpdated(
        uint256 indexed recipientId,
        address indexed newRecipient,
        uint256 newBasisPoints,
        bool active
    );
    
    event FeeSourceRegistered(
        address indexed source,
        string description
    );
    
    event EmergencyModeToggled(bool enabled, address emergencyRecipient);
    
    event SweepIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    // ============ Custom Errors ============
    error ZeroAddress();
    error InvalidBasisPoints(uint256 basisPoints);
    error TotalAllocationExceeded(uint256 total, uint256 max);
    error RecipientNotFound(uint256 recipientId);
    error SweepTooFrequent(uint256 lastSweep, uint256 minInterval);
    error NoBalanceToSweep(address token);
    error UnauthorizedSource(address source);
    error EmergencyModeActive();
    error InvalidAllocation();

    // ============ Constructor ============
    constructor(
        address _admin,
        address _emergencyRecipient,
        string memory _emergencyDescription
    ) {
        if (_admin == address(0) || _emergencyRecipient == address(0)) revert ZeroAddress();
        
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        
        emergencyRecipient = _emergencyRecipient;
        
        // Add emergency recipient as default with 100% allocation
        _addRecipient(_emergencyRecipient, 10000, _emergencyDescription);
        
        lastGlobalSweep = block.timestamp;
    }

    // ============ Fee Reception Functions ============
    
    /**
     * @notice Receive protocol fees from authorized sources
     * @param token The token address
     * @param amount The amount of fees
     * @param sourceDescription Description of the fee source
     */
    function receiveFees(
        address token,
        uint256 amount,
        string calldata sourceDescription
    ) external whenNotPaused nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        
        // Verify source is registered (optional enforcement)
        if (feeSources[msg.sender].source == address(0)) {
            // Auto-register new sources with basic description
            _registerFeeSource(msg.sender, sourceDescription);
        }
        
        // Transfer tokens to treasury
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update tracking
        _updateTokenBalance(token, amount);
        _updateFeeSource(msg.sender, amount);
        
        emit FeeReceived(msg.sender, token, amount, sourceDescription);
    }
    
    /**
     * @notice Receive ETH fees (if needed)
     */
    receive() external payable whenNotPaused {
        if (msg.value > 0) {
            _updateTokenBalance(address(0), msg.value); // Track ETH as address(0)
            _updateFeeSource(msg.sender, msg.value);
            emit FeeReceived(msg.sender, address(0), msg.value, "ETH fee");
        }
    }

    // ============ Distribution Functions ============
    
    /**
     * @notice Sweep fees for a specific token to recipients
     * @param token The token to sweep (address(0) for ETH)
     */
    function sweepToken(address token) external onlyRole(TREASURY_ROLE) whenNotPaused nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        
        uint256 balance = _getTokenBalance(token);
        if (balance == 0) revert NoBalanceToSweep(token);
        
        // Check minimum interval
        TokenBalance storage tokenData = tokenBalances[token];
        if (block.timestamp < tokenData.lastSweepTime + minimumSweepInterval) {
            revert SweepTooFrequent(tokenData.lastSweepTime, minimumSweepInterval);
        }
        
        _distributeFees(token, balance);
    }
    
    /**
     * @notice Sweep all tracked tokens
     */
    function sweepAllTokens() external onlyRole(TREASURY_ROLE) whenNotPaused nonReentrant {
        if (emergencyMode) revert EmergencyModeActive();
        
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            address token = trackedTokens[i];
            uint256 balance = _getTokenBalance(token);
            
            if (balance > 0) {
                TokenBalance storage tokenData = tokenBalances[token];
                if (block.timestamp >= tokenData.lastSweepTime + minimumSweepInterval) {
                    _distributeFees(token, balance);
                }
            }
        }
        
        lastGlobalSweep = block.timestamp;
    }
    
    /**
     * @notice Emergency sweep all funds to emergency recipient
     */
    function emergencySweep(address token) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(emergencyMode, "Emergency mode not active");
        
        uint256 balance = _getTokenBalance(token);
        if (balance > 0) {
            if (token == address(0)) {
                // ETH transfer
                (bool success, ) = emergencyRecipient.call{value: balance}("");
                require(success, "ETH transfer failed");
            } else {
                // ERC20 transfer
                IERC20(token).safeTransfer(emergencyRecipient, balance);
            }
            
            TokenBalance storage tokenData = tokenBalances[token];
            tokenData.totalDistributed += balance;
            tokenData.currentBalance = 0;
            tokenData.lastSweepTime = block.timestamp;
            
            emit RecipientPaid(emergencyRecipient, token, balance, 0, "Emergency sweep");
            emit FeesSwept(token, balance, block.timestamp);
        }
    }

    // ============ Configuration Functions ============
    
    /**
     * @notice Add a new fee recipient
     * @param recipient The recipient address
     * @param basisPoints Allocation in basis points (10000 = 100%)
     * @param description Description of the recipient
     */
    function addRecipient(
        address recipient,
        uint256 basisPoints,
        string calldata description
    ) external onlyRole(ADMIN_ROLE) {
        _addRecipient(recipient, basisPoints, description);
    }
    
    /**
     * @notice Update an existing recipient
     * @param recipientId The recipient ID to update
     * @param newRecipient New recipient address
     * @param newBasisPoints New allocation in basis points
     * @param active Whether the recipient is active
     */
    function updateRecipient(
        uint256 recipientId,
        address newRecipient,
        uint256 newBasisPoints,
        bool active
    ) external onlyRole(ADMIN_ROLE) {
        if (recipients[recipientId].recipient == address(0)) revert RecipientNotFound(recipientId);
        if (newRecipient == address(0)) revert ZeroAddress();
        if (newBasisPoints > 10000) revert InvalidBasisPoints(newBasisPoints);
        
        // Update total allocation
        uint256 oldBps = recipients[recipientId].basisPoints;
        if (recipients[recipientId].active) {
            totalAllocationBps -= oldBps;
        }
        
        if (active) {
            totalAllocationBps += newBasisPoints;
            if (totalAllocationBps > 10000) {
                revert TotalAllocationExceeded(totalAllocationBps, 10000);
            }
        }
        
        recipients[recipientId].recipient = newRecipient;
        recipients[recipientId].basisPoints = newBasisPoints;
        recipients[recipientId].active = active;
        
        emit RecipientUpdated(recipientId, newRecipient, newBasisPoints, active);
    }
    
    /**
     * @notice Register a fee source
     * @param source The source contract address
     * @param description Description of the source
     */
    function registerFeeSource(
        address source,
        string calldata description
    ) external onlyRole(ADMIN_ROLE) {
        _registerFeeSource(source, description);
    }
    
    /**
     * @notice Set minimum sweep interval
     * @param newInterval New minimum interval in seconds
     */
    function setMinimumSweepInterval(uint256 newInterval) external onlyRole(ADMIN_ROLE) {
        require(newInterval >= 10 minutes && newInterval <= 7 days, "Invalid interval");
        uint256 oldInterval = minimumSweepInterval;
        minimumSweepInterval = newInterval;
        emit SweepIntervalUpdated(oldInterval, newInterval);
    }
    
    /**
     * @notice Toggle emergency mode
     * @param enabled Whether emergency mode should be enabled
     */
    function setEmergencyMode(bool enabled) external onlyRole(ADMIN_ROLE) {
        emergencyMode = enabled;
        emit EmergencyModeToggled(enabled, emergencyRecipient);
    }
    
    /**
     * @notice Update emergency recipient
     * @param newEmergencyRecipient New emergency recipient address
     */
    function setEmergencyRecipient(address newEmergencyRecipient) external onlyRole(ADMIN_ROLE) {
        if (newEmergencyRecipient == address(0)) revert ZeroAddress();
        emergencyRecipient = newEmergencyRecipient;
    }

    // ============ Internal Functions ============
    
    /**
     * @notice Internal function to add a recipient
     */
    function _addRecipient(
        address recipient,
        uint256 basisPoints,
        string memory description
    ) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (basisPoints == 0 || basisPoints > 10000) revert InvalidBasisPoints(basisPoints);
        
        if (totalAllocationBps + basisPoints > 10000) {
            revert TotalAllocationExceeded(totalAllocationBps + basisPoints, 10000);
        }
        
        uint256 recipientId = nextRecipientId++;
        recipients[recipientId] = Recipient({
            recipient: recipient,
            basisPoints: basisPoints,
            active: true,
            description: description
        });
        
        recipientIds.push(recipientId);
        totalAllocationBps += basisPoints;
        
        emit RecipientAdded(recipientId, recipient, basisPoints, description);
    }
    
    /**
     * @notice Internal function to register a fee source
     */
    function _registerFeeSource(address source, string memory description) internal {
        if (feeSources[source].source == address(0)) {
            feeSources[source] = FeeSource({
                source: source,
                description: description,
                totalFeesReceived: 0,
                active: true
            });
            activeSources.push(source);
            emit FeeSourceRegistered(source, description);
        }
    }
    
    /**
     * @notice Internal function to update token balance tracking
     */
    function _updateTokenBalance(address token, uint256 amount) internal {
        TokenBalance storage balance = tokenBalances[token];
        
        if (balance.token == address(0) && token != address(0)) {
            // First time tracking this token
            balance.token = token;
            trackedTokens.push(token);
        }
        
        balance.totalReceived += amount;
        balance.currentBalance += amount;
    }
    
    /**
     * @notice Internal function to update fee source tracking
     */
    function _updateFeeSource(address source, uint256 amount) internal {
        FeeSource storage sourceData = feeSources[source];
        sourceData.totalFeesReceived += amount;
    }
    
    /**
     * @notice Internal function to get token balance
     */
    function _getTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
    
    /**
     * @notice Internal function to distribute fees to recipients
     */
    function _distributeFees(address token, uint256 totalAmount) internal {
        require(totalAmount > 0, "No amount to distribute");
        
        uint256 distributed = 0;
        
        // Distribute to each active recipient
        for (uint256 i = 0; i < recipientIds.length; i++) {
            uint256 recipientId = recipientIds[i];
            Recipient storage recipient = recipients[recipientId];
            
            if (recipient.active && recipient.basisPoints > 0) {
                uint256 amount = (totalAmount * recipient.basisPoints) / totalAllocationBps;
                
                if (amount > 0) {
                    if (token == address(0)) {
                        // ETH transfer
                        (bool success, ) = recipient.recipient.call{value: amount}("");
                        require(success, "ETH transfer failed");
                    } else {
                        // ERC20 transfer
                        IERC20(token).safeTransfer(recipient.recipient, amount);
                    }
                    
                    distributed += amount;
                    emit RecipientPaid(recipient.recipient, token, amount, recipientId, recipient.description);
                }
            }
        }
        
        // Handle any dust (rounding errors)
        uint256 dust = totalAmount - distributed;
        if (dust > 0 && recipientIds.length > 0) {
            // Send dust to first active recipient
            for (uint256 i = 0; i < recipientIds.length; i++) {
                uint256 recipientId = recipientIds[i];
                Recipient storage recipient = recipients[recipientId];
                
                if (recipient.active) {
                    if (token == address(0)) {
                        (bool success, ) = recipient.recipient.call{value: dust}("");
                        require(success, "Dust ETH transfer failed");
                    } else {
                        IERC20(token).safeTransfer(recipient.recipient, dust);
                    }
                    break;
                }
            }
        }
        
        // Update tracking
        TokenBalance storage tokenData = tokenBalances[token];
        tokenData.totalDistributed += totalAmount;
        tokenData.currentBalance = _getTokenBalance(token);
        tokenData.lastSweepTime = block.timestamp;
        
        emit FeesSwept(token, totalAmount, block.timestamp);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get all recipients
     */
    function getAllRecipients() external view returns (uint256[] memory ids, Recipient[] memory recipientList) {
        ids = recipientIds;
        recipientList = new Recipient[](recipientIds.length);
        
        for (uint256 i = 0; i < recipientIds.length; i++) {
            recipientList[i] = recipients[recipientIds[i]];
        }
    }
    
    /**
     * @notice Get tracked tokens and their balances
     */
    function getTokenBalances() external view returns (address[] memory tokens, TokenBalance[] memory balances) {
        tokens = trackedTokens;
        balances = new TokenBalance[](trackedTokens.length);
        
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            balances[i] = tokenBalances[trackedTokens[i]];
            balances[i].currentBalance = _getTokenBalance(trackedTokens[i]); // Get real-time balance
        }
    }
    
    /**
     * @notice Get active fee sources
     */
    function getFeeSources() external view returns (address[] memory sources, FeeSource[] memory sourceData) {
        sources = activeSources;
        sourceData = new FeeSource[](activeSources.length);
        
        for (uint256 i = 0; i < activeSources.length; i++) {
            sourceData[i] = feeSources[activeSources[i]];
        }
    }
    
    /**
     * @notice Check if a token can be swept
     * @param token The token to check
     */
    function canSweepToken(address token) external view returns (bool, string memory reason) {
        if (emergencyMode) return (false, "Emergency mode active");
        
        uint256 balance = _getTokenBalance(token);
        if (balance == 0) return (false, "No balance");
        
        TokenBalance storage tokenData = tokenBalances[token];
        if (block.timestamp < tokenData.lastSweepTime + minimumSweepInterval) {
            return (false, "Too frequent");
        }
        
        return (true, "");
    }

    // ============ Admin Functions ============
    
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
