const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("YieldRouter", function () {
    let yieldRouter, dinRegistry, dinUSDT, tranchePoolCore1, tranchePoolCore2, productCatalog, tranchePoolFactory;
    let owner, admin, operator, user1, user2;
    let poolAddress1, poolAddress2;

    beforeEach(async function () {
        [owner, admin, operator, user1, user2] = await ethers.getSigners();

        // Deploy DinUSDT
        const DinUSDT = await ethers.getContractFactory("DinUSDT");
        dinUSDT = await DinUSDT.deploy("DIN USDT", "USDT", admin.address);

        // Deploy DinRegistry
        const DinRegistry = await ethers.getContractFactory("DinRegistry");
        dinRegistry = await DinRegistry.deploy(admin.address, "1.0.0");

        // Set USDT in registry
        await dinRegistry.connect(admin).setAddress(
            await dinRegistry.USDT_TOKEN(),
            await dinUSDT.getAddress()
        );

        // Deploy YieldRouter
        const YieldRouter = await ethers.getContractFactory("YieldRouter");
        yieldRouter = await YieldRouter.deploy(await dinRegistry.getAddress(), admin.address);

        // Set YieldRouter in registry
        await dinRegistry.connect(admin).setAddress(
            await dinRegistry.YIELD_ROUTER(),
            await yieldRouter.getAddress()
        );

        // Grant roles
        await yieldRouter.connect(admin).grantRole(await yieldRouter.OPERATOR_ROLE(), operator.address);

        // Deploy mock ProductCatalog
        const ProductCatalog = await ethers.getContractFactory("ProductCatalog");
        productCatalog = await ProductCatalog.deploy(await dinRegistry.getAddress(), admin.address);

        // Deploy InsuranceToken
        const InsuranceToken = await ethers.getContractFactory("InsuranceToken");
        const insuranceToken = await InsuranceToken.deploy(await dinRegistry.getAddress(), admin.address);

        // Deploy TranchePoolFactory
        const TranchePoolFactory = await ethers.getContractFactory("TranchePoolFactory");
        tranchePoolFactory = await TranchePoolFactory.deploy(
            await dinRegistry.getAddress(),
            await insuranceToken.getAddress(),
            admin.address
        );

        // Create two test pools
        const trancheInfo1 = {
            trancheId: 1,
            productId: 1,
            productCatalog: await productCatalog.getAddress(),
            active: true
        };
        
        const trancheInfo2 = {
            trancheId: 2,
            productId: 1,
            productCatalog: await productCatalog.getAddress(),
            active: true
        };

        const TranchePoolCore = await ethers.getContractFactory("TranchePoolCore");
        tranchePoolCore1 = await TranchePoolCore.deploy(
            await dinRegistry.getAddress(),
            trancheInfo1,
            await insuranceToken.getAddress(),
            admin.address
        );

        tranchePoolCore2 = await TranchePoolCore.deploy(
            await dinRegistry.getAddress(),
            trancheInfo2,
            await insuranceToken.getAddress(),
            admin.address
        );

        poolAddress1 = await tranchePoolCore1.getAddress();
        poolAddress2 = await tranchePoolCore2.getAddress();

        // Grant operator roles on pools
        await tranchePoolCore1.connect(admin).grantRole(await tranchePoolCore1.OPERATOR_ROLE(), operator.address);
        await tranchePoolCore2.connect(admin).grantRole(await tranchePoolCore2.OPERATOR_ROLE(), operator.address);

        // Mint USDT to users and admin
        await dinUSDT.connect(admin).mint(user1.address, ethers.parseUnits("10000", 6));
        await dinUSDT.connect(admin).mint(user2.address, ethers.parseUnits("10000", 6));
        await dinUSDT.connect(admin).mint(admin.address, ethers.parseUnits("20000", 6));
        
        // Mint USDT to pools (simulate some pool activity)
        await dinUSDT.connect(admin).mint(poolAddress1, ethers.parseUnits("5000", 6));
        await dinUSDT.connect(admin).mint(poolAddress2, ethers.parseUnits("3000", 6));
    });

    describe("Deployment and Pool Registration", function () {
        it("Should set the correct admin and roles", async function () {
            expect(await yieldRouter.hasRole(await yieldRouter.ADMIN_ROLE(), admin.address)).to.be.true;
            expect(await yieldRouter.hasRole(await yieldRouter.OPERATOR_ROLE(), operator.address)).to.be.true;
        });

        it("Should initialize with correct registry and USDT token", async function () {
            expect(await yieldRouter.registry()).to.equal(await dinRegistry.getAddress());
            expect(await yieldRouter.usdtToken()).to.equal(await dinUSDT.getAddress());
        });

        it("Should automatically register pools on deployment", async function () {
            const registeredPools = await yieldRouter.getRegisteredPools();
            expect(registeredPools).to.include(poolAddress1);
            expect(registeredPools).to.include(poolAddress2);
            
            const poolInfo1 = await yieldRouter.getPoolInfo(poolAddress1);
            expect(poolInfo1.registered).to.be.true;
            expect(poolInfo1.trancheId).to.equal(1);
            expect(poolInfo1.fundsInYield).to.equal(0);
        });

        it("Should prevent duplicate pool registration", async function () {
            await expect(yieldRouter.connect(operator).registerPool(poolAddress1))
                .to.be.revertedWithCustomError(yieldRouter, "PoolAlreadyRegistered");
        });
    });

    describe("Fund Movement from YieldRouter Perspective", function () {
        const moveAmount = ethers.parseUnits("1000", 6); // $1000

        it("Should move funds from pool to yield generation", async function () {
            const balanceBefore = await dinUSDT.balanceOf(await yieldRouter.getAddress());
            
            await expect(yieldRouter.connect(operator).moveFromPool(poolAddress1, moveAmount))
                .to.emit(yieldRouter, "FundsMovedToYield")
                .withArgs(poolAddress1, moveAmount, anyValue);

            const balanceAfter = await dinUSDT.balanceOf(await yieldRouter.getAddress());
            expect(balanceAfter - balanceBefore).to.equal(moveAmount);

            const poolInfo = await yieldRouter.getPoolInfo(poolAddress1);
            expect(poolInfo.fundsInYield).to.equal(moveAmount);

            const yieldRecord = await yieldRouter.getYieldRecord();
            expect(yieldRecord.totalDeposited).to.equal(moveAmount);
        });

        it("Should reject move from unregistered pool", async function () {
            await expect(yieldRouter.connect(operator).moveFromPool(user1.address, moveAmount))
                .to.be.revertedWithCustomError(yieldRouter, "PoolNotRegistered");
        });

        it("Should reject move exceeding available funds", async function () {
            const excessAmount = ethers.parseUnits("10000", 6); // More than pool has
            await expect(yieldRouter.connect(operator).moveFromPool(poolAddress1, excessAmount))
                .to.be.revertedWithCustomError(yieldRouter, "InsufficientPoolFunds");
        });

        it("Should reject unauthorized move", async function () {
            await expect(yieldRouter.connect(user1).moveFromPool(poolAddress1, moveAmount))
                .to.be.revertedWith("AccessControl:");
        });
    });

    describe("Fund Return with Yield", function () {
        const moveAmount = ethers.parseUnits("1000", 6);
        const yieldAmount = ethers.parseUnits("100", 6); // 10% yield

        beforeEach(async function () {
            // Move funds to yield first
            await yieldRouter.connect(operator).moveFromPool(poolAddress1, moveAmount);
        });

        it("Should return funds with zero yield", async function () {
            const poolBalanceBefore = await dinUSDT.balanceOf(poolAddress1);
            
            await expect(yieldRouter.connect(operator).returnToPool(poolAddress1, 0))
                .to.emit(yieldRouter, "FundsReturnedToPool")
                .withArgs(poolAddress1, moveAmount, 0, anyValue);

            const poolBalanceAfter = await dinUSDT.balanceOf(poolAddress1);
            expect(poolBalanceAfter - poolBalanceBefore).to.equal(moveAmount);

            const poolInfo = await yieldRouter.getPoolInfo(poolAddress1);
            expect(poolInfo.fundsInYield).to.equal(0);
        });

        it("Should return funds with positive yield", async function () {
            // Admin deposits yield into YieldRouter
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yieldAmount);
            
            const poolBalanceBefore = await dinUSDT.balanceOf(poolAddress1);
            
            await expect(yieldRouter.connect(operator).returnToPool(poolAddress1, yieldAmount))
                .to.emit(yieldRouter, "FundsReturnedToPool")
                .withArgs(poolAddress1, moveAmount + yieldAmount, yieldAmount, anyValue)
                .to.emit(yieldRouter, "YieldGenerated");

            const poolBalanceAfter = await dinUSDT.balanceOf(poolAddress1);
            expect(poolBalanceAfter - poolBalanceBefore).to.equal(moveAmount + yieldAmount);

            const poolInfo = await yieldRouter.getPoolInfo(poolAddress1);
            expect(poolInfo.fundsInYield).to.equal(0);
            expect(poolInfo.totalYieldEarned).to.equal(yieldAmount);

            const yieldRecord = await yieldRouter.getYieldRecord();
            expect(yieldRecord.totalYieldGenerated).to.equal(yieldAmount);
        });

        it("Should reject return to unregistered pool", async function () {
            await expect(yieldRouter.connect(operator).returnToPool(user1.address, 0))
                .to.be.revertedWithCustomError(yieldRouter, "PoolNotRegistered");
        });

        it("Should reject return with insufficient YieldRouter balance", async function () {
            const excessYield = ethers.parseUnits("10000", 6);
            await expect(yieldRouter.connect(operator).returnToPool(poolAddress1, excessYield))
                .to.be.revertedWithCustomError(yieldRouter, "InsufficientFunds");
        });
    });

    describe("Admin Functions", function () {
        const depositAmount = ethers.parseUnits("1000", 6);
        const withdrawAmount = ethers.parseUnits("500", 6);

        beforeEach(async function () {
            // Setup a pool deposit
            await yieldRouter.connect(operator).moveFromPool(poolAddress1, depositAmount);
        });

        it("Should allow admin withdrawal", async function () {
            // Add extra funds first
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), withdrawAmount);
            
            const balanceBefore = await dinUSDT.balanceOf(admin.address);
            
            await expect(yieldRouter.connect(admin).adminWithdraw(withdrawAmount, "DeFi investment"))
                .to.emit(yieldRouter, "AdminWithdrawal")
                .withArgs(admin.address, withdrawAmount, anyValue, "DeFi investment");
            
            const balanceAfter = await dinUSDT.balanceOf(admin.address);
            expect(balanceAfter - balanceBefore).to.equal(withdrawAmount);
        });

        it("Should reject admin withdrawal exceeding available funds", async function () {
            // Try to withdraw more than available (should leave pool deposits untouched)
            const excessAmount = ethers.parseUnits("2000", 6);
            await expect(yieldRouter.connect(admin).adminWithdraw(excessAmount, "Too much"))
                .to.be.revertedWithCustomError(yieldRouter, "InsufficientFunds");
        });

        it("Should allow admin deposit", async function () {
            const depositBackAmount = ethers.parseUnits("600", 6);
            await dinUSDT.connect(admin).approve(await yieldRouter.getAddress(), depositBackAmount);
            
            await expect(yieldRouter.connect(admin).adminDeposit(depositBackAmount, "Investment return"))
                .to.emit(yieldRouter, "AdminDeposit")
                .withArgs(admin.address, depositBackAmount, anyValue, "Investment return");
        });
    });

    describe("View Functions", function () {
        const depositAmount = ethers.parseUnits("1000", 6);

        beforeEach(async function () {
            await yieldRouter.connect(operator).moveFromPool(poolAddress1, depositAmount);
        });

        it("Should return correct total balance", async function () {
            const balance = await yieldRouter.getTotalBalance();
            expect(balance).to.equal(depositAmount);
        });

        it("Should return correct value at risk", async function () {
            const valueAtRisk = await yieldRouter.getTotalValueAtRisk();
            expect(valueAtRisk).to.equal(depositAmount);
        });

        it("Should return zero available for withdrawal when all funds at risk", async function () {
            const available = await yieldRouter.getAvailableForWithdrawal();
            expect(available).to.equal(0); // All funds are at risk for pool return
        });

        it("Should return correct available for withdrawal with excess funds", async function () {
            // Admin adds extra funds
            const extraFunds = ethers.parseUnits("500", 6);
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), extraFunds);
            
            const available = await yieldRouter.getAvailableForWithdrawal();
            expect(available).to.equal(extraFunds);
        });

        it("Should return registered pools", async function () {
            const registeredPools = await yieldRouter.getRegisteredPools();
            expect(registeredPools.length).to.be.gte(2);
            expect(registeredPools).to.include(poolAddress1);
            expect(registeredPools).to.include(poolAddress2);
        });

        it("Should return comprehensive yield status", async function () {
            const [
                totalBalance,
                totalValueAtRisk,
                availableForWithdrawal,
                totalPoolsRegistered,
                totalActiveDeposits,
                yieldRecord
            ] = await yieldRouter.getYieldStatus();

            expect(totalBalance).to.equal(depositAmount);
            expect(totalValueAtRisk).to.equal(depositAmount);
            expect(availableForWithdrawal).to.equal(0);
            expect(totalPoolsRegistered).to.be.gte(2);
            expect(totalActiveDeposits).to.equal(1); // Only pool1 has active deposit
        });
    });

    describe("Multi-Pool Operations", function () {
        const moveAmount = ethers.parseUnits("500", 6);

        it("Should handle multiple pools simultaneously", async function () {
            // Move funds from both pools
            await yieldRouter.connect(operator).moveFromPool(poolAddress1, moveAmount);
            await yieldRouter.connect(operator).moveFromPool(poolAddress2, moveAmount);

            const valueAtRisk = await yieldRouter.getTotalValueAtRisk();
            expect(valueAtRisk).to.equal(moveAmount * 2n);

            const poolInfo1 = await yieldRouter.getPoolInfo(poolAddress1);
            const poolInfo2 = await yieldRouter.getPoolInfo(poolAddress2);
            
            expect(poolInfo1.fundsInYield).to.equal(moveAmount);
            expect(poolInfo2.fundsInYield).to.equal(moveAmount);

            // Return funds to both pools with different yields
            const yield1 = ethers.parseUnits("50", 6);
            const yield2 = ethers.parseUnits("75", 6);
            
            // Admin adds yield
            await dinUSDT.connect(admin).transfer(await yieldRouter.getAddress(), yield1 + yield2);
            
            await yieldRouter.connect(operator).returnToPool(poolAddress1, yield1);
            await yieldRouter.connect(operator).returnToPool(poolAddress2, yield2);

            const finalPoolInfo1 = await yieldRouter.getPoolInfo(poolAddress1);
            const finalPoolInfo2 = await yieldRouter.getPoolInfo(poolAddress2);
            
            expect(finalPoolInfo1.totalYieldEarned).to.equal(yield1);
            expect(finalPoolInfo2.totalYieldEarned).to.equal(yield2);
        });
    });

    describe("Emergency Controls", function () {
        const depositAmount = ethers.parseUnits("1000", 6);

        beforeEach(async function () {
            await yieldRouter.connect(operator).moveFromPool(poolAddress1, depositAmount);
        });

        it("Should allow emergency pause and fund return", async function () {
            await yieldRouter.connect(admin).pause();
            expect(await yieldRouter.paused()).to.be.true;
            
            // Should reject operations when paused
            await expect(yieldRouter.connect(operator).moveFromPool(poolAddress2, depositAmount))
                .to.be.revertedWith("Pausable: paused");

            // Emergency return all funds
            const poolBalanceBefore = await dinUSDT.balanceOf(poolAddress1);
            await yieldRouter.connect(admin).emergencyReturnAllFunds();
            const poolBalanceAfter = await dinUSDT.balanceOf(poolAddress1);
            
            expect(poolBalanceAfter - poolBalanceBefore).to.equal(depositAmount);
            
            const poolInfo = await yieldRouter.getPoolInfo(poolAddress1);
            expect(poolInfo.fundsInYield).to.equal(0);
        });
    });

    // Helper to match any value in events
    const anyValue = require("@nomicfoundation/hardhat-chai-matchers").anyValue;
});