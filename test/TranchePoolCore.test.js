const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("TranchePoolCore", function () {
    // Test fixture with all required contracts
    async function deployTranchePoolFixture() {
        const [deployer, buyer, seller, operator] = await ethers.getSigners();

        // Deploy DinRegistry
        const DinRegistry = await ethers.getContractFactory("DinRegistry");
        const registry = await DinRegistry.deploy(deployer.address, "1.0.0");

        // Deploy DinUSDT (6 decimals)
        const DinUSDT = await ethers.getContractFactory("DinUSDT");
        const initialSupply = ethers.parseUnits("1000000", 6); // 1M USDT
        const usdt = await DinUSDT.deploy(initialSupply, "DIN USD Tether", "USDT", 6);

        // Deploy ProductCatalog
        const ProductCatalog = await ethers.getContractFactory("ProductCatalog");
        const productCatalog = await ProductCatalog.deploy(registry.target, deployer.address);

        // Deploy InsuranceToken
        const InsuranceToken = await ethers.getContractFactory("InsuranceToken");
        const insuranceToken = await InsuranceToken.deploy(deployer.address);

        // Deploy FeeTreasury
        const FeeTreasury = await ethers.getContractFactory("FeeTreasury");
        const feeTreasury = await FeeTreasury.deploy(deployer.address, deployer.address, "Emergency Treasury");

        // Register contracts in registry
        await registry.setAddress(await registry.USDT_TOKEN(), usdt.target);
        await registry.setAddress(await registry.PRODUCT_CATALOG(), productCatalog.target);
        await registry.setAddress(await registry.FEE_TREASURY(), feeTreasury.target);
        // Note: INSURANCE_TOKEN is not in the registry constants - might be set differently

        // Grant roles
        const OPERATOR_ROLE = await productCatalog.OPERATOR_ROLE();
        await productCatalog.grantRole(OPERATOR_ROLE, deployer.address);

        // Create a test product
        const productMetadata = ethers.keccak256(ethers.toUtf8Bytes("TestProduct"));
        await productCatalog.createProduct(productMetadata);

        // Create a test tranche with USDT values (6 decimals)
        const now = Math.floor(Date.now() / 1000);
        const maturityTimestamp = now + (24 * 60 * 60); // 24 hours
        
        const trancheParams = {
            productId: 1,
            triggerType: 0, // PRICE_BELOW
            threshold: ethers.parseEther("100000"), // BTC price $100,000 (18 decimals)
            maturityTimestamp: maturityTimestamp,
            premiumRateBps: 300, // 3%
            perAccountMin: ethers.parseUnits("100", 6), // $100 USDT (6 decimals)
            perAccountMax: ethers.parseUnits("10000", 6), // $10,000 USDT (6 decimals)
            trancheCap: ethers.parseUnits("100000", 6), // $100,000 USDT (6 decimals)
            oracleRouteId: 1
        };

        await productCatalog.createTranche(trancheParams);

        // Get tranche details to verify creation
        const trancheSpec = await productCatalog.getTranche(1);

        // Create TrancheInfo for pool deployment (economics-only)
        const trancheInfo = {
            trancheId: 1,
            productId: 1,
            productCatalog: productCatalog.target,
            active: true
        };

        // Deploy TranchePoolCore
        const TranchePoolCore = await ethers.getContractFactory("TranchePoolCore");
        const pool = await TranchePoolCore.deploy(
            registry.target,
            trancheInfo,
            insuranceToken.target,
            deployer.address
        );

        // Grant roles to pool and operator
        const POOL_OPERATOR_ROLE = await pool.OPERATOR_ROLE();
        await pool.grantRole(POOL_OPERATOR_ROLE, operator.address);

        // Authorize pool to mint insurance tokens
        const ADMIN_ROLE = await insuranceToken.DEFAULT_ADMIN_ROLE();
        await insuranceToken.grantRole(ADMIN_ROLE, deployer.address);
        await insuranceToken.setPoolAuthorization(pool.target, true);

        // Issue USDT and transfer to buyers and sellers
        const mintAmount = ethers.parseUnits("2000000", 6); // $2M USDT total
        await usdt.issue(mintAmount);
        
        // Transfer USDT to buyers and sellers (deployer is owner so has the minted amount)
        await usdt.transfer(buyer.address, ethers.parseUnits("1000000", 6)); // $1M USDT
        await usdt.transfer(seller.address, ethers.parseUnits("1000000", 6)); // $1M USDT

        return {
            deployer,
            buyer,
            seller,
            operator,
            registry,
            usdt,
            productCatalog,
            insuranceToken,
            feeTreasury,
            pool,
            trancheInfo,
            trancheSpec
        };
    }

    describe("Deployment", function () {
        it("Should deploy with correct tranche info", async function () {
            const { pool, trancheInfo } = await loadFixture(deployTranchePoolFixture);

            const storedInfo = await pool.getTrancheInfo();
            expect(storedInfo.trancheId).to.equal(trancheInfo.trancheId);
            expect(storedInfo.productId).to.equal(trancheInfo.productId);
            expect(storedInfo.productCatalog).to.equal(trancheInfo.productCatalog);
            expect(storedInfo.active).to.equal(true);
        });

        it("Should have correct USDT decimal values", async function () {
            const { productCatalog } = await loadFixture(deployTranchePoolFixture);
            const trancheSpec = await productCatalog.getTranche(1);
            expect(ethers.formatUnits(trancheSpec.perAccountMin, 6)).to.equal("100.0");
            expect(ethers.formatUnits(trancheSpec.perAccountMax, 6)).to.equal("10000.0");
            expect(ethers.formatUnits(trancheSpec.trancheCap, 6)).to.equal("100000.0");
        });
    });

    describe("Round Management", function () {
        it("Should announce and open a round in catalog", async function () {
            const { productCatalog } = await loadFixture(deployTranchePoolFixture);

            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60; // 1 minute from now
            const salesEnd = salesStart + 3600; // 1 hour sales window

            const announceTx = await productCatalog.announceRound(1, salesStart, salesEnd);
            await announceTx.wait();

            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            const round = await productCatalog.getRound(1);
            expect(round.state).to.equal(1); // OPEN
        });
    });

    describe("Buyer Orders", function () {
        it("Should place a valid buyer order", async function () {
            const { pool, operator, buyer, usdt, insuranceToken, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            const announceTx = await productCatalog.announceRound(1, salesStart, salesEnd);
            await announceTx.wait();
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Purchase amount: $1000 USDT (6 decimals)
            const purchaseAmount = ethers.parseUnits("1000", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            // Approve USDT
            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Get initial balances
            const initialUsdtBalance = await usdt.balanceOf(buyer.address);
            const initialTokenCount = await insuranceToken.balanceOf(buyer.address);

            // Place buyer order
            await pool.connect(buyer).placeBuyerOrder(1, purchaseAmount);

            // Verify order was placed
            const buyerOrder = await pool.getBuyerOrder(1, buyer.address);
            expect(buyerOrder.buyer).to.equal(buyer.address);
            expect(buyerOrder.purchaseAmount).to.equal(purchaseAmount);
            expect(buyerOrder.premiumPaid).to.equal(premium);

            // Verify USDT was transferred
            const finalUsdtBalance = await usdt.balanceOf(buyer.address);
            expect(initialUsdtBalance - finalUsdtBalance).to.equal(premium);

            // Verify insurance token was minted
            const finalTokenCount = await insuranceToken.balanceOf(buyer.address);
            expect(finalTokenCount - initialTokenCount).to.equal(1);
        });

        it("Should reject purchase below minimum", async function () {
            const { pool, operator, buyer, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            const announceTx = await productCatalog.announceRound(1, salesStart, salesEnd);
            await announceTx.wait();
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Purchase amount below minimum: $50 USDT (minimum is $100)
            const purchaseAmount = ethers.parseUnits("50", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Should revert with AccountLimitExceeded
            await expect(
                pool.connect(buyer).placeBuyerOrder(1, purchaseAmount)
            ).to.be.revertedWithCustomError(pool, "AccountLimitExceeded");
        });

        it("Should reject purchase above maximum", async function () {
            const { pool, operator, buyer, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Purchase amount above maximum: $20,000 USDT (maximum is $10,000)
            const purchaseAmount = ethers.parseUnits("20000", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Should revert with AccountLimitExceeded
            await expect(
                pool.connect(buyer).placeBuyerOrder(1, purchaseAmount)
            ).to.be.revertedWithCustomError(pool, "AccountLimitExceeded");
        });

        it("Should calculate premium correctly", async function () {
            const { pool } = await loadFixture(deployTranchePoolFixture);

            const purchaseAmount = ethers.parseUnits("1000", 6); // $1000
            const premium = await pool.calculatePremium(purchaseAmount);
            
            // Premium should be 3% of purchase amount
            const expectedPremium = (purchaseAmount * 300n) / 10000n; // 3%
            expect(premium).to.equal(expectedPremium);
            
            // Convert to readable format
            expect(ethers.formatUnits(premium, 6)).to.equal("30.0"); // $30
        });
    });

    describe("Seller Collateral", function () {
        it("Should accept collateral deposit", async function () {
            const { pool, operator, seller, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Collateral amount: $5000 USDT
            const collateralAmount = ethers.parseUnits("5000", 6);

            // Approve USDT
            await usdt.connect(seller).approve(pool.target, collateralAmount);

            // Get initial state
            const initialUsdtBalance = await usdt.balanceOf(seller.address);
            const initialShares = await pool.shareBalances(seller.address);

            // Deposit collateral
            await pool.connect(seller).depositCollateral(1, collateralAmount);

            // Verify collateral was deposited
            const sellerPosition = await pool.getSellerPosition(1, seller.address);
            expect(sellerPosition.seller).to.equal(seller.address);
            expect(sellerPosition.collateralAmount).to.equal(collateralAmount);

            // Verify USDT was transferred
            const finalUsdtBalance = await usdt.balanceOf(seller.address);
            expect(initialUsdtBalance - finalUsdtBalance).to.equal(collateralAmount);

            // Verify shares were minted
            const finalShares = await pool.shareBalances(seller.address);
            expect(finalShares).to.be.gt(initialShares);
        });
    });

    describe("Round States", function () {
        it("Should reject orders when round is not open", async function () {
            const { pool, operator, buyer, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create round but don't open it
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);

            const purchaseAmount = ethers.parseUnits("1000", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Should revert because round is still ANNOUNCED in catalog
            await expect(
                pool.connect(buyer).placeBuyerOrder(1, purchaseAmount)
            ).to.be.revertedWithCustomError(pool, "InvalidRoundState");
        });
    });

    describe("Edge Cases", function () {
        it("Should handle exact minimum purchase amount", async function () {
            const { pool, operator, buyer, usdt, insuranceToken, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Purchase exactly the minimum amount: $100 USDT
            const purchaseAmount = ethers.parseUnits("100", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Should succeed
            await expect(
                pool.connect(buyer).placeBuyerOrder(1, purchaseAmount)
            ).to.not.be.reverted;

            // Verify order was placed
            const buyerOrder = await pool.getBuyerOrder(1, buyer.address);
            expect(buyerOrder.purchaseAmount).to.equal(purchaseAmount);
        });

        it("Should handle exact maximum purchase amount", async function () {
            const { pool, operator, buyer, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Purchase exactly the maximum amount: $10,000 USDT
            const purchaseAmount = ethers.parseUnits("10000", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            const totalCost = purchaseAmount + premium;

            await usdt.connect(buyer).approve(pool.target, totalCost);

            // Should succeed
            await expect(
                pool.connect(buyer).placeBuyerOrder(1, purchaseAmount)
            ).to.not.be.reverted;

            // Verify order was placed
            const buyerOrder = await pool.getBuyerOrder(1, buyer.address);
            expect(buyerOrder.purchaseAmount).to.equal(purchaseAmount);
        });
    });

    describe("USDT Integration", function () {
        it("Should work with 6-decimal USDT amounts", async function () {
            const { pool, usdt } = await loadFixture(deployTranchePoolFixture);

            // Verify USDT has 6 decimals
            expect(await usdt.decimals()).to.equal(6);

            // Test various USDT amounts
            const amounts = ["100", "1000", "10000"];
            
            for (const amount of amounts) {
                const amountWei = ethers.parseUnits(amount, 6);
                const premium = await pool.calculatePremium(amountWei);
                
                // Premium should be 3% of amount
                const expectedPremiumWei = (amountWei * 300n) / 10000n;
                expect(premium).to.equal(expectedPremiumWei);
                
                // Convert back to readable format
                const expectedPremium = (parseFloat(amount) * 0.03);
                expect(Number(ethers.formatUnits(premium, 6))).to.equal(expectedPremium);
            }
        });
    });

    describe("Matching and Refunds", function () {
        it("Should compute match, lock matched collateral, and refund only unfilled seller remainder", async function () {
            const { pool, operator, buyer, seller, usdt, productCatalog } = await loadFixture(deployTranchePoolFixture);

            // Create and open round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60;
            const salesEnd = salesStart + 3600;

            await productCatalog.announceRound(1, salesStart, salesEnd);
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesStart]);
            await productCatalog.openRound(1);

            // Buyer purchases $1500
            const purchaseAmount = ethers.parseUnits("1500", 6);
            const premium = await pool.calculatePremium(purchaseAmount);
            await usdt.connect(buyer).approve(pool.target, purchaseAmount + premium);
            await pool.connect(buyer).placeBuyerOrder(1, purchaseAmount);

            // Seller deposits $1750
            const depositAmount = ethers.parseUnits("1750", 6);
            await usdt.connect(seller).approve(pool.target, depositAmount);
            const sellerUsdtBefore = await usdt.balanceOf(seller.address);
            const sellerSharesBefore = await pool.shareBalances(seller.address);
            await pool.connect(seller).depositCollateral(1, depositAmount);
            const sellerUsdtAfterDeposit = await usdt.balanceOf(seller.address);
            const sellerSharesAfterDeposit = await pool.shareBalances(seller.address);

            // End sales window
            await ethers.provider.send("evm_setNextBlockTimestamp", [salesEnd + 1]);

            // Compute match
            await pool.connect(operator).computeMatchAndDistribute(1);

            // Round economics
            const econ = await pool.getRoundEconomics(1);
            expect(econ[2]).to.equal(purchaseAmount); // matchedAmount = 1500
            expect(econ[3]).to.equal(purchaseAmount); // lockedCollateral = 1500

            // Seller should receive: unmatched refund (250) + premium share (40.5) = 290.5
            const sellerUsdtAfter = await usdt.balanceOf(seller.address);
            const expectedRefund = ethers.parseUnits("250", 6); // Unmatched portion
            const protocolFee = (premium * 1000n) / 10000n; // 10% protocol fee  
            const sellerPremiumShare = premium - protocolFee; // 90% to seller
            const expectedTotal = expectedRefund + sellerPremiumShare;
            // Compare total (refund + premium) relative to post-deposit balance
            expect(sellerUsdtAfter - sellerUsdtAfterDeposit).to.equal(expectedTotal);

            // Shares: only a proportional portion remains (locked) corresponding to 1500 of 1750
            const sellerPos = await pool.getSellerPosition(1, seller.address);
            const sellerSharesAfter = await pool.shareBalances(seller.address);
            expect(sellerPos.filled).to.equal(true);
            expect(sellerPos.collateralAmount).to.equal(purchaseAmount); // updated to filled portion
            // After matching, shares should be lower than immediately after deposit due to burning unmatched portion
            expect(sellerSharesAfter).to.be.lt(sellerSharesAfterDeposit);

            // Locked assets equals matched amount
            const poolAccounting = await pool.getPoolAccounting();
            expect(poolAccounting.lockedAssets).to.equal(purchaseAmount);
        });
    });

});
