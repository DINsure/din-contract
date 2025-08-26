const { task, types } = require("hardhat/config");

// ============================================================================
// MONITORING TASKS
// ============================================================================

task("monitor-pools", "Monitor pool health and TVL across all pools")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    const { setupWallet, getEnvAddresses } = require("./utils");
    
    console.log("🏊 Pool Health Monitor");
    console.log("=" .repeat(60));

    // Setup wallet and get environment variables
    setupWallet(hre);
    const env = getEnvAddresses();

    if (!env.TRANCHE_POOL_FACTORY_ADDRESS || !env.USDT_TOKEN_ADDRESS) {
        throw new Error("Please set TRANCHE_POOL_FACTORY_ADDRESS and USDT_TOKEN_ADDRESS (or USDT_TOKEN_ADDRESS) in your .env file");
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", env.TRANCHE_POOL_FACTORY_ADDRESS);
    const usdt = await ethers.getContractAt("DinUSDT", env.USDT_TOKEN_ADDRESS);

    try {
        // Get pool count first, then get all pools by index
        const poolCount = await tranchePoolFactory.getPoolCount();
        console.log(`\n🏊 Found ${poolCount} pool(s)`);
        
        // Get all pools by accessing the public allPools array
        const allPools = [];
        for (let i = 0; i < poolCount; i++) {
            try {
                const poolAddress = await tranchePoolFactory.allPools(i);
                allPools.push(poolAddress);
            } catch (error) {
                console.log(`Warning: Could not fetch pool at index ${i}`);
            }
        }

        if (allPools.length === 0) {
            console.log("\n⚠️  No pools found. Create pools first:");
            console.log("   npx hardhat create-pools");
            return;
        }

        let totalTVL = 0n;
        let totalAssets = 0n;
        let totalLockedAssets = 0n;

        console.log("\n📊 Pool Overview:");
        console.log("──────────────────────────────────────────────────");

        for (let i = 0; i < allPools.length; i++) {
            const poolAddress = allPools[i];
            const pool = await ethers.getContractAt("TranchePoolCore", poolAddress);
            
            try {
                const trancheInfo = await pool.getTrancheInfo();
                const poolAccounting = await pool.getPoolAccounting();
                const usdtBalance = await usdt.balanceOf(poolAddress);
                
                console.log(`\n🏊 Pool ${i}: Tranche ${trancheInfo.trancheId}`);
                console.log(`   💰 Total Assets: $${ethers.formatUnits(poolAccounting.totalAssets, 6)}`);
                console.log(`   🔒 Locked: $${ethers.formatUnits(poolAccounting.lockedAssets, 6)}`);
                console.log(`   💸 In Yield: $${ethers.formatUnits(poolAccounting.yieldDeposited || 0n, 6)}`);
                console.log(`   🎁 Yield Earned: $${ethers.formatUnits(poolAccounting.yieldEarned || 0n, 6)}`);
                console.log(`   💎 NAV/Share: ${ethers.formatEther(poolAccounting.navPerShare)}`);
                
                // Calculate utilization
                const utilization = poolAccounting.totalAssets > 0n ? 
                    (poolAccounting.lockedAssets * 10000n) / poolAccounting.totalAssets : 0n;
                console.log(`   📈 Utilization: ${Number(utilization) / 100}%`);
                
                // Health checks
                const balanceVsAccounting = poolAccounting.totalAssets - usdtBalance;
                const navHealth = poolAccounting.navPerShare;
                
                if (balanceVsAccounting !== 0n) {
                    console.log(`   ⚠️  Balance mismatch: ${ethers.formatUnits(balanceVsAccounting, 6)}`);
                }
                
                if (navHealth < ethers.parseEther("0.5") || navHealth > ethers.parseEther("2.0")) {
                    console.log(`   ⚠️  NAV unusual: ${ethers.formatEther(navHealth)}`);
                }
                
                totalTVL += usdtBalance;
                totalAssets += poolAccounting.totalAssets;
                totalLockedAssets += poolAccounting.lockedAssets;
                
            } catch (poolError) {
                console.log(`\n❌ Pool ${i}: Error reading pool data`);
                console.log(`   📍 Address: ${poolAddress}`);
                console.log(`   ⚠️  Error: ${poolError.message}`);
            }
        }

        console.log("\n" + "=" .repeat(60));
        console.log("📊 System Summary");
        console.log("=" .repeat(60));
        console.log(`💰 Total TVL: $${ethers.formatUnits(totalTVL, 6)}`);
        console.log(`📊 Total Assets (Accounting): $${ethers.formatUnits(totalAssets, 6)}`);
        console.log(`🔒 Total Locked Assets: $${ethers.formatUnits(totalLockedAssets, 6)}`);
        console.log(`💧 Total Available: $${ethers.formatUnits(totalAssets - totalLockedAssets, 6)}`);
        
        const overallUtilization = totalAssets > 0n ? 
            (totalLockedAssets * 10000n) / totalAssets : 0n;
        console.log(`📈 Overall Utilization: ${Number(overallUtilization) / 100}%`);

        console.log("\n📝 Health Status:");
        if (Number(overallUtilization) > 8000) { // > 80%
            console.log("⚠️  High utilization - consider expanding capacity");
        } else if (Number(overallUtilization) < 1000) { // < 10%
            console.log("💡 Low utilization - more marketing needed");
        } else {
            console.log("✅ Healthy utilization levels");
        }

    } catch (error) {
        console.error(`❌ Error: ${error.message}`);
        throw error;
    }
  });

