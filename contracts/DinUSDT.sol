// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/access/Ownable.sol";
import "@kaiachain/contracts/security/Pausable.sol";
import "@kaiachain/contracts/token/ERC20/IERC20.sol";

/**
 * @title IERC20NonStandard
 * @dev Interface for non-standard ERC20 tokens like USDT that don't return booleans
 */
interface IERC20NonStandard {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external; // No return value!
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external; // No return value!
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title DinUSDT
 * @notice Tether-style USDT token for DIN protocol
 * @dev Based on the original Tether token architecture with modern Solidity practices
 * 
 * IMPORTANT COMPATIBILITY NOTE:
 * This contract intentionally implements the same non-standard ERC20 behavior as the real USDT:
 * - transfer() and transferFrom() do NOT return boolean values
 * - This matches the actual USDT contract deployed on Ethereum mainnet
 * - Many DeFi protocols have had to implement workarounds for this non-standard behavior
 * - This implementation helps test real-world integration scenarios
 */
contract DinUSDT is IERC20NonStandard, Ownable, Pausable {
    // Token metadata
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 private _totalSupply;

    // Balances and allowances
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Transaction fee variables
    uint256 public basisPointsRate = 0;
    uint256 public maximumFee = 0;

    // Blacklist functionality
    mapping(address => bool) public isBlackListed;

    // Deprecation functionality
    address public upgradedAddress;
    bool public deprecated;

    // Constants
    uint256 public constant MAX_UINT = 2**256 - 1;

    // Events
    event Issue(uint256 amount);
    event Redeem(uint256 amount);
    event Deprecate(address newAddress);
    event Params(uint256 feeBasisPoints, uint256 maxFee);
    event DestroyedBlackFunds(address _blackListedUser, uint256 _balance);
    event AddedBlackList(address _user);
    event RemovedBlackList(address _user);

    // Custom errors
    error ZeroAddress();
    error BlacklistedAddress(address account);
    error DeprecatedContract();
    error InvalidFeeParameters();
    error InsufficientBalance();
    error InsufficientAllowance();

    /**
     * @dev Constructor
     * @param _initialSupply Initial supply in smallest units
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _decimals Number of decimals
     */
    constructor(
        uint256 _initialSupply,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        _totalSupply = _initialSupply;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        _balances[owner()] = _initialSupply;
        deprecated = false;
        emit Transfer(address(0), owner(), _initialSupply);
    }

    /**
     * @dev Returns the total supply
     */
    function totalSupply() public view returns (uint256) {
        if (deprecated) {
            return IERC20(upgradedAddress).totalSupply();
        } else {
            return _totalSupply;
        }
    }

    /**
     * @dev Returns the balance of an account
     */
    function balanceOf(address account) public view returns (uint256) {
        if (deprecated) {
            return IERC20(upgradedAddress).balanceOf(account);
        } else {
            return _balances[account];
        }
    }

    /**
     * @dev Transfer tokens with blacklist and fee logic
     * @notice IMPORTANT: Does not return bool like real USDT (non-standard ERC20)
     */
    function transfer(address to, uint256 amount) public whenNotPaused {
        if (isBlackListed[msg.sender]) revert BlacklistedAddress(msg.sender);
        if (isBlackListed[to]) revert BlacklistedAddress(to);
        
        if (deprecated) {
            // Call legacy function on upgraded contract
            upgradedAddress.call(
                abi.encodeWithSignature("transferByLegacy(address,address,uint256)", msg.sender, to, amount)
            );
            return;
        }

        _transferWithFee(msg.sender, to, amount);
    }

    /**
     * @dev Transfer tokens from one account to another
     * @notice IMPORTANT: Does not return bool like real USDT (non-standard ERC20)
     */
    function transferFrom(address from, address to, uint256 amount) public whenNotPaused {
        if (isBlackListed[from]) revert BlacklistedAddress(from);
        if (isBlackListed[to]) revert BlacklistedAddress(to);
        if (isBlackListed[msg.sender]) revert BlacklistedAddress(msg.sender);
        
        if (deprecated) {
            // Call legacy function on upgraded contract
            upgradedAddress.call(
                abi.encodeWithSignature("transferFromByLegacy(address,address,address,uint256)", msg.sender, from, to, amount)
            );
            return;
        }

        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != MAX_UINT) {
            if (currentAllowance < amount) revert InsufficientAllowance();
            _allowances[from][msg.sender] = currentAllowance - amount;
        }

        _transferWithFee(from, to, amount);
    }

