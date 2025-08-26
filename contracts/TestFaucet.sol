// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestFaucet
 * @notice Simple faucet for test environments. Dispenses fixed amounts of DIN and USDT
 *         to a caller at most once per hour. Owner funds the contract manually.
 */
contract TestFaucet {
    IERC20 public immutable dinToken;
    IERC20 public immutable usdtToken;

    // 1 hour cooldown per address
    uint256 public constant COOLDOWN_SECONDS = 3600;

    // Fixed dispense amounts (DIN 18 decimals, USDT 6 decimals)
    uint256 public constant DIN_AMOUNT = 100 ether;         // 100 DIN
    uint256 public constant USDT_AMOUNT = 1000 * 1e6;       // 1000 USDT (6 decimals)

    mapping(address => uint256) public lastClaimAt;

    event Claimed(address indexed account, uint256 dinAmount, uint256 usdtAmount, uint256 timestamp);

    error CooldownNotPassed(uint256 nextAllowedAt);
    error InsufficientFaucetBalance();

    constructor(address _dinToken, address _usdtToken) {
        require(_dinToken != address(0) && _usdtToken != address(0), "Zero address");
        dinToken = IERC20(_dinToken);
        usdtToken = IERC20(_usdtToken);
    }

    /**
     * @dev Performs an ERC20 transfer compatible with non-standard tokens (e.g., USDT) that do not return a boolean.
     * Succeeds if the low-level call succeeds and either returns no data or decodes to 'true'.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ERC20 transfer failed");
    }

    /**
     * @notice Claim faucet tokens (limited once per hour per address)
     */
    function claim() external {
        uint256 last = lastClaimAt[msg.sender];
        if (last != 0 && block.timestamp < last + COOLDOWN_SECONDS) {
            revert CooldownNotPassed(last + COOLDOWN_SECONDS);
        }

        // Check balances to avoid revert from token transfer
        if (dinToken.balanceOf(address(this)) < DIN_AMOUNT || usdtToken.balanceOf(address(this)) < USDT_AMOUNT) {
            revert InsufficientFaucetBalance();
        }

        lastClaimAt[msg.sender] = block.timestamp;

        // Transfer tokens using safe pattern to support non-standard ERC20s (like USDT)
        _safeTransfer(address(dinToken), msg.sender, DIN_AMOUNT);
        _safeTransfer(address(usdtToken), msg.sender, USDT_AMOUNT);

        emit Claimed(msg.sender, DIN_AMOUNT, USDT_AMOUNT, block.timestamp);
    }
}