task("monitor-tranches", "Monitor all tranches with auto-discovery and risk analysis")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🎯 Tranche Monitor with Auto-Discovery");
    console.log("=" .repeat(60));

    const PRODUCT_CATALOG_ADDRESS = process.env.PRODUCT_CATALOG_ADDRESS;
    const TRANCHE_POOL_FACTORY_ADDRESS = process.env.TRANCHE_POOL_FACTORY_ADDRESS;
    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;

    if (!PRODUCT_CATALOG_ADDRESS || !TRANCHE_POOL_FACTORY_ADDRESS) {
        throw new Error("Please set required contract addresses in your .env file");
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const productCatalog = await ethers.getContractAt("ProductCatalog", PRODUCT_CATALOG_ADDRESS);
    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", TRANCHE_POOL_FACTORY_ADDRESS);
    
    let oracleRouter;
    if (ORACLE_ROUTER_ADDRESS) {
        oracleRouter = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);
    }

    try {
        // Auto-discover all tranches
        const activeTranches = await productCatalog.getActiveTranches();
        console.log(`\n🔍 Auto-discovered ${activeTranches.length} active tranche(s)`);

        if (activeTranches.length === 0) {
            console.log("\n⚠️  No active tranches found. Register products first:");
            console.log("   npx hardhat register-products");
            return;
        }

        // Get current market prices for risk analysis
        let marketPrices = {};
        if (oracleRouter) {
            const symbols = ["BTC-USDT", "ETH-USDT", "KAIA-USDT"];
            console.log(`\n💰 Current Market Prices:`);
            for (const symbol of symbols) {
                try {
                    const identifier = ethers.keccak256(ethers.toUtf8Bytes(symbol));
                    const priceResult = await oracleRouter.getPrice(identifier);
                    const price = Number(ethers.formatUnits(priceResult.price, 8));
                    marketPrices[symbol] = price;
                    console.log(`   ${symbol}: $${price.toLocaleString()}`);
                } catch (priceError) {
                    console.log(`   ${symbol}: ❌ ${priceError.message}`);
                    marketPrices[symbol] = null;
                }
            }
        }

        let portfolioStats = {
            totalCapacity: 0,
            totalPremiumPool: 0,
            totalRevenue: 0,
            lowRisk: 0,
            mediumRisk: 0,
            highRisk: 0,
            triggered: 0
        };

        console.log("\n📊 Tranche Analysis:");
        console.log("──────────────────────────────────────────────────");

        for (let i = 0; i < activeTranches.length; i++) {
            const trancheId = activeTranches[i];
            
            try {
                const trancheSpec = await productCatalog.getTranche(trancheId);
                const poolAddress = await tranchePoolFactory.getTranchePool(trancheId);
                
                console.log(`\n🎯 Tranche ${trancheId}`);
                console.log(`   📍 Pool: ${poolAddress}`);
                
                const triggerPrice = Number(ethers.formatEther(trancheSpec.threshold));
                const trancheCap = Number(ethers.formatUnits(trancheSpec.trancheCap, 6));
                const premiumRate = Number(trancheSpec.premiumRateBps) / 100;
                const maturityTime = Number(trancheSpec.maturityTimestamp);
                const now = Math.floor(Date.now() / 1000);
                const daysToMaturity = (maturityTime - now) / (24 * 60 * 60);
                const annualizedYield = premiumRate * (365 / Math.max(daysToMaturity, 1));
                
                // Determine trigger direction based on TriggerType
                const triggerType = Number(trancheSpec.triggerType);
                const triggerDirection = triggerType === 0 ? "BELOW" : triggerType === 1 ? "ABOVE" : "OTHER";
                
                console.log(`   🎯 Trigger: $${triggerPrice.toLocaleString()} (${triggerDirection})`);
                console.log(`   💰 Premium Rate: ${premiumRate}%`);
                console.log(`   🏦 Capacity: $${trancheCap.toLocaleString()}`);
                console.log(`   📅 Maturity: ${new Date(maturityTime * 1000).toLocaleString()}`);
                console.log(`   ⏰ Days to Maturity: ${daysToMaturity.toFixed(1)}`);
                console.log(`   📈 Annualized Yield: ${annualizedYield.toFixed(2)}%`);
                
                // Risk analysis - determine which oracle identifier to use
                let riskLevel = "Unknown";
                let riskColor = "⚪";
                
                // Determine relevant market price based on oracle route ID or product type
                let relevantPrice = marketPrices["BTC-USDT"]; // Default to BTC
                const oracleRouteId = Number(trancheSpec.oracleRouteId || 1);
                
                // Map oracle route IDs to symbols (based on configureOracles.js)
                const routeMapping = {
                    1: "BTC-USDT",    // Default BTC route
                    2: "ETH-USDT",    // ETH route 
                    3: "KAIA-USDT"    // KAIA route
                };
                
                const targetSymbol = routeMapping[oracleRouteId] || "BTC-USDT";
                relevantPrice = marketPrices[targetSymbol];
                
                console.log(`   🔮 Oracle Route: ${targetSymbol} (Route ID: ${oracleRouteId})`);
                
                if (relevantPrice && triggerDirection !== "OTHER") {
                    let distanceToTrigger;
                    if (triggerDirection === "BELOW") {
                        distanceToTrigger = ((relevantPrice - triggerPrice) / relevantPrice) * 100;
                    } else { // ABOVE
                        distanceToTrigger = ((triggerPrice - relevantPrice) / relevantPrice) * 100;
                    }
                    
                    console.log(`   📊 Current Price: $${relevantPrice.toLocaleString()}`);
                    console.log(`   📊 Distance to Trigger: ${distanceToTrigger.toFixed(2)}%`);
                    
                    if (distanceToTrigger <= 0) {
                        riskLevel = "Triggered";
                        riskColor = "🔴";
                        portfolioStats.triggered++;
                    } else if (distanceToTrigger < 5) {
                        riskLevel = "High Risk";
                        riskColor = "🟠";
                        portfolioStats.highRisk++;
                    } else if (distanceToTrigger < 15) {
                        riskLevel = "Medium Risk";
                        riskColor = "🟡";
                        portfolioStats.mediumRisk++;
                    } else {
                        riskLevel = "Low Risk";
                        riskColor = "🟢";
                        portfolioStats.lowRisk++;
                    }
                } else if (!relevantPrice) {
                    console.log(`   ⚠️  No price data available for ${targetSymbol}`);
                }
                
                console.log(`   ${riskColor} Risk Level: ${riskLevel}`);
                
                // Get pool data if available
                if (poolAddress !== ethers.ZeroAddress) {
                    const pool = await ethers.getContractAt("TranchePoolCore", poolAddress);
                    const poolAccounting = await pool.getPoolAccounting();
                    
                    const utilizationRate = trancheCap > 0 ? (Number(ethers.formatUnits(poolAccounting.totalAssets, 6)) / trancheCap) * 100 : 0;
                    
                    console.log(`   💧 Pool Assets: $${ethers.formatUnits(poolAccounting.totalAssets, 6)}`);
                    console.log(`   📈 Utilization: ${utilizationRate.toFixed(2)}%`);
                    
                    portfolioStats.totalCapacity += trancheCap;
                    portfolioStats.totalRevenue += Number(ethers.formatUnits(poolAccounting.totalAssets, 6)) * (premiumRate / 100);
                }
                
            } catch (trancheError) {
                console.log(`\n❌ Tranche ${trancheId}: Error reading data`);
                console.log(`   ⚠️  Error: ${trancheError.message}`);
            }
        }

        console.log("\n" + "=" .repeat(60));
        console.log("📊 Portfolio Summary");
        console.log("=" .repeat(60));
        console.log(`🏦 Total Capacity: $${portfolioStats.totalCapacity.toLocaleString()}`);
        console.log(`💰 Estimated Revenue: $${portfolioStats.totalRevenue.toLocaleString()}`);
        console.log(`\n🎯 Risk Distribution:`);
        console.log(`   🟢 Low Risk: ${portfolioStats.lowRisk}`);
        console.log(`   🟡 Medium Risk: ${portfolioStats.mediumRisk}`);
        console.log(`   🟠 High Risk: ${portfolioStats.highRisk}`);
        console.log(`   🔴 Triggered: ${portfolioStats.triggered}`);

        console.log("\n📝 Recommendations:");
        if (portfolioStats.triggered > 0) {
            console.log("🚨 URGENT: Some tranches are triggered - check settlement!");
        } else if (portfolioStats.highRisk > portfolioStats.lowRisk) {
            console.log("⚠️  High risk concentration - monitor closely");
        } else {
            console.log("✅ Balanced risk portfolio");
        }

    } catch (error) {
        console.error(`❌ Error: ${error.message}`);
        throw error;
    }
  });

