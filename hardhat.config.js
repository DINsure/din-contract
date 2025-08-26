require("@nomicfoundation/hardhat-toolbox");
require('dotenv').config();

const { KAIROS_TESTNET_URL = "", PRIVATE_KEY = "" } = process.env;

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1, // Lower runs for smaller bytecode size
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
          },
          viaIR: true,
        },
      },
    ],
  },
  networks: {
    kairos: {
      url: KAIROS_TESTNET_URL || "",
      gasPrice: 250000000000,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
};


