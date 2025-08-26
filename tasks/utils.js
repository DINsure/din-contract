const { ethers } = require("hardhat");

/**
 * Setup wallet with private key from environment variables
 * This ensures tasks use the PRIVATE_KEY from .env file
 */
function setupWallet(hre) {
    require("dotenv").config();
    
    if (process.env.PRIVATE_KEY && hre.network.name !== "hardhat") {
        const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, ethers.provider);
        // Override getSigners to return our wallet
        const originalGetSigners = hre.ethers.getSigners;
        hre.ethers.getSigners = () => Promise.resolve([wallet]);
        return wallet;
    }
    
    return null;
}

/**
 * Get environment variables with fallbacks for common naming variations
 */
function getEnvAddresses() {
    require("dotenv").config();
    
    return {
        PRODUCT_CATALOG_ADDRESS: process.env.PRODUCT_CATALOG_ADDRESS,
        TRANCHE_POOL_FACTORY_ADDRESS: process.env.TRANCHE_POOL_FACTORY_ADDRESS,
        INSURANCE_TOKEN_ADDRESS: process.env.INSURANCE_TOKEN_ADDRESS,
        USDT_TOKEN_ADDRESS: process.env.USDT_TOKEN_ADDRESS || process.env.USDT_TOKEN_ADDRESS,
        SETTLEMENT_ENGINE_ADDRESS: process.env.SETTLEMENT_ENGINE_ADDRESS,
        ORACLE_ROUTER_ADDRESS: process.env.ORACLE_ROUTER_ADDRESS,
        DEPLOYER_ADDRESS: process.env.DEPLOYER_ADDRESS,
        PRIVATE_KEY: process.env.PRIVATE_KEY
    };
}

module.exports = {
    setupWallet,
    getEnvAddresses
};
