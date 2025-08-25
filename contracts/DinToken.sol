// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/token/ERC20/ERC20.sol";
import "@kaiachain/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@kaiachain/contracts/access/AccessControl.sol";
import "@kaiachain/contracts/security/Pausable.sol";

/**
 * @title DinToken
 * @notice DIN protocol governance and utility token
 * @dev ERC-20 token with mint/burn functionality, access control, and pausable features
 */
contract DinToken is ERC20, ERC20Burnable, AccessControl, Pausable {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Token details
    uint8 private constant DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**DECIMALS; // 1 billion DIN

    // Events
    event TokensMinted(address indexed to, uint256 amount, address indexed minter);
    event TokensBurned(address indexed from, uint256 amount, address indexed burner);
    event MaxSupplyReached(uint256 totalSupply);

    // Custom errors
    error ExceedsMaxSupply(uint256 requestedAmount, uint256 availableAmount);
    error ZeroAddress();
    error ZeroAmount();

    /**
     * @dev Constructor
     * @param admin Address to grant admin role
     * @param initialSupply Initial token supply (in whole tokens, will be multiplied by decimals)
     */
    constructor(
        address admin,
        uint256 initialSupply
    ) 
        ERC20("DIN Token", "DIN") 
    {
        if (admin == address(0)) revert ZeroAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);

        if (initialSupply > 0) {
            uint256 initialSupplyWithDecimals = initialSupply * 10**DECIMALS;
            if (initialSupplyWithDecimals > MAX_SUPPLY) {
                revert ExceedsMaxSupply(initialSupplyWithDecimals, MAX_SUPPLY);
            }
            _mint(admin, initialSupplyWithDecimals);
            emit TokensMinted(admin, initialSupplyWithDecimals, admin);
        }
    }

    /**
     * @notice Returns the number of decimals used by the token
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Mint new tokens
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (in smallest unit)
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        uint256 newTotalSupply = totalSupply() + amount;
        if (newTotalSupply > MAX_SUPPLY) {
            revert ExceedsMaxSupply(amount, MAX_SUPPLY - totalSupply());
        }

        _mint(to, amount);
        emit TokensMinted(to, amount, msg.sender);

        if (newTotalSupply == MAX_SUPPLY) {
            emit MaxSupplyReached(newTotalSupply);
        }
    }

    /**
     * @notice Burn tokens from a specific address (requires BURNER_ROLE)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyRole(BURNER_ROLE) whenNotPaused {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        super.burnFrom(from, amount);
        emit TokensBurned(from, amount, msg.sender);
    }

    /**
     * @notice Burn tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) public override whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        
        super.burn(amount);
        emit TokensBurned(msg.sender, amount, msg.sender);
    }

    /**
     * @notice Pause token transfers
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     */
    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Get remaining mintable supply
     * @return Amount of tokens that can still be minted
     */
    function remainingMintableSupply() public view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /**
     * @notice Check if max supply has been reached
     * @return True if total supply equals max supply
     */
    function isMaxSupplyReached() public view returns (bool) {
        return totalSupply() == MAX_SUPPLY;
    }

    // Required overrides for multiple inheritance

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