task("monitor-insurances", "Monitor insurance rounds with settlement status and lifecycle tracking")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔍 Insurance Lifecycle Monitor");
    console.log("=" .repeat(60));

    const PRODUCT_CATALOG_ADDRESS = process.env.PRODUCT_CATALOG_ADDRESS;
    const TRANCHE_POOL_FACTORY_ADDRESS = process.env.TRANCHE_POOL_FACTORY_ADDRESS;
    const SETTLEMENT_ENGINE_ADDRESS = process.env.SETTLEMENT_ENGINE_ADDRESS;
    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;

    if (!PRODUCT_CATALOG_ADDRESS || !TRANCHE_POOL_FACTORY_ADDRESS) {
        throw new Error("Please set required contract addresses in your .env file");
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const productCatalog = await ethers.getContractAt("ProductCatalog", PRODUCT_CATALOG_ADDRESS);
    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", TRANCHE_POOL_FACTORY_ADDRESS);
    
    let settlementEngine, oracleRouter;
    if (SETTLEMENT_ENGINE_ADDRESS) {
        settlementEngine = await ethers.getContractAt("SettlementEngine", SETTLEMENT_ENGINE_ADDRESS);
    }
    if (ORACLE_ROUTER_ADDRESS) {
        oracleRouter = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);
    }

    try {
        // Get current market prices for reference
        let marketPrices = {};
        if (oracleRouter) {
            const symbols = ["BTC-USDT", "ETH-USDT", "KAIA-USDT"];
            for (const symbol of symbols) {
                try {
                    const identifier = ethers.keccak256(ethers.toUtf8Bytes(symbol));
                    const priceResult = await oracleRouter.getPrice(identifier);
                    const price = Number(ethers.formatUnits(priceResult.price, 8));
                    marketPrices[symbol] = price;
                } catch (priceError) {
                    marketPrices[symbol] = null;
                }
            }
        }

        // Auto-discover active tranches and their rounds
        const activeTranches = await productCatalog.getActiveTranches();
        console.log(`\n🔍 Found ${activeTranches.length} active tranche(s)`);

        let totalCoverage = 0n;
        let roundsRequiringAction = [];
        const now = Math.floor(Date.now() / 1000);

        for (const trancheId of activeTranches) {
            try {
                const trancheRounds = await productCatalog.getTrancheRounds(trancheId);
                if (trancheRounds.length === 0) continue;

                const trancheSpec = await productCatalog.getTranche(trancheId);
                const poolAddress = await tranchePoolFactory.getTranchePool(trancheId);

                // Build a human-readable tranche name from oracle route, trigger direction, and threshold
                const oracleRouteId = Number(trancheSpec.oracleRouteId || 1);
                const routeMapping = { 1: "BTC-USDT", 2: "ETH-USDT", 3: "KAIA-USDT" };
                const symbol = routeMapping[oracleRouteId] || "BTC-USDT";
                const triggerDir = Number(trancheSpec.triggerType) === 0 ? "BELOW" : (Number(trancheSpec.triggerType) === 1 ? "ABOVE" : "OTHER");
                const thresholdHuman = Number(ethers.formatEther(trancheSpec.threshold));
                const trancheDisplayName = `${symbol} ${triggerDir} $${thresholdHuman.toLocaleString()}`;
                
                console.log(`\n🎯 Tranche ${trancheId}: ${trancheDisplayName}`);
                console.log(`   🎯 Trigger: $${Number(ethers.formatEther(trancheSpec.threshold)).toLocaleString()} (${Number(trancheSpec.triggerType) === 0 ? 'BELOW' : 'ABOVE'})`);
                
                for (const roundId of trancheRounds) {
                    const roundInfo = await productCatalog.getRound(roundId);
                    const roundState = ['ANNOUNCED', 'OPEN', 'ACTIVE', 'MATURED', 'SETTLED', 'CANCELED'][roundInfo.state];
                    
                    // Show recent settled rounds (within 24 hours) but skip old ones
                    if (roundInfo.state === 6) continue; // Skip CANCELED
                    if (roundInfo.state === 5) { // SETTLED
                        const hoursSinceSettlement = (now - stateChangedAt) / 3600;
                        if (hoursSinceSettlement > 24) continue; // Skip if older than 24 hours
                    }
                    
                    console.log(`\n   📋 Round ${roundId}: ${roundState}`);

                    // Always show timeline
                    const salesStart = Number(roundInfo.salesStartTime);
                    const salesEnd = Number(roundInfo.salesEndTime);
                    const maturityTs = Number(trancheSpec.maturityTimestamp);
                    const createdAt = Number(roundInfo.createdAt || 0);
                    const stateChangedAt = Number(roundInfo.stateChangedAt || 0);
                    console.log(`      📅 Sales: ${new Date(salesStart * 1000).toLocaleString()} → ${new Date(salesEnd * 1000).toLocaleString()}`);
                    console.log(`      📅 Maturity: ${new Date(maturityTs * 1000).toLocaleString()}`);
                    if (createdAt) console.log(`      🧾 Created: ${new Date(createdAt * 1000).toLocaleString()}`);
                    if (stateChangedAt) console.log(`      🔄 Last State Change: ${new Date(stateChangedAt * 1000).toLocaleString()}`);

                    // Show buyer/seller status and economics (always)
                    if (poolAddress !== ethers.ZeroAddress) {
                        const pool = await ethers.getContractAt("TranchePoolCore", poolAddress);
                        const [totalBuyerPurchases, totalSellerCollateral, matchedAmount, lockedCollateral, premiumPool] = await pool.getRoundEconomics(roundId);

                        // Aggregate buyer/seller details
                        let buyers = [], sellers = [];
                        try {
                            const participants = await pool.getRoundParticipants(roundId);
                            buyers = participants[0] || [];
                            sellers = participants[1] || [];
                        } catch {}

                        // Buyers aggregation
                        let buyerCount = buyers.length;
                        let buyersFilled = 0, buyersUnfilled = 0;
                        let buyerFilledAmount = 0n, buyerUnfilledPremiumRefund = 0n;
                        for (const b of buyers) {
                            try {
                                const o = await pool.getBuyerOrder(roundId, b);
                                if (o.buyer !== ethers.ZeroAddress) {
                                    if (o.filled) {
                                        buyersFilled++;
                                        buyerFilledAmount += o.purchaseAmount;
                                    } else {
                                        buyersUnfilled++;
                                        if (o.refunded) buyerUnfilledPremiumRefund += o.premiumPaid;
                                    }
                                }
                            } catch {}
                        }

                        // Sellers aggregation
                        let sellerCount = sellers.length;
                        let sellersFilled = 0, sellersUnfilled = 0;
                        for (const s of sellers) {
                            try {
                                const p = await pool.getSellerPosition(roundId, s);
                                if (p.seller !== ethers.ZeroAddress) {
                                    if (p.filled) {
                                        sellersFilled++;
                                    } else {
                                        if (p.refunded) sellersUnfilled++;
                                    }
                                }
                            } catch {}
                        }

                        // Economics summary
                        console.log(`      💰 Coverage (matched): $${ethers.formatUnits(matchedAmount, 6)}`);
                        // After settlement, locked collateral should be 0 in pool accounting
                        const lockedDisplay = roundInfo.state === 5 ? 0n : lockedCollateral;
                        console.log(`      🔒 Locked Collateral: $${ethers.formatUnits(lockedDisplay, 6)}`);

                        // Buyer status
                        const buyersUnmatched = totalBuyerPurchases > matchedAmount ? (totalBuyerPurchases - matchedAmount) : 0n;
                        console.log(`      👥 Buyers: ${buyerCount} (filled ${buyersFilled}, unfilled ${buyersUnfilled})`);
                        console.log(`         - Purchased: $${ethers.formatUnits(totalBuyerPurchases, 6)} | Filled: $${ethers.formatUnits(buyerFilledAmount, 6)} | Unmatched: $${ethers.formatUnits(buyersUnmatched, 6)}`);
                        if (buyerUnfilledPremiumRefund > 0n) {
                            console.log(`         - Premium refunds: $${ethers.formatUnits(buyerUnfilledPremiumRefund, 6)}`);
                        }

                        // Seller status
                        const sellersUnmatched = totalSellerCollateral > matchedAmount ? (totalSellerCollateral - matchedAmount) : 0n;
                        console.log(`      🏦 Sellers: ${sellerCount} (filled ${sellersFilled}, unfilled ${sellersUnfilled})`);
                        console.log(`         - Collateral: $${ethers.formatUnits(totalSellerCollateral, 6)} | Filled: $${ethers.formatUnits(matchedAmount, 6)} | Unmatched refunded: $${ethers.formatUnits(sellersUnmatched, 6)}`);

                        totalCoverage += matchedAmount;
                        
                        // Always show pool state; emphasize after settlement
                        if (roundInfo.state === 5) { // SETTLED
                            try {
                                const poolAccounting = await pool.getPoolAccounting();
                                console.log(`      📊 Pool after settlement:`);
                                console.log(`         - Total Assets: $${ethers.formatUnits(poolAccounting.totalAssets, 6)}`);
                                console.log(`         - Locked Assets: $${ethers.formatUnits(poolAccounting.lockedAssets, 6)}`);
                                console.log(`         - NAV per Share: ${ethers.formatEther(poolAccounting.navPerShare)}`);
                            } catch (poolError) {
                                console.log(`      ⚠️  Could not read pool state after settlement`);
                            }
                        } else {
                            try {
                                const poolAccounting = await pool.getPoolAccounting();
                                console.log(`      📊 Pool state:`);
                                console.log(`         - Total Assets: $${ethers.formatUnits(poolAccounting.totalAssets, 6)}`);
                                console.log(`         - Locked Assets: $${ethers.formatUnits(poolAccounting.lockedAssets, 6)}`);
                                console.log(`         - NAV per Share: ${ethers.formatEther(poolAccounting.navPerShare)}`);
                            } catch {}
                        }
                    }
                    
                    // Show settlement status for matured/settled rounds
                    if ((roundInfo.state === 3 || roundInfo.state === 5) && settlementEngine) { // MATURED or SETTLED
                        try {
                            const settlementInfo = await settlementEngine.getSettlementInfo(roundId);
                            
                            if (settlementInfo.roundId !== 0n) {
                                // Oracle observation completed
                                const oraclePrice = Number(ethers.formatUnits(settlementInfo.oracleResult, 8));
                                const triggered = settlementInfo.triggered;
                                const settled = settlementInfo.settled;
                                const livenessDeadline = Number(settlementInfo.livenessDeadline);
                                const timeUntilFinalize = livenessDeadline - now;
                                
                                console.log(`      🔮 Oracle Result: $${oraclePrice.toLocaleString()} (${triggered ? '🔴 TRIGGERED' : '🟢 Safe'})`);
                                
                                if (!settled) {
                                    if (timeUntilFinalize > 0) {
                                        const mins = Math.floor(timeUntilFinalize / 60);
                                        console.log(`      ⏰ Liveness: ${mins}min remaining until finalization`);
                                        console.log(`      📅 Ready: ${new Date(livenessDeadline * 1000).toLocaleString()}`);
                                    } else {
                                        console.log(`      ✅ READY TO FINALIZE`);
                                        roundsRequiringAction.push({
                                            roundId,
                                            action: 'finalize-settlement',
                                            urgency: 'high',
                                            description: `Round ${roundId} ready for final settlement`
                                        });
                                    }
                                } else {
                                    console.log(`      ✅ Settlement complete`);
                                    
                                    // Show settlement results
                                    const totalPayouts = ethers.formatUnits(settlementInfo.totalPayouts, 6);
                                    if (triggered) {
                                        console.log(`      🔴 TRIGGERED - Buyers paid $${totalPayouts}`);
                                        console.log(`      💰 Sellers received yield earnings (lost collateral)`);
                                    } else {
                                        console.log(`      🟢 NOT TRIGGERED - Sellers got collateral + yield back`);
                                        console.log(`      💰 Estimated total seller payout: $${ethers.formatUnits(matchedAmount, 6)} + yield`);
                                    }
                                }
                            } else {
                                // Oracle observation not yet done
                                const maturityTime = Number(trancheSpec.maturityTimestamp);
                                if (now >= maturityTime) {
                                    console.log(`      ⚖️ READY FOR ORACLE OBSERVATION`);
                                    roundsRequiringAction.push({
                                        roundId,
                                        action: 'settle-rounds',
                                        urgency: 'high',
                                        description: `Round ${roundId} matured, needs oracle observation`
                                    });
                                } else {
                                    const timeToMaturity = maturityTime - now;
                                    const hours = Math.floor(timeToMaturity / 3600);
                                    console.log(`      ⏰ Matures in ${hours}h`);
                                }
                            }
                        } catch (settlementError) {
                            console.log(`      ⚠️  Settlement info unavailable`);
                        }
                    }
                    
                    // Show current price vs trigger for active rounds
                    if (roundInfo.state >= 2 && roundInfo.state <= 3) {
                        const oracleRouteId = Number(trancheSpec.oracleRouteId || 1);
                        const routeMapping = { 1: "BTC-USDT", 2: "ETH-USDT", 3: "KAIA-USDT" };
                        const targetSymbol = routeMapping[oracleRouteId] || "BTC-USDT";
                        const currentPrice = marketPrices[targetSymbol];
                        
                        if (currentPrice) {
                            const triggerPrice = Number(ethers.formatEther(trancheSpec.threshold));
                            const distance = Math.abs(currentPrice - triggerPrice) / triggerPrice * 100;
                            console.log(`      📊 ${targetSymbol}: $${currentPrice.toLocaleString()} (${distance.toFixed(1)}% from trigger)`);
                        }
                    }
                    
                    // Check for action items
                    if (roundInfo.state === 1 && now > Number(roundInfo.salesEndTime)) {
                        roundsRequiringAction.push({
                            roundId,
                            action: 'close-rounds',
                            urgency: 'medium',
                            description: `Round ${roundId} sales period ended, needs closure`
                        });
                    }
                    
                    // Show maturity countdown for active rounds
                    if (roundInfo.state === 2) { // ACTIVE
                        const maturityTime = Number(trancheSpec.maturityTimestamp);
                        const timeToMaturity = maturityTime - now;
                        
                        if (timeToMaturity > 0) {
                            const days = Math.floor(timeToMaturity / (24 * 60 * 60));
                            const hours = Math.floor((timeToMaturity % (24 * 60 * 60)) / 3600);
                            console.log(`      ⏰ Matures: ${days}d ${hours}h (${new Date(maturityTime * 1000).toLocaleString()})`);
                        }
                    }
                }
                
            } catch (trancheError) {
                console.log(`\n❌ Error reading tranche ${trancheId}: ${trancheError.message}`);
            }
        }

        // Summary and action items
        console.log("\n" + "=" .repeat(60));
        console.log("📊 System Status Summary");
        console.log("=" .repeat(60));
        console.log(`💰 Total Active Coverage: $${ethers.formatUnits(totalCoverage, 6)}`);

        if (roundsRequiringAction.length > 0) {
            console.log(`\n📝 Action Items (${roundsRequiringAction.length}):`);
            
            // Sort by urgency
            const sortedActions = roundsRequiringAction.sort((a, b) => {
                const urgencyOrder = { 'high': 0, 'medium': 1, 'low': 2 };
                return urgencyOrder[a.urgency] - urgencyOrder[b.urgency];
            });
            
            for (const action of sortedActions) {
                const urgencyIcon = action.urgency === 'high' ? '🔴' : action.urgency === 'medium' ? '🟡' : '🟢';
                console.log(`   ${urgencyIcon} ${action.description}`);
                console.log(`      → npx hardhat ${action.action} --round-id ${action.roundId} --network kairos`);
            }
        } else {
            console.log("\n✅ No immediate actions required");
        }

        if (totalCoverage === 0n) {
            console.log("\n💡 No active coverage found. Start new rounds:");
            console.log("   npx hardhat announce-rounds --tranche-id <id> --network kairos");
        }

    } catch (error) {
        console.error(`❌ Error: ${error.message}`);
        throw error;
    }
  });

