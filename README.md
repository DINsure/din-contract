# din-contract
Smart contract of DIN

https://dinsure.app

## Introduction

This repository contains a Hardhat-based smart contract workspace targeting the Kaia Kairos testnet.
It includes the complete DIN protocol modular architecture with sophisticated insurance pool management, oracle-based settlement, and decentralized governance.

## How this works

Modular design with isolated components for scalability and upgradability

- **DinRegistry**: Central configuration hub for the entire protocol
- **TranchePoolCore**: Economics only (orders, collateral, NAV, premiums). Round lifecycle is owned by ProductCatalog.
- **TranchePoolFactory**: Deploy pools per tranche with proper integration
- **SettlementEngine**: Oracle integration + Settlement logic + Dispute handling
- **InsuranceToken**: ERC-721 tokens representing buyer insurance positions
- **ProductCatalog**: Product and tranche management with round lifecycle
- **FeeTreasury**: Protocol fee collection, distribution, and transparent accounting
- **Oracle System**: Dual oracle integration (Orakl Network + DINO optimistic oracle)

## Contract Architecture

**Core Contracts**
- `ProductCatalog`: Single Source of Truth for round states and tranche specifications
- `TranchePoolCore`: Economics-only (orders, collateral, NAV, premiums, auto-refunds)
- `SettlementEngine`: Oracle integration and payout distribution
- `DinRegistry`: Central configuration registry for all contract addresses

**Oracle System**
- `OracleRouter`: Unified interface routing between Orakl Network and DINO Oracle
- `OraklPriceFeed`: External price feeds from Orakl Network (8 decimals)
- `DinoOracle`: Internal optimistic oracle with DIN token governance (8 decimals)

**Decimal Precision**
- `USDT`: 6 decimals (all amounts, premiums, collateral)
- `Oracle Prices`: 8 decimals (both Orakl and DINO)
- `Trigger Prices`: 18 decimals (stored in ProductCatalog, auto-converted for settlement)
- `DIN Token`: 18 decimals (standard ERC20)

## Contract Address

TBA


## Prerequisites

- Node.js 18+ and npm
- A Kaia Kairos RPC endpoint
- A funded Kairos testnet account (Kaia Wallet, MetaMask or similar)
