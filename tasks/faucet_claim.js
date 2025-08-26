const { task, types } = require("hardhat/config");

// Claim tokens from TestFaucet
// Requires FAUCET_ADDRESS in .env

task("faucet-claim", "Claim 100 DIN and 1000 USDT from the TestFaucet")
  .addOptionalParam("faucet", "Faucet contract address (defaults to FAUCET_ADDRESS from .env)", undefined, types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    const FAUCET_ADDRESS = taskArgs.faucet || process.env.FAUCET_ADDRESS;
    if (!FAUCET_ADDRESS) {
      throw new Error("Please set FAUCET_ADDRESS in your .env or pass --faucet <address>");
    }

    const [signer] = await ethers.getSigners();
    console.log("\n🚰 Faucet Claim");
    console.log("=".repeat(60));
    console.log(`👤 Caller: ${signer.address}`);
    console.log(`📍 Faucet: ${FAUCET_ADDRESS}`);

    const faucet = await ethers.getContractAt("TestFaucet", FAUCET_ADDRESS);

    try {
      console.log("\n📤 Sending claim()...");
      const tx = await faucet.claim();
      const receipt = await tx.wait();
      console.log(`✅ Claimed successfully. Gas used: ${receipt.gasUsed}`);

      // Try decoding event best-effort
      try {
        const iface = faucet.interface;
        for (const log of receipt.logs) {
          try {
            const parsed = iface.parseLog(log);
            if (parsed && parsed.name === "Claimed") {
              const din = parsed.args[1];
              const usdt = parsed.args[2];
              console.log(`   🎁 DIN:  ${ethers.formatEther(din)} DIN`);
              console.log(`   💵 USDT: ${ethers.formatUnits(usdt, 6)} USDT`);
            }
          } catch {}
        }
      } catch {}

      console.log("\n📝 Note: You can claim once per hour per address.");
    } catch (e) {
      console.log(`❌ Claim failed: ${e.message}`);
      throw e;
    }
  });

module.exports = {};


