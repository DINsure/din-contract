const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("YieldRouter Integration with TranchePoolCore", function () {
    let yieldRouter, dinRegistry, dinUSDT, tranchePoolCore, productCatalog;
    let owner, admin, operator, buyer, seller;
    let poolAddress;

    beforeEach(async function () {
        [owner, admin, operator, buyer, seller] = await ethers.getSigners();

        // Deploy core contracts
        const DinUSDT = await ethers.getContractFactory("DinUSDT");
        dinUSDT = await DinUSDT.deploy("DIN USDT", "USDT", admin.address);

        const DinRegistry = await ethers.getContractFactory("DinRegistry");
        dinRegistry = await DinRegistry.deploy(admin.address, "1.0.0");

        // Set USDT in registry
        await dinRegistry.connect(admin).setAddress(
            await dinRegistry.USDT_TOKEN(),
            await dinUSDT.getAddress()
        );

        // Deploy FeeTreasury
        const FeeTreasury = await ethers.getContractFactory("FeeTreasury");
        const feeTreasury = await FeeTreasury.deploy(await dinRegistry.getAddress(), admin.address);
        
        await dinRegistry.connect(admin).setAddress(
            await dinRegistry.FEE_TREASURY(),
            await feeTreasury.getAddress()
        );

        // Deploy ProductCatalog
        const ProductCatalog = await ethers.getContractFactory("ProductCatalog");
        productCatalog = await ProductCatalog.deploy(await dinRegistry.getAddress(), admin.address);

        // Deploy InsuranceToken
        const InsuranceToken = await ethers.getContractFactory("InsuranceToken");
        const insuranceToken = await InsuranceToken.deploy(await dinRegistry.getAddress(), admin.address);

        // Deploy TranchePoolFactory
        const TranchePoolFactory = await ethers.getContractFactory("TranchePoolFactory");
        const tranchePoolFactory = await TranchePoolFactory.deploy(
            await dinRegistry.getAddress(),
            await insuranceToken.getAddress(),
            admin.address
        );

        // Deploy YieldRouter
        const YieldRouter = await ethers.getContractFactory("YieldRouter");
        yieldRouter = await YieldRouter.deploy(await dinRegistry.getAddress(), admin.address);

        // Grant roles
        await productCatalog.connect(admin).grantRole(await productCatalog.OPERATOR_ROLE(), operator.address);
        await tranchePoolFactory.connect(admin).grantRole(await tranchePoolFactory.OPERATOR_ROLE(), operator.address);
        await yieldRouter.connect(admin).grantRole(await yieldRouter.OPERATOR_ROLE(), operator.address);

        // Register test product and tranche
        await productCatalog.connect(operator).registerProduct("Yield Test Product", "Test product", true);
        
        const trancheParams = {
            productId: 1,
            name: "Yield Test Tranche",
            premiumRateBps: 300, // 3%
            trancheCap: ethers.parseUnits("50000", 6),
            perAccountMin: ethers.parseUnits("100", 6),
            perAccountMax: ethers.parseUnits("5000", 6),
            triggerType: 0, // PRICE_BELOW
            threshold: ethers.parseEther("50000"),
            maturitySeconds: 30 * 24 * 60 * 60,
            oracleRouteId: 1,
            active: true
        };
        
        await productCatalog.connect(operator).registerTranche(trancheParams);

        // Create pool
        await tranchePoolFactory.connect(operator).createTranchePool(1);
        poolAddress = await tranchePoolFactory.getTranchePool(1);
        tranchePoolCore = await ethers.getContractAt("TranchePoolCore", poolAddress);

        // Set yield router and grant roles
        await tranchePoolCore.connect(admin).setYieldRouter(await yieldRouter.getAddress());
        await tranchePoolCore.connect(admin).grantRole(await tranchePoolCore.OPERATOR_ROLE(), operator.address);

        // Mint USDT
        await dinUSDT.connect(admin).mint(buyer.address, ethers.parseUnits("10000", 6));
        await dinUSDT.connect(admin).mint(seller.address, ethers.parseUnits("10000", 6));
        await dinUSDT.connect(admin).mint(admin.address, ethers.parseUnits("20000", 6));

        // Authorize pool for insurance token minting
        await insuranceToken.connect(admin).setPoolAuthorization(poolAddress, true);
    });

    describe("Full Yield Generation Flow", function () {
        let roundId;

        beforeEach(async function () {
            // Create and open a round
            const now = Math.floor(Date.now() / 1000);
            const salesStart = now + 60; // 1 minute from now
            const salesEnd = salesStart + 3600; // 1 hour sales window
            
            // Announce round
            await productCatalog.connect(operator).announceRound(1, salesStart, salesEnd);
            roundId = 1;
            
            // Open round (simulate time passage)
            await productCatalog.connect(operator).openRound(roundId);

            // Buyer places order
            const buyAmount = ethers.parseUnits("1000", 6); // $1000 coverage
            const premium = ethers.parseUnits("30", 6); // 3% premium
            
            await dinUSDT.connect(buyer).approve(poolAddress, premium);
            await tranchePoolCore.connect(buyer).placeBuyerOrder(roundId, buyAmount);

            // Seller deposits collateral
            const collateralAmount = ethers.parseUnits("2000", 6); // $2000 collateral
            
            await dinUSDT.connect(seller).approve(poolAddress, collateralAmount);
            await tranchePoolCore.connect(seller).depositCollateral(roundId, collateralAmount);

            // Close and match the round
            await tranchePoolCore.connect(operator).computeMatchAndDistribute(roundId);
            await productCatalog.connect(operator).closeAndMarkMatched(roundId, buyAmount);
        });

        it("Should move idle funds to yield generation", async function () {
            // Check available funds for yield
            const availableForYield = await tranchePoolCore.getAvailableForYield();
            expect(availableForYield).to.be.gt(0);

            const moveAmount = ethers.parseUnits("500", 6); // Move $500 to yield
            
            // Move funds to yield
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);

            // Verify pool accounting
            const poolAccounting = await tranchePoolCore.getPoolAccounting();
            expect(poolAccounting.yieldDeposited).to.equal(moveAmount);

            // Verify YieldRouter records
            const deposit = await yieldRouter.getPoolDeposit(poolAddress);
            expect(deposit.active).to.be.true;
            expect(deposit.depositedAmount).to.equal(moveAmount);

            const yieldRecord = await yieldRouter.getYieldRecord();
            expect(yieldRecord.totalDeposited).to.equal(moveAmount);
        });

        it("Should prevent moving locked funds to yield", async function () {
            // Try to move more than available (should be rejected)
            const poolAccounting = await tranchePoolCore.getPoolAccounting();
            const availableForYield = await tranchePoolCore.getAvailableForYield();
            const excessAmount = availableForYield + ethers.parseUnits("1000", 6);

            await expect(tranchePoolCore.connect(operator).moveToYield(excessAmount))
                .to.be.revertedWithCustomError(tranchePoolCore, "InsufficientAvailableFunds");
        });

        it("Should allow admin to withdraw for external investment", async function () {
            // Move funds to yield first
            const moveAmount = ethers.parseUnits("500", 6);
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);

            // Admin withdraws for external investment
            const withdrawAmount = ethers.parseUnits("300", 6);
            const adminBalanceBefore = await dinUSDT.balanceOf(admin.address);

            await yieldRouter.connect(admin).adminWithdraw(withdrawAmount, "DeFi farming");

            const adminBalanceAfter = await dinUSDT.balanceOf(admin.address);
            expect(adminBalanceAfter - adminBalanceBefore).to.equal(withdrawAmount);

            // Available for withdrawal should be reduced
            const availableForWithdrawal = await yieldRouter.getAvailableForWithdrawal();
            expect(availableForWithdrawal).to.equal(moveAmount - withdrawAmount);
        });

        it("Should return funds with yield and update NAV", async function () {
            // Move funds to yield
            const moveAmount = ethers.parseUnits("500", 6);
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);

            // Check initial NAV
            const initialAccounting = await tranchePoolCore.getPoolAccounting();
            const initialNav = initialAccounting.navPerShare;

            // Admin simulates investment return
            const yieldAmount = ethers.parseUnits("50", 6); // $50 yield (10% return)
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yieldAmount);

            // Return funds with yield
            await tranchePoolCore.connect(operator).returnFromYield(yieldAmount);

            // Check updated accounting
            const updatedAccounting = await tranchePoolCore.getPoolAccounting();
            expect(updatedAccounting.yieldDeposited).to.equal(0); // Should be reset
            expect(updatedAccounting.yieldEarned).to.equal(yieldAmount);
            expect(updatedAccounting.totalAssets).to.equal(initialAccounting.totalAssets + yieldAmount);
            expect(updatedAccounting.navPerShare).to.be.gt(initialNav); // NAV should increase

            // Verify YieldRouter state
            const deposit = await yieldRouter.getPoolDeposit(poolAddress);
            expect(deposit.active).to.be.false;

            const yieldRecord = await yieldRouter.getYieldRecord();
            expect(yieldRecord.totalYieldGenerated).to.equal(yieldAmount);
        });

        it("Should return funds with zero yield", async function () {
            // Move funds to yield
            const moveAmount = ethers.parseUnits("500", 6);
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);

            // Return funds with zero yield
            await tranchePoolCore.connect(operator).returnFromYield(0);

            // Check accounting - no yield should be added
            const updatedAccounting = await tranchePoolCore.getPoolAccounting();
            expect(updatedAccounting.yieldDeposited).to.equal(0);
            expect(updatedAccounting.yieldEarned).to.equal(0);
        });

        it("Should handle multiple yield cycles", async function () {
            const moveAmount = ethers.parseUnits("300", 6);
            
            // First cycle
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);
            
            const yieldAmount1 = ethers.parseUnits("30", 6);
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yieldAmount1);
            await tranchePoolCore.connect(operator).returnFromYield(yieldAmount1);

            // Second cycle (if there are still available funds)
            const availableForYield = await tranchePoolCore.getAvailableForYield();
            if (availableForYield >= moveAmount) {
                await tranchePoolCore.connect(operator).moveToYield(moveAmount);
                
                const yieldAmount2 = ethers.parseUnits("25", 6);
                await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yieldAmount2);
                await tranchePoolCore.connect(operator).returnFromYield(yieldAmount2);

                // Check cumulative yield
                const finalAccounting = await tranchePoolCore.getPoolAccounting();
                expect(finalAccounting.yieldEarned).to.equal(yieldAmount1 + yieldAmount2);
            }
        });
    });

    describe("Settlement Impact on Yield", function () {
        let roundId;

        beforeEach(async function () {
            // Setup a round with yield generation
            const now = Math.floor(Date.now() / 1000);
            await productCatalog.connect(operator).announceRound(1, now + 60, now + 3660);
            roundId = 1;
            await productCatalog.connect(operator).openRound(roundId);

            // Buyer and seller participate
            const buyAmount = ethers.parseUnits("1000", 6);
            const premium = ethers.parseUnits("30", 6);
            
            await dinUSDT.connect(buyer).approve(poolAddress, premium);
            await tranchePoolCore.connect(buyer).placeBuyerOrder(roundId, buyAmount);

            const collateralAmount = ethers.parseUnits("2000", 6);
            await dinUSDT.connect(seller).approve(poolAddress, collateralAmount);
            await tranchePoolCore.connect(seller).depositCollateral(roundId, collateralAmount);

            // Close and match
            await tranchePoolCore.connect(operator).computeMatchAndDistribute(roundId);
            await productCatalog.connect(operator).closeAndMarkMatched(roundId, buyAmount);

            // Move funds to yield and generate yield
            const moveAmount = ethers.parseUnits("500", 6);
            await tranchePoolCore.connect(operator).moveToYield(moveAmount);
            
            const yieldAmount = ethers.parseUnits("50", 6);
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yieldAmount);
            await tranchePoolCore.connect(operator).returnFromYield(yieldAmount);
        });

        it("Should distribute yield to sellers when not triggered", async function () {
            // Check seller's shares before settlement
            const sellerSharesBefore = await tranchePoolCore.shareBalances(seller.address);
            const navBefore = (await tranchePoolCore.getPoolAccounting()).navPerShare;

            // Simulate settlement (not triggered) - mock the settlement engine call
            await tranchePoolCore.connect(admin).grantRole(
                await tranchePoolCore.SETTLEMENT_ROLE(), 
                admin.address
            );
            
            // Release seller collateral (not triggered case)
            await tranchePoolCore.connect(admin).releaseSellerCollateral(roundId);

            // Seller should still have their shares with increased NAV (yield benefit)
            const sellerSharesAfter = await tranchePoolCore.shareBalances(seller.address);
            const navAfter = (await tranchePoolCore.getPoolAccounting()).navPerShare;
            
            expect(sellerSharesAfter).to.equal(sellerSharesBefore); // Shares unchanged
            expect(navAfter).to.be.gt(navBefore); // NAV increased due to yield
        });

        it("Should burn collateral shares but keep yield benefits when triggered", async function () {
            // Grant settlement role for testing
            await tranchePoolCore.connect(admin).grantRole(
                await tranchePoolCore.SETTLEMENT_ROLE(), 
                admin.address
            );

            // Check seller's shares and NAV before
            const sellerSharesBefore = await tranchePoolCore.shareBalances(seller.address);
            const totalSharesBefore = (await tranchePoolCore.getPoolAccounting()).totalShares;
            const navBefore = (await tranchePoolCore.getPoolAccounting()).navPerShare;

            // Execute buyer payouts (triggered case)
            await tranchePoolCore.connect(admin).executeBuyerPayouts(roundId);

            // Seller should lose some shares (collateral portion) but NAV should preserve yield
            const sellerSharesAfter = await tranchePoolCore.shareBalances(seller.address);
            const totalSharesAfter = (await tranchePoolCore.getPoolAccounting()).totalShares;
            const navAfter = (await tranchePoolCore.getPoolAccounting()).navPerShare;
            
            expect(sellerSharesAfter).to.be.lt(sellerSharesBefore); // Collateral shares burned
            expect(totalSharesAfter).to.be.lt(totalSharesBefore); // Total shares reduced
            expect(navAfter).to.be.gte(navBefore); // NAV preserves yield (seller keeps yield benefit)
        });
    });

    describe("Error Cases", function () {
        it("Should reject yield operations without yield router set", async function () {
            // Create a new pool without yield router
            const TranchePoolCore = await ethers.getContractFactory("TranchePoolCore");
            const trancheInfo = {
                trancheId: 999,
                productId: 1,
                productCatalog: await productCatalog.getAddress(),
                active: true
            };
            
            const newPool = await TranchePoolCore.deploy(
                await dinRegistry.getAddress(),
                trancheInfo,
                ethers.ZeroAddress, // No insurance token for simplicity
                admin.address
            );

            await newPool.connect(admin).grantRole(await newPool.OPERATOR_ROLE(), operator.address);

            // Should revert without yield router set
            await expect(newPool.connect(operator).moveToYield(ethers.parseUnits("100", 6)))
                .to.be.revertedWithCustomError(newPool, "YieldRouterNotSet");
        });

        it("Should reject returning from yield without prior deposit", async function () {
            await expect(tranchePoolCore.connect(operator).returnFromYield(0))
                .to.be.revertedWithCustomError(tranchePoolCore, "InvalidYieldReturn");
        });
    });
});