    /**
     * @dev Approve spender to transfer tokens
     */
    function approve(address spender, uint256 amount) public whenNotPaused returns (bool) {
        if (isBlackListed[msg.sender]) revert BlacklistedAddress(msg.sender);
        if (isBlackListed[spender]) revert BlacklistedAddress(spender);
        
        if (deprecated) {
            // Call legacy function on upgraded contract
            (bool success, ) = upgradedAddress.call(
                abi.encodeWithSignature("approveByLegacy(address,address,uint256)", msg.sender, spender, amount)
            );
            return success;
        }

        // Prevent approve from non-zero to non-zero (security measure)
        require(!(amount != 0 && _allowances[msg.sender][spender] != 0), "Approve from non-zero to non-zero");
        
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @dev Returns the allowance
     */
    function allowance(address owner, address spender) public view returns (uint256) {
        if (deprecated) {
            return IERC20(upgradedAddress).allowance(owner, spender);
        } else {
            return _allowances[owner][spender];
        }
    }

    /**
     * @dev Internal transfer with fee calculation
     */
    function _transferWithFee(address from, address to, uint256 amount) internal {
        if (_balances[from] < amount) revert InsufficientBalance();

        uint256 fee = (amount * basisPointsRate) / 10000;
        if (fee > maximumFee) {
            fee = maximumFee;
        }
        
        uint256 sendAmount = amount - fee;
        
        _balances[from] -= amount;
        _balances[to] += sendAmount;
        
        if (fee > 0) {
            _balances[owner()] += fee;
            emit Transfer(from, owner(), fee);
        }
        
        emit Transfer(from, to, sendAmount);
    }

    // ============ Owner Functions ============

    /**
     * @dev Issue new tokens (mint)
     * @param amount Amount to mint
     */
    function issue(uint256 amount) public onlyOwner {
        require(_totalSupply + amount > _totalSupply, "Overflow check");
        require(_balances[owner()] + amount > _balances[owner()], "Overflow check");

        _balances[owner()] += amount;
        _totalSupply += amount;
        emit Issue(amount);
        emit Transfer(address(0), owner(), amount);
    }

    /**
     * @dev Redeem tokens (burn)
     * @param amount Amount to burn
     */
    function redeem(uint256 amount) public onlyOwner {
        require(_totalSupply >= amount, "Insufficient total supply");
        require(_balances[owner()] >= amount, "Insufficient balance");

        _totalSupply -= amount;
        _balances[owner()] -= amount;
        emit Redeem(amount);
        emit Transfer(owner(), address(0), amount);
    }

    /**
     * @dev Set transaction fee parameters
     * @param newBasisPoints New basis points for fee (1 basis point = 0.01%)
     * @param newMaxFee New maximum fee
     */
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) public onlyOwner {
        require(newBasisPoints < 20, "Fee too high"); // Max 0.2%
        require(newMaxFee < 50 * 10**uint256(decimals), "Max fee too high");

        basisPointsRate = newBasisPoints;
        maximumFee = newMaxFee * 10**uint256(decimals);

        emit Params(basisPointsRate, maximumFee);
    }

    // ============ Blacklist Functions ============

    /**
     * @dev Get blacklist status
     * @param _maker Address to check
     * @return blacklist status
     */
    function getBlackListStatus(address _maker) external view returns (bool) {
        return isBlackListed[_maker];
    }

    /**
     * @dev Add address to blacklist
     * @param _evilUser Address to blacklist
     */
    function addBlackList(address _evilUser) public onlyOwner {
        isBlackListed[_evilUser] = true;
        emit AddedBlackList(_evilUser);
    }

    /**
     * @dev Remove address from blacklist
     * @param _clearedUser Address to remove from blacklist
     */
    function removeBlackList(address _clearedUser) public onlyOwner {
        isBlackListed[_clearedUser] = false;
        emit RemovedBlackList(_clearedUser);
    }

    /**
     * @dev Destroy funds of blacklisted address
     * @param _blackListedUser Blacklisted address
     */
    function destroyBlackFunds(address _blackListedUser) public onlyOwner {
        require(isBlackListed[_blackListedUser], "Address not blacklisted");
        uint256 dirtyFunds = _balances[_blackListedUser];
        _balances[_blackListedUser] = 0;
        _totalSupply -= dirtyFunds;
        emit DestroyedBlackFunds(_blackListedUser, dirtyFunds);
    }

    // ============ Deprecation Functions ============

    /**
     * @dev Deprecate current contract in favor of a new one
     * @param _upgradedAddress Address of the new contract
     */
    function deprecate(address _upgradedAddress) public onlyOwner {
        if (_upgradedAddress == address(0)) revert ZeroAddress();
        deprecated = true;
        upgradedAddress = _upgradedAddress;
        emit Deprecate(_upgradedAddress);
    }

    /**
     * @dev Check if contract is deprecated
     * @return deprecation status
     */
    function isDeprecated() public view returns (bool) {
        return deprecated;
    }

    /**
     * @dev Get upgraded contract address
     * @return upgraded contract address
     */
    function getUpgradedAddress() public view returns (address) {
        return upgradedAddress;
    }

    // ============ Pausable Functions ============

    /**
     * @dev Pause the contract
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() public onlyOwner {
        _unpause();
    }
}