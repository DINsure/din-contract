// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IProductCatalog {
    // Match enums with ProductCatalog.sol
    enum TriggerType { PRICE_BELOW, PRICE_ABOVE, RELATIVE, BOOLEAN, CUSTOM }
    enum RoundState { ANNOUNCED, OPEN, ACTIVE, MATURED, SETTLED, CANCELED }

    struct TrancheSpec {
        uint256 trancheId;
        uint256 productId;
        TriggerType triggerType;
        uint256 threshold;
        uint256 maturityTimestamp;
        uint256 premiumRateBps;
        uint256 perAccountMin;
        uint256 perAccountMax;
        uint256 trancheCap;
        uint256 oracleRouteId;
        bool active;
        uint256 createdAt;
        uint256 updatedAt;
        uint256[] roundIds;
    }

    struct Round {
        uint256 roundId;
        uint256 trancheId;
        uint256 salesStartTime;
        uint256 salesEndTime;
        RoundState state;
        uint256 totalBuyerPurchases;
        uint256 totalSellerCollateral;
        uint256 matchedAmount;
        uint256 createdAt;
        uint256 stateChangedAt;
    }

    function getTranche(uint256 trancheId) external view returns (TrancheSpec memory);
    function getRound(uint256 roundId) external view returns (Round memory);
    function updateRoundState(uint256 roundId, RoundState newState) external;
    function closeAndMarkMatched(uint256 roundId, uint256 matchedAmount) external;
}