task("monitor-yield", "Monitor YieldRouter status and yield generation")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("💰 Yield Router Monitor");
    console.log("=" .repeat(60));

    const YIELD_ROUTER_ADDRESS = process.env.YIELD_ROUTER_ADDRESS;
    const TRANCHE_POOL_FACTORY_ADDRESS = process.env.TRANCHE_POOL_FACTORY_ADDRESS;

    if (!YIELD_ROUTER_ADDRESS || !TRANCHE_POOL_FACTORY_ADDRESS) {
        throw new Error("Please set YIELD_ROUTER_ADDRESS and TRANCHE_POOL_FACTORY_ADDRESS in your .env file");
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const yieldRouter = await ethers.getContractAt("YieldRouter", YIELD_ROUTER_ADDRESS);
    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", TRANCHE_POOL_FACTORY_ADDRESS);

    try {
        // Get YieldRouter overall status
        const totalBalance = await yieldRouter.getTotalBalance();
        const valueAtRisk = await yieldRouter.getTotalValueAtRisk();
        const availableForWithdrawal = await yieldRouter.getAvailableForWithdrawal();
        const yieldRecord = await yieldRouter.getYieldRecord();

        console.log(`\n🏦 YieldRouter Overall Status:`);
        console.log(`   💎 Total Balance: $${ethers.formatUnits(totalBalance, 6)}`);
        console.log(`   🔒 Value at Risk: $${ethers.formatUnits(valueAtRisk, 6)}`);
        console.log(`   💚 Available for Admin Withdrawal: $${ethers.formatUnits(availableForWithdrawal, 6)}`);
        console.log(`\n📊 Yield Statistics:`);
        console.log(`   📈 Total Deposited: $${ethers.formatUnits(yieldRecord.totalDeposited, 6)}`);
        console.log(`   📉 Total Returned: $${ethers.formatUnits(yieldRecord.totalReturned, 6)}`);
        console.log(`   🎁 Total Yield Generated: $${ethers.formatUnits(yieldRecord.totalYieldGenerated, 6)}`);

        // Get registered pools with details
        const registeredPools = await yieldRouter.getRegisteredPools();
        console.log(`\n🏊 Registered Pools (${registeredPools.length}):`);

        let totalPoolDeposits = 0n;
        let activeCount = 0;
        for (let i = 0; i < registeredPools.length; i++) {
            const poolAddress = registeredPools[i];
            const poolInfo = await yieldRouter.getPoolInfo(poolAddress);
            
            // Get pool info
            try {
                const pool = await ethers.getContractAt("TranchePoolCore", poolAddress);
                const trancheInfo = await pool.getTrancheInfo();
                
                console.log(`\n   🏊 Pool ${i + 1}: Tranche ${poolInfo.trancheId || trancheInfo.trancheId}`);
                console.log(`      📍 Address: ${poolAddress}`);
                console.log(`      💰 Funds in Yield: $${ethers.formatUnits(poolInfo.fundsInYield, 6)}`);
                console.log(`      🎁 Total Yield Earned: $${ethers.formatUnits(poolInfo.totalYieldEarned, 6)}`);
                console.log(`      📅 Registered: ${new Date(Number(poolInfo.registrationTimestamp) * 1000).toLocaleString()}`);
                console.log(`      ✅ Active: ${poolInfo.fundsInYield > 0 ? "Yes" : "No"}`);
                
                totalPoolDeposits += poolInfo.fundsInYield;
                if (poolInfo.fundsInYield > 0) activeCount++;
            } catch (error) {
                console.log(`\n   ❌ Pool ${i + 1}: Error reading pool data`);
                console.log(`      📍 Address: ${poolAddress}`);
                console.log(`      💰 Funds in Yield: $${ethers.formatUnits(poolInfo.fundsInYield, 6)}`);
            }
        }

        console.log(`\n📊 Summary:`);
        console.log(`   💸 Total Pool Funds in Yield: $${ethers.formatUnits(totalPoolDeposits, 6)}`);
        console.log(`   🏦 YieldRouter Balance: $${ethers.formatUnits(totalBalance, 6)}`);
        console.log(`   ⚡ Active Pools: ${activeCount} / ${registeredPools.length}`);
        
        const balanceDiff = totalBalance - totalPoolDeposits;
        if (balanceDiff > 0n) {
            console.log(`   💰 Extra Funds (admin deposits/yield): $${ethers.formatUnits(balanceDiff, 6)}`);
        } else if (balanceDiff < 0n) {
            console.log(`   ⚠️  Deficit: $${ethers.formatUnits(-balanceDiff, 6)}`);
        }

        // Health checks
        console.log(`\n🏥 Health Status:`);
        if (totalBalance < valueAtRisk) {
            console.log(`   ❌ CRITICAL: Insufficient funds to cover pool returns`);
            console.log(`      Balance: $${ethers.formatUnits(totalBalance, 6)}`);
            console.log(`      Required: $${ethers.formatUnits(valueAtRisk, 6)}`);
        } else {
            console.log(`   ✅ Healthy: Sufficient funds to cover all pool returns`);
        }

        if (activeCount === 0) {
            console.log(`   💡 No active yield generation - all funds available for admin use`);
        }
        
        // Utilization rate
        if (totalBalance > 0n) {
            const utilizationRate = (valueAtRisk * 10000n) / totalBalance;
            console.log(`   📊 Fund Utilization: ${Number(utilizationRate) / 100}%`);
        }

    } catch (error) {
        console.error(`❌ Error: ${error.message}`);
        throw error;
    }
  });

