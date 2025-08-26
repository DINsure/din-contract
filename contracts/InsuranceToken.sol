// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/token/ERC721/ERC721.sol";
import "@kaiachain/contracts/access/AccessControl.sol";
import "./interfaces/IInsuranceToken.sol";

/**
 * @title InsuranceToken
 * @notice ERC-721 tokens representing insurance positions
 * @dev Minted when buyers purchase insurance coverage, transferable before settlement
 */
contract InsuranceToken is ERC721, AccessControl, IInsuranceToken {
    // ============ Constants ============
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ============ Enums ============
    enum RoundState { ANNOUNCED, OPEN, MATCHED, ACTIVE, MATURED, SETTLED, CANCELED }

    // ============ Structs ============
    struct TokenInfo {
        uint256 trancheId;
        uint256 roundId;
        uint256 purchaseAmount;
        address originalBuyer;
        address tranchePool;
        uint256 mintTimestamp;
    }

    // ============ Storage ============
    mapping(uint256 => TokenInfo) public tokenInfo;
    mapping(address => bool) public authorizedPools; // TranchePool addresses that can mint
    uint256 public nextTokenId = 1;

    // ============ Events ============
    event InsuranceTokenMinted(
        uint256 indexed tokenId,
        uint256 indexed trancheId,
        uint256 indexed roundId,
        address buyer,
        uint256 purchaseAmount,
        address tranchePool
    );
    
    event PoolAuthorized(address indexed pool, bool authorized);

    // ============ Constructor ============
    constructor(address _admin) ERC721("DIN Insurance Token", "DIN-INSURANCE") {
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Authorize a TranchePool to mint tokens
     * @param pool The TranchePool address
     * @param authorized Whether the pool is authorized
     */
    function setPoolAuthorization(address pool, bool authorized) external onlyRole(ADMIN_ROLE) {
        authorizedPools[pool] = authorized;
        if (authorized) {
            _grantRole(MINTER_ROLE, pool);
        } else {
            _revokeRole(MINTER_ROLE, pool);
        }
        emit PoolAuthorized(pool, authorized);
    }

    // ============ Minting Functions ============
    
    /**
     * @notice Mint an insurance token (called by authorized TranchePool)
     * @param to The buyer address
     * @param trancheId The tranche ID
     * @param roundId The round ID
     * @param purchaseAmount The purchase amount
     * @return tokenId The minted token ID
     */
    function mintInsuranceToken(
        address to,
        uint256 trancheId,
        uint256 roundId,
        uint256 purchaseAmount
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        require(authorizedPools[msg.sender], "Unauthorized pool");
        require(to != address(0), "Cannot mint to zero address");
        require(purchaseAmount > 0, "Purchase amount must be positive");
        
        tokenId = nextTokenId++;
        
        // Store token information
        tokenInfo[tokenId] = TokenInfo({
            trancheId: trancheId,
            roundId: roundId,
            purchaseAmount: purchaseAmount,
            originalBuyer: to,
            tranchePool: msg.sender,
            mintTimestamp: block.timestamp
        });
        
        // Mint the token
        _mint(to, tokenId);
        
        emit InsuranceTokenMinted(tokenId, trancheId, roundId, to, purchaseAmount, msg.sender);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get token information
     * @param tokenId The token ID
     */
    function getTokenInfo(uint256 tokenId) external view returns (
        uint256 trancheId,
        uint256 roundId,
        uint256 purchaseAmount,
        address originalBuyer
    ) {
        TokenInfo storage info = tokenInfo[tokenId];
        return (info.trancheId, info.roundId, info.purchaseAmount, info.originalBuyer);
    }
    
    /**
     * @notice Check if token is transferable
     * @param tokenId The token to check
     */
    function isTransferable(uint256 tokenId) public view returns (bool) {
        // Tokens are transferable before settlement
        // In a real implementation, this would check the round state from the TranchePool
        return _exists(tokenId);
    }
    
    /**
     * @notice Get token URI with metadata
     * @param tokenId The token ID
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        
        TokenInfo storage info = tokenInfo[tokenId];
        
        // Return JSON metadata
        return string(abi.encodePacked(
            '{"name":"DIN Insurance Token #', 
            _toString(tokenId),
            '","description":"Insurance position for tranche ',
            _toString(info.trancheId),
            ' round ',
            _toString(info.roundId),
            '","attributes":[',
            '{"trait_type":"Purchase Amount","value":"',
            _toString(info.purchaseAmount),
            '"},',
            '{"trait_type":"Tranche","value":"',
            _toString(info.trancheId),
            '"},',
            '{"trait_type":"Round","value":"',
            _toString(info.roundId),
            '"},',
            '{"trait_type":"Original Buyer","value":"',
            _toHexString(uint256(uint160(info.originalBuyer)), 20),
            '"}',
            ']}'
        ));
    }

    // ============ Transfer Override ============
    
    /**
     * @notice Override transfer to check transferability
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        if (from != address(0) && to != address(0)) { // Skip mint/burn
            require(isTransferable(tokenId), "Token not transferable");
        }
        super._beforeTokenTransfer(from, to, tokenId);
    }

    // ============ Utility Functions ============
    
    /**
     * @notice Convert uint to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    /**
     * @notice Convert address to hex string
     */
    function _toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
    
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    // ============ Interface Support ============
    
    /**
     * @notice Override supportsInterface to include AccessControl
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(ERC721, AccessControl, IERC165) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
}
