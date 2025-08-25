# din-contract
Smart contract of DIN
https://dinsure.app

## Introduction

This repository contains a Hardhat-based smart contract workspace targeting the Kaia Kairos testnet.
It includes the complete DIN protocol modular architecture with sophisticated insurance pool management, oracle-based settlement, and decentralized governance.

## Architecture

Modular design with isolated components for scalability and upgradability

- **DinRegistry**: Central configuration hub for the entire protocol
- **TranchePoolCore**: Economics only (orders, collateral, NAV, premiums). Round lifecycle is owned by ProductCatalog.
- **TranchePoolFactory**: Deploy pools per tranche with proper integration
- **SettlementEngine**: Oracle integration + Settlement logic + Dispute handling
- **InsuranceToken**: ERC-721 tokens representing buyer insurance positions
- **ProductCatalog**: Product and tranche management with round lifecycle
- **FeeTreasury**: Protocol fee collection, distribution, and transparent accounting
- **Oracle System**: Dual oracle integration (Orakl Network + DINO optimistic oracle)