module.exports = {};
// ==========================================================================
// POSITION MONITORING (BY ADDRESS)
// ==========================================================================

task("monitor-address", "Show user's insurance positions and seller stakes")
  .addParam("address", "User address to inspect", undefined, types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("👤 Address Position Monitor");
    console.log("=" .repeat(60));

    const PRODUCT_CATALOG_ADDRESS = process.env.PRODUCT_CATALOG_ADDRESS;
    const TRANCHE_POOL_FACTORY_ADDRESS = process.env.TRANCHE_POOL_FACTORY_ADDRESS;
    const INSURANCE_TOKEN_ADDRESS = process.env.INSURANCE_TOKEN_ADDRESS;

    if (!PRODUCT_CATALOG_ADDRESS || !TRANCHE_POOL_FACTORY_ADDRESS || !INSURANCE_TOKEN_ADDRESS) {
        throw new Error("Please set PRODUCT_CATALOG_ADDRESS, TRANCHE_POOL_FACTORY_ADDRESS, and INSURANCE_TOKEN_ADDRESS in your .env file");
    }

    const productCatalog = await ethers.getContractAt("ProductCatalog", PRODUCT_CATALOG_ADDRESS);
    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", TRANCHE_POOL_FACTORY_ADDRESS);

    const user = taskArgs.address;
    console.log(`\n👤 Address: ${user}`);

    // Buyer positions via InsuranceToken balance and tokenInfo scan (guarded)
    try {
        const code = await ethers.provider.getCode(INSURANCE_TOKEN_ADDRESS);
        if (code === "0x") {
            console.log("\n🎫 Buyer Positions (ERC721): skipped (INSURANCE_TOKEN_ADDRESS is not a deployed contract)");
        } else {
            const insuranceToken = await ethers.getContractAt("InsuranceToken", INSURANCE_TOKEN_ADDRESS);
            const tokenCount = await insuranceToken.balanceOf(user);
            console.log(`\n🎫 Buyer Positions (ERC721): ${tokenCount}`);
            let shown = 0n;
            for (let i = 0n; i < tokenCount && shown < 10n; i++) {
                const candidateId = tokenCount - i; // heuristic only
                try {
                    const owner = await insuranceToken.ownerOf(candidateId);
                    if (owner.toLowerCase() === user.toLowerCase()) {
                        const info = await insuranceToken.getTokenInfo(candidateId);
                        console.log(`   #${candidateId} → tranche ${info.trancheId}, round ${info.roundId}, amount $${ethers.formatUnits(info.purchaseAmount, 6)}`);
                        shown++;
                    }
                } catch {}
            }
            if (shown === 0n && tokenCount > 0n) {
                console.log("   ℹ️ Tokens exist but cannot enumerate IDs (non-enumerable ERC721).");
            }
        }
    } catch (e) {
        console.log(`\n🎫 Buyer Positions: skipped (${e.message})`);
    }

    // Seller stakes across active tranches
    const activeTranches = await productCatalog.getActiveTranches();
    let totalShares = 0n;
    let totalAvailable = 0n;
    console.log(`\n🏦 Seller Stakes:`);
    for (const trancheId of activeTranches) {
        try {
            const poolAddr = await tranchePoolFactory.getTranchePool(trancheId);
            if (poolAddr === ethers.ZeroAddress) continue;
            const pool = await ethers.getContractAt("TranchePoolCore", poolAddr);
            const shares = await pool.shareBalances(user);
            if (shares === 0n) continue;
            const avail = await pool.getAvailableCollateral(user);
            totalShares += shares;
            totalAvailable += avail;
            console.log(`   Tranche ${trancheId}: shares ${ethers.formatUnits(shares, 6)}, available $${ethers.formatUnits(avail, 6)}`);
        } catch (e) {}
    }
    if (totalShares === 0n) console.log("   (none)");
    console.log(`\n📊 Totals: shares ${ethers.formatUnits(totalShares, 6)}, available $${ethers.formatUnits(totalAvailable, 6)}`);
  });

// ==========================================================================
// CLAIMABLE MONITOR (BY ADDRESS, ROUND)
// ==========================================================================

