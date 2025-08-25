// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IDinRegistry {
    function getUSDTToken() external view returns (address);
    function getDINToken() external view returns (address);
    function getProductCatalog() external view returns (address);
    function getFeeTreasury() external view returns (address);
    function getProtocolFeeBps() external view returns (uint256);
    function getContractAddress(bytes32 identifier) external view returns (address);
}
