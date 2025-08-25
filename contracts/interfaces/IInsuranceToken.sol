// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@kaiachain/contracts/token/ERC721/IERC721.sol";

interface IInsuranceToken is IERC721 {
    function mintInsuranceToken(
        address to,
        uint256 trancheId,
        uint256 roundId,
        uint256 purchaseAmount
    ) external returns (uint256 tokenId);
    
    function getTokenInfo(uint256 tokenId) external view returns (
        uint256 trancheId,
        uint256 roundId,
        uint256 purchaseAmount,
        address originalBuyer
    );
    
    function isTransferable(uint256 tokenId) external view returns (bool);
}