task("monitor-claimable", "Show claimable status for a user in a round (auto-refund model)")
  .addParam("address", "User address", undefined, types.string)
  .addParam("roundId", "Round ID", undefined, types.int)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    const PRODUCT_CATALOG_ADDRESS = process.env.PRODUCT_CATALOG_ADDRESS;
    const TRANCHE_POOL_FACTORY_ADDRESS = process.env.TRANCHE_POOL_FACTORY_ADDRESS;

    const productCatalog = await ethers.getContractAt("ProductCatalog", PRODUCT_CATALOG_ADDRESS);
    const tranchePoolFactory = await ethers.getContractAt("TranchePoolFactory", TRANCHE_POOL_FACTORY_ADDRESS);

    const roundInfo = await productCatalog.getRound(taskArgs.roundId);
    const trancheId = roundInfo.trancheId;
    const poolAddress = await tranchePoolFactory.getTranchePool(trancheId);
    const pool = await ethers.getContractAt("TranchePoolCore", poolAddress);

    const buyerOrder = await pool.getBuyerOrder(taskArgs.roundId, taskArgs.address);
    const sellerPosition = await pool.getSellerPosition(taskArgs.roundId, taskArgs.address);

    console.log("\n📋 Claimable Overview (auto-refund model):");
    if (buyerOrder.buyer !== ethers.ZeroAddress) {
        const status = buyerOrder.filled ? "FILLED" : (buyerOrder.refunded ? "REFUNDED" : "UNFILLED");
        console.log(`   🧾 Buyer: ${taskArgs.address} | ${status}`);
        console.log(`     - Purchase: $${ethers.formatUnits(buyerOrder.purchaseAmount, 6)}`);
        console.log(`     - Premium:  $${ethers.formatUnits(buyerOrder.premiumPaid, 6)}`);
        if (!buyerOrder.filled && buyerOrder.refunded) {
            console.log(`     - Premium was auto-refunded at matching.`);
        } else if (!buyerOrder.filled && !buyerOrder.refunded) {
            console.log(`     - Pending: will auto-refund at matching.`);
        } else {
            console.log(`     - No premium refund (order filled).`);
        }
    } else {
        console.log(`   🧾 Buyer: no order found`);
    }

    if (sellerPosition.seller !== ethers.ZeroAddress) {
        const status = sellerPosition.filled ? "FILLED" : (sellerPosition.refunded ? "REFUNDED" : "UNFILLED");
        const totalColl = sellerPosition.collateralAmount;
        const filledColl = sellerPosition.filledCollateral || 0n;
        const unmatched = totalColl > filledColl ? (totalColl - filledColl) : 0n;
        console.log(`   🏦 Seller: ${taskArgs.address} | ${status}`);
        console.log(`     - Collateral (total): $${ethers.formatUnits(totalColl, 6)}`);
        console.log(`     - Filled Collateral:  $${ethers.formatUnits(filledColl, 6)}`);
        if (unmatched > 0n) {
            console.log(`     - Unmatched (auto-refunded): $${ethers.formatUnits(unmatched, 6)}`);
        }
        if ((sellerPosition.lockedSharesAssigned || 0n) > 0n) {
            console.log(`     - Locked Shares Assigned: ${ethers.formatUnits(sellerPosition.lockedSharesAssigned, 6)}`);
        }
        if (!sellerPosition.filled && sellerPosition.refunded) {
            console.log(`     - Note: Unmatched collateral was auto-refunded at matching.`);
        } else if (!sellerPosition.filled && !sellerPosition.refunded) {
            console.log(`     - Pending: will auto-refund at matching.`);
        } else {
            console.log(`     - No collateral refund (position filled).`);
        }
    } else {
        console.log(`   🏦 Seller: no position found`);
    }
  });
// ============================================================================
// ORACLE MONITOR TASK
// ============================================================================

task("monitor-oracles", "Monitor oracle routes and current prices")
  .addOptionalParam("identifier", "Price identifier string (e.g., BTC-USDT, ETH-USDT, KAIA-USDT, or 'all')", "all", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔮 Oracle Monitor");
    console.log("=" .repeat(60));

    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;

    if (!ORACLE_ROUTER_ADDRESS) {
        console.log("⚠️  ORACLE_ROUTER_ADDRESS not set. Skipping.");
        return;
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const oracleRouter = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);

    try {
        const identifiers = taskArgs.identifier === "all" 
            ? ["BTC-USDT", "ETH-USDT", "KAIA-USDT"]
            : [taskArgs.identifier];

        for (const idString of identifiers) {
            console.log(`\n🎯 Identifier: ${idString}`);
            const identifier = ethers.keccak256(ethers.toUtf8Bytes(idString));

            try {
                const result = await oracleRouter.getPrice(identifier);
                const price = Number(ethers.formatUnits(result.price, 8)); // Both oracles use 8 decimals
                const ts = Number(result.timestamp);
                const ageSec = Math.floor(Date.now() / 1000) - ts;

                console.log(`   💰 Price: $${price.toLocaleString()}`);
                console.log(`   ⏰ Timestamp: ${new Date(ts * 1000).toLocaleString()} (${ageSec}s ago)`);
                console.log(`   ✅ Valid: ${result.valid}`);

                // If comparePrices available, try a comparison print (best-effort)
                try {
                    const cmp = await oracleRouter.comparePrices(identifier);
                    const orakl = Number(ethers.formatUnits(cmp[0].price, 8)); // Orakl uses 8 decimals
                    const dino = Number(ethers.formatUnits(cmp[1].price, 8)); // DINO now uses 8 decimals too
                    const deviationBps = Number(cmp[2]);
                    console.log(`   🔀 Source Comparison:`);
                    console.log(`      🌐 Orakl: $${orakl.toLocaleString()}`);
                    console.log(`      🦕 DINO:  $${dino.toLocaleString()}`);
                    console.log(`      📉 Deviation: ${deviationBps / 100}%`);
                } catch {}

            } catch (identifierError) {
                console.log(`   ❌ Error: ${identifierError.message}`);
            }

            if (identifiers.length > 1 && idString !== identifiers[identifiers.length - 1]) {
                console.log("   " + "─".repeat(50));
            }
        }

    } catch (error) {
        console.error(`\n❌ Oracle error: ${error.message}`);
        throw error;
    }
  });

// ============================================================================
// DIRECT ORAKL FEED MONITOR (BYPASS ORACLE ROUTER)
// ============================================================================

task("monitor-orakl-direct", "Directly query OraklPriceFeed for a symbol")
  .addOptionalParam("symbol", "Symbol (e.g., BTC-USDT)", "BTC-USDT", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔌 Orakl Direct Monitor");
    console.log("=" .repeat(60));

    const ORAKL_FEED_ADDRESS = process.env.ORAKL_FEED_ADDRESS;
    if (!ORAKL_FEED_ADDRESS) {
      console.log("⚠️  ORAKL_FEED_ADDRESS not set in .env. Set it to your OraklPriceFeed address.");
      return;
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const orakl = await ethers.getContractAt("OraklPriceFeed", ORAKL_FEED_ADDRESS);

    try {
      const symbol = taskArgs.symbol;
      const feedId = ethers.keccak256(ethers.toUtf8Bytes(symbol));
      console.log(`\n🎯 Symbol: ${symbol}`);
      console.log(`🧩 Feed ID: ${feedId}`);

      // Read config from mapping (public)
      const cfg = await orakl.priceFeeds(feedId);
      const feedProxy = cfg.feedProxyAddress;
      const decimals = Number(cfg.decimals || 0);
      const heartbeat = Number(cfg.heartbeatSeconds || 0);
      const description = cfg.description || "";
      const active = Boolean(cfg.active);

      console.log("\n⚙️  Config:");
      console.log(`   📍 Proxy: ${feedProxy}`);
      console.log(`   🧮 Decimals: ${decimals}`);
      console.log(`   ⏱️  Heartbeat: ${heartbeat}s`);
      console.log(`   📝 Description: ${description}`);
      console.log(`   ✅ Active: ${active}`);

      const supported = await orakl.isFeedSupported(symbol);
      console.log(`\n🔎 Supported: ${supported}`);

      // Try latest price
      console.log("\n📡 Fetching latest price from OraklPriceFeed...");
      try {
        const data = await orakl.getLatestPrice(symbol);
        const rawPrice = data.price;
        const ts = Number(data.timestamp);
        const roundId = Number(data.roundId);
        const valid = data.valid;
        const humanPrice = decimals > 0 ? ethers.formatUnits(rawPrice, decimals) : rawPrice.toString();

        console.log(`   💰 Raw Price: ${rawPrice.toString()}`);
        console.log(`   💵 Human Price: $${humanPrice}`);
        console.log(`   ⏰ Timestamp: ${new Date(ts * 1000).toLocaleString()} (${Math.floor((Date.now()/1000 - ts))}s ago)`);
        console.log(`   🔁 Round ID: ${roundId}`);
        console.log(`   ✅ Valid: ${valid}`);
      } catch (e) {
        console.log(`   ❌ Error calling getLatestPrice: ${e.message}`);
      }

      console.log("\n📝 Note: If values are zero/invalid, ensure the feed proxy is correct and active, and heartbeat/staleness allow reads.");
    } catch (error) {
      console.error(`\n❌ Orakl monitor error: ${error.message}`);
      throw error;
    }
  });

// ============================================================================
// DIRECT DINO ORACLE MONITOR (BYPASS ORACLE ROUTER)
// ============================================================================

task("monitor-dino-direct", "Directly query DinoOracle for an identifier")
  .addOptionalParam("identifier", "Price identifier string (e.g., BTC-USDT)", "BTC-USDT", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🦕 DINO Oracle Direct Monitor");
    console.log("=" .repeat(60));

    const DINO_ORACLE_ADDRESS = process.env.DINO_ORACLE_ADDRESS;
    if (!DINO_ORACLE_ADDRESS) {
      console.log("⚠️  DINO_ORACLE_ADDRESS not set in .env. Set it to your DinoOracle address.");
      return;
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const dino = await ethers.getContractAt("DinoOracle", DINO_ORACLE_ADDRESS);

    try {
      const idString = taskArgs.identifier;
      const identifier = ethers.keccak256(ethers.toUtf8Bytes(idString));
      console.log(`\n🎯 Identifier: ${idString}`);
      console.log(`🧩 Keccak: ${identifier}`);

      console.log("\n📡 Fetching latest price from DinoOracle...");
      try {
        const [price, ts] = await dino.getLatestPrice(identifier);
        const human = ethers.formatUnits(price, 8); // DINO now uses 8 decimals
        console.log(`   💰 Price: $${human}`);
        console.log(`   ⏰ Timestamp: ${new Date(Number(ts) * 1000).toLocaleString()} (${Math.floor((Date.now()/1000 - Number(ts)))}s ago)`);
      } catch (e) {
        console.log(`   ❌ Error calling getLatestPrice: ${e.message}`);
      }

      console.log("\n🧪 Historical read (last 1h ago, if any)...");
      try {
        const ts = Math.floor(Date.now() / 1000) - 3600;
        const priceAt = await dino.getPrice(identifier, ts);
        console.log(`   💰 Price @ ${new Date(ts * 1000).toLocaleString()}: $${ethers.formatUnits(priceAt, 8)}`); // DINO now uses 8 decimals
      } catch {}

    } catch (error) {
      console.error(`\n❌ DINO monitor error: ${error.message}`);
      throw error;
    }
  });

// ============================================================================
// ORACLE DEBUG TASKS (Clean and organized)
// ============================================================================

task("debug-oracle-route", "Debug exact OracleRouter getPrice flow")
  .addOptionalParam("identifier", "Price identifier string (e.g., BTC-USDT)", "BTC-USDT", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔧 Oracle Route Flow Debugger");
    console.log("=" .repeat(60));

    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;
    const ORAKL_FEED_ADDRESS = process.env.ORAKL_FEED_ADDRESS;

    if (!ORACLE_ROUTER_ADDRESS || !ORAKL_FEED_ADDRESS) {
      console.log("⚠️  ORACLE_ROUTER_ADDRESS or ORAKL_FEED_ADDRESS not set. Skipping.");
      return;
    }

    const router = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);
    const oraklFeed = await ethers.getContractAt("OraklPriceFeed", ORAKL_FEED_ADDRESS);
    const identifier = ethers.keccak256(ethers.toUtf8Bytes(taskArgs.identifier));

    try {
      console.log(`\n🎯 Testing: ${taskArgs.identifier}`);
      console.log(`🧩 Identifier Hash: ${identifier}`);

      // Step 1: Check router configuration
      const configured = await router.isConfigured(identifier);
      console.log(`\n📋 Router Configured: ${configured}`);

      if (!configured) {
        console.log("❌ Identifier not configured in router");
        return;
      }

      const config = await router.getOracleConfig(identifier);
      console.log(`   🎯 Primary Type: ${config.primaryType} (0=ORAKL, 1=DINO)`);

      // Step 2: Test _identifierToString conversion
      console.log(`\n🔄 Testing identifier conversion...`);
      
      // Manually test the conversion logic from our fixed function
      let convertedSymbol = "";
      if (identifier === ethers.keccak256(ethers.toUtf8Bytes("BTC-USDT"))) {
        convertedSymbol = "BTC-USDT";
      } else if (identifier === ethers.keccak256(ethers.toUtf8Bytes("ETH-USDT"))) {
        convertedSymbol = "ETH-USDT";
      } else if (identifier === ethers.keccak256(ethers.toUtf8Bytes("KAIA-USDT"))) {
        convertedSymbol = "KAIA-USDT";
      }
      console.log(`   ✅ Converted Symbol: "${convertedSymbol}"`);

      // Step 3: Test OraklPriceFeed directly with converted symbol
      console.log(`\n📡 Testing OraklPriceFeed with symbol: "${convertedSymbol}"`);
      try {
        const oraklData = await oraklFeed.getLatestPrice(convertedSymbol);
        console.log(`   💰 Orakl Price: ${oraklData.price}`);
        console.log(`   ⏰ Orakl Timestamp: ${oraklData.timestamp}`);
        console.log(`   🔁 Orakl Round ID: ${oraklData.roundId}`);
        console.log(`   ✅ Orakl Valid: ${oraklData.valid}`);
        console.log(`   💵 Human Price: $${ethers.formatUnits(oraklData.price, 8)}`);
      } catch (error) {
        console.log(`   ❌ OraklPriceFeed Error: ${error.message}`);
      }

      // Step 4: Test OracleRouter getPrice
      console.log(`\n🔀 Testing OracleRouter.getPrice()...`);
      try {
        const routerResult = await router.getPrice(identifier);
        console.log(`   💰 Router Price: ${routerResult.price}`);
        console.log(`   ⏰ Router Timestamp: ${routerResult.timestamp}`);
        console.log(`   🎯 Router Source: ${routerResult.source}`);
        console.log(`   ✅ Router Valid: ${routerResult.valid}`);
        console.log(`   ❌ Router Error: "${routerResult.error}"`);
        console.log(`   💵 Human Price: $${ethers.formatUnits(routerResult.price, 8)}`);
      } catch (error) {
        console.log(`   ❌ OracleRouter Error: ${error.message}`);
      }

    } catch (error) {
      console.error(`\n❌ Debug error: ${error.message}`);
      throw error;
    }
  });

task("debug-oracle-config", "Debug OracleRouter configuration")
  .addOptionalParam("identifier", "Price identifier string (e.g., BTC-USDT)", "BTC-USDT", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔧 Oracle Configuration Debugger");
    console.log("=" .repeat(60));

    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;
    if (!ORACLE_ROUTER_ADDRESS) {
      console.log("⚠️  ORACLE_ROUTER_ADDRESS not set. Skipping.");
      return;
    }

    const router = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);
    const identifier = ethers.keccak256(ethers.toUtf8Bytes(taskArgs.identifier));

    try {
      console.log(`\n🎯 Debugging: ${taskArgs.identifier}`);
      console.log(`🧩 Identifier Hash: ${identifier}`);

      const configured = await router.isConfigured(identifier);
      console.log(`\n📋 Is Configured: ${configured}`);

      if (configured) {
        const config = await router.getOracleConfig(identifier);
        const primaryTypes = ["ORAKL_NETWORK", "DINO_ORACLE", "FALLBACK"];
        const fallbackStrategies = ["PREFER_ORAKL", "PREFER_DINO", "REQUIRE_BOTH", "MANUAL_ONLY"];
        
        console.log(`   🎯 Primary Type: ${primaryTypes[config.primaryType]} (${config.primaryType})`);
        console.log(`   🔄 Fallback Strategy: ${fallbackStrategies[config.fallbackStrategy]} (${config.fallbackStrategy})`);
        console.log(`   📊 Max Deviation: ${Number(config.maxPriceDeviationBps) / 100}%`);
        console.log(`   ⏰ Max Staleness: ${config.maxStaleness}s`);
        console.log(`   ✅ Active: ${config.active}`);
        console.log(`   📝 Description: ${config.description}`);
      }

      const allConfigured = await router.getConfiguredIdentifiers();
      console.log(`\n📋 All Configured Identifiers (${allConfigured.length}):`);
      for (let i = 0; i < allConfigured.length; i++) {
        console.log(`   ${i+1}. ${allConfigured[i]}`);
      }

    } catch (error) {
      console.error(`\n❌ Debug error: ${error.message}`);
      throw error;
    }
  });

task("propose-test-price", "Propose a test price to DinoOracle")
  .addOptionalParam("identifier", "Price identifier (e.g., BTC-USDT)", "BTC-USDT", types.string)
  .addOptionalParam("price", "Price in ETH units (e.g., 113000)", "113000", types.string)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🦕 DINO Oracle Test Price Proposer");
    console.log("=" .repeat(60));

    const DINO_ORACLE_ADDRESS = process.env.DINO_ORACLE_ADDRESS;
    const DIN_TOKEN_ADDRESS = process.env.DIN_TOKEN_ADDRESS;

    if (!DINO_ORACLE_ADDRESS || !DIN_TOKEN_ADDRESS) {
      console.log("⚠️  DINO_ORACLE_ADDRESS or DIN_TOKEN_ADDRESS not set. Skipping.");
      return;
    }

    const [deployer] = await ethers.getSigners();
    console.log(`\n👤 Using account: ${deployer.address}`);

    const dino = await ethers.getContractAt("DinoOracle", DINO_ORACLE_ADDRESS);
    const dinToken = await ethers.getContractAt("DinToken", DIN_TOKEN_ADDRESS);

    try {
      const identifier = ethers.keccak256(ethers.toUtf8Bytes(taskArgs.identifier));
      const price = ethers.parseUnits(taskArgs.price, 8); // DINO Oracle now uses 8 decimals
      const timestamp = Math.floor(Date.now() / 1000);

      console.log(`\n🎯 Proposing price for: ${taskArgs.identifier}`);
      console.log(`💰 Price: $${taskArgs.price} (${price.toString()} wei)`);
      console.log(`⏰ Timestamp: ${new Date(timestamp * 1000).toLocaleString()}`);

      // Check if identifier is supported
      const supported = await dino.supportedIdentifiers(identifier);
      if (!supported) {
        console.log(`\n❌ Identifier ${taskArgs.identifier} not supported. Add it first.`);
        return;
      }

      // Check DIN balance and allowance
      const proposalBond = await dino.proposalBond();
      const balance = await dinToken.balanceOf(deployer.address);
      const allowance = await dinToken.allowance(deployer.address, DINO_ORACLE_ADDRESS);

      console.log(`\n💰 DIN Status:`);
      console.log(`   Balance: ${ethers.formatEther(balance)} DIN`);
      console.log(`   Required Bond: ${ethers.formatEther(proposalBond)} DIN`);
      console.log(`   Current Allowance: ${ethers.formatEther(allowance)} DIN`);

      if (balance < proposalBond) {
        console.log(`\n❌ Insufficient DIN balance for proposal bond.`);
        return;
      }

      if (allowance < proposalBond) {
        console.log(`\n🔐 Approving DIN spending...`);
        const approveTx = await dinToken.approve(DINO_ORACLE_ADDRESS, proposalBond);
        await approveTx.wait();
        console.log(`✅ DIN approved!`);
      }

      // Propose price
      console.log(`\n📤 Proposing price...`);
      const proposeTx = await dino.proposePrice(
        identifier,
        timestamp,
        price,
        `Test price proposal for ${taskArgs.identifier} at $${taskArgs.price}`
      );
      const receipt = await proposeTx.wait();
      console.log(`✅ Price proposed! Gas used: ${receipt.gasUsed}`);

      // Get proposal ID from events
      const event = receipt.logs.find(log => {
        try {
          const parsed = dino.interface.parseLog(log);
          return parsed.name === "PriceProposed";
        } catch {
          return false;
        }
      });

      if (event) {
        const proposalId = dino.interface.parseLog(event).args.proposalId;
        console.log(`📋 Proposal ID: ${proposalId}`);
        console.log(`\n⏰ Wait ${await dino.livenessWindow()}s (liveness window) then call:`);
        console.log(`   npx hardhat settle-dino-proposal --proposal-id ${proposalId} --network kairos`);
      }

    } catch (error) {
      console.error(`\n❌ Proposal error: ${error.message}`);
      throw error;
    }
  });

task("settle-dino-proposal", "Settle a DINO oracle proposal after liveness window")
  .addParam("proposalId", "Proposal ID to settle", undefined, types.int)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    const DINO_ORACLE_ADDRESS = process.env.DINO_ORACLE_ADDRESS;
    const dino = await ethers.getContractAt("DinoOracle", DINO_ORACLE_ADDRESS);

    try {
      console.log(`\n🦕 Settling DINO proposal ${taskArgs.proposalId}...`);
      const settleTx = await dino.settleProposal(taskArgs.proposalId);
      const receipt = await settleTx.wait();
      console.log(`✅ Proposal settled! Gas used: ${receipt.gasUsed}`);
    } catch (error) {
      console.error(`❌ Settlement error: ${error.message}`);
      throw error;
    }
  });

task("debug-trigger-evaluation", "Debug trigger price evaluation with current oracle data")
  .addOptionalParam("trancheId", "Tranche ID to test", "1", types.int)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    require("dotenv").config();

    console.log("🔧 Trigger Evaluation Debugger");
    console.log("=" .repeat(60));

    const PRODUCT_CATALOG_ADDRESS = process.env.PRODUCT_CATALOG_ADDRESS;
    const ORACLE_ROUTER_ADDRESS = process.env.ORACLE_ROUTER_ADDRESS;

    if (!PRODUCT_CATALOG_ADDRESS || !ORACLE_ROUTER_ADDRESS) {
      console.log("⚠️  Required addresses not set. Skipping.");
      return;
    }

    try {
      const productCatalog = await ethers.getContractAt("ProductCatalog", PRODUCT_CATALOG_ADDRESS);
      const oracleRouter = await ethers.getContractAt("OracleRouter", ORACLE_ROUTER_ADDRESS);

      console.log(`\n🎯 Testing Tranche: ${taskArgs.trancheId}`);

      // Get tranche spec
      const tranche = await productCatalog.getTranche(taskArgs.trancheId);
      console.log(`\n📋 Tranche Configuration:`);
      console.log(`   🎯 Trigger Type: ${tranche.triggerType} (0=PRICE_BELOW, 1=PRICE_ABOVE)`);
      console.log(`   💰 Threshold (18 decimals): ${tranche.threshold}`);
      console.log(`   💵 Threshold (human): $${ethers.formatEther(tranche.threshold)}`);

      // Determine oracle route and get current price
      const oracleRouteId = Number(tranche.oracleRouteId || 1);
      const routeMapping = {
          1: "BTC-USDT",
          2: "ETH-USDT", 
          3: "KAIA-USDT"
      };
      const targetSymbol = routeMapping[oracleRouteId] || "BTC-USDT";
      const identifier = ethers.keccak256(ethers.toUtf8Bytes(targetSymbol));
      
      console.log(`\n🔮 Oracle Route: ${targetSymbol} (Route ID: ${oracleRouteId})`);
      
      const oracleResult = await oracleRouter.getPrice(identifier);
      console.log(`   💰 Oracle Price (8 decimals): ${oracleResult.price}`);
      console.log(`   💵 Oracle Price (human): $${ethers.formatUnits(oracleResult.price, 8)}`);
      console.log(`   ✅ Valid: ${oracleResult.valid}`);

      // Simulate trigger evaluation
      const normalizedThreshold = tranche.threshold / BigInt(1e10); // Convert 18 to 8 decimals
      console.log(`\n🧮 Trigger Evaluation:`);
      console.log(`   📏 Normalized Threshold (8 decimals): ${normalizedThreshold}`);
      console.log(`   💵 Normalized Threshold (human): $${ethers.formatUnits(normalizedThreshold, 8)}`);

      let triggered = false;
      if (tranche.triggerType === 0n) { // PRICE_BELOW
        triggered = oracleResult.price < normalizedThreshold;
        console.log(`   🔽 PRICE_BELOW: ${oracleResult.price} < ${normalizedThreshold} = ${triggered}`);
      } else if (tranche.triggerType === 1n) { // PRICE_ABOVE
        triggered = oracleResult.price > normalizedThreshold;
        console.log(`   🔼 PRICE_ABOVE: ${oracleResult.price} > ${normalizedThreshold} = ${triggered}`);
      }

      console.log(`\n🎯 Final Result: ${triggered ? "🔥 TRIGGERED" : "✅ Not Triggered"}`);

      if (triggered) {
        console.log(`\n⚠️  Insurance would payout!`);
      } else {
        console.log(`\n✅ Insurance premiums would be kept (no payout).`);
      }

    } catch (error) {
      console.error(`\n❌ Debug error: ${error.message}`);
      throw error;
    }
  });
