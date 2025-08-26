const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { ethers } = require("hardhat");

describe("ProductCatalog", function () {
  async function deployProductCatalogFixture() {
    const [admin, operator, pauser, user1, user2] = await ethers.getSigners();
    
    // Deploy Registry first
    const DinRegistry = await ethers.getContractFactory("DinRegistry");
    const registry = await DinRegistry.deploy(admin.address, "1.0.0");
    await registry.waitForDeployment();

    // Deploy ProductCatalog
    const ProductCatalog = await ethers.getContractFactory("ProductCatalog");
    const productCatalog = await ProductCatalog.deploy(registry.target, admin.address);
    await productCatalog.waitForDeployment();

    // Grant roles
    await productCatalog.connect(admin).grantRole(await productCatalog.OPERATOR_ROLE(), operator.address);
    await productCatalog.connect(admin).grantRole(await productCatalog.PAUSER_ROLE(), pauser.address);

    return { productCatalog, registry, admin, operator, pauser, user1, user2 };
  }

  // Helper function to get future timestamp
  const getFutureTimestamp = (daysFromNow = 1) => {
    return Math.floor(Date.now() / 1000) + (daysFromNow * 24 * 60 * 60);
  };

  describe("Deployment", function () {
    it("Should set the correct registry and admin", async function () {
      const { productCatalog, registry, admin } = await loadFixture(deployProductCatalogFixture);
      
      expect(await productCatalog.registry()).to.equal(registry.target);
      expect(await productCatalog.hasRole(await productCatalog.ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await productCatalog.hasRole(await productCatalog.PAUSER_ROLE(), admin.address)).to.be.true;
    });

    it("Should initialize counters correctly", async function () {
      const { productCatalog } = await loadFixture(deployProductCatalogFixture);
      
      expect(await productCatalog.nextProductId()).to.equal(1);
      expect(await productCatalog.nextTrancheId()).to.equal(1);
      expect(await productCatalog.nextRoundId()).to.equal(1);
    });

    it("Should revert if registry or admin is zero address", async function () {
      const [admin] = await ethers.getSigners();
      const ProductCatalog = await ethers.getContractFactory("ProductCatalog");
      
      await expect(
        ProductCatalog.deploy(ethers.ZeroAddress, admin.address)
      ).to.be.revertedWithCustomError(ProductCatalog, "ZeroAddress");
      
      await expect(
        ProductCatalog.deploy(admin.address, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(ProductCatalog, "ZeroAddress");
    });
  });

  describe("Product Management", function () {
    it("Should allow operator to create product", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("product metadata"));
      
      await expect(productCatalog.connect(operator).createProduct(metadataHash))
        .to.emit(productCatalog, "ProductCreated")
        .withArgs(1, metadataHash, operator.address);
      
      const product = await productCatalog.getProduct(1);
      expect(product.productId).to.equal(1);
      expect(product.metadataHash).to.equal(metadataHash);
      expect(product.active).to.be.true;
      expect(product.trancheIds.length).to.equal(0);
      
      const activeProducts = await productCatalog.getActiveProducts();
      expect(activeProducts).to.include(1n);
    });

    it("Should allow operator to update product", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash1 = ethers.keccak256(ethers.toUtf8Bytes("metadata 1"));
      const metadataHash2 = ethers.keccak256(ethers.toUtf8Bytes("metadata 2"));
      
      await productCatalog.connect(operator).createProduct(metadataHash1);
      
      await expect(productCatalog.connect(operator).updateProduct(1, metadataHash2))
        .to.emit(productCatalog, "ProductUpdated")
        .withArgs(1, metadataHash2, operator.address);
      
      const product = await productCatalog.getProduct(1);
      expect(product.metadataHash).to.equal(metadataHash2);
    });

    it("Should allow operator to activate/deactivate product", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      await productCatalog.connect(operator).createProduct(metadataHash);
      
      // Deactivate
      await expect(productCatalog.connect(operator).setProductActive(1, false))
        .to.emit(productCatalog, "ProductDeactivated")
        .withArgs(1);
      
      const product1 = await productCatalog.getProduct(1);
      expect(product1.active).to.be.false;
      
      // Reactivate
      await expect(productCatalog.connect(operator).setProductActive(1, true))
        .to.emit(productCatalog, "ProductActivated")
        .withArgs(1);
      
      const product2 = await productCatalog.getProduct(1);
      expect(product2.active).to.be.true;
    });

    it("Should revert when non-operator tries to create product", async function () {
      const { productCatalog, user1 } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      
      await expect(
        productCatalog.connect(user1).createProduct(metadataHash)
      ).to.be.reverted;
    });

    it("Should revert when updating non-existent product", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      
      await expect(
        productCatalog.connect(operator).updateProduct(999, metadataHash)
      ).to.be.revertedWithCustomError(productCatalog, "ProductNotFound");
    });

    it("Should revert with invalid metadata hash", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      await expect(
        productCatalog.connect(operator).createProduct(ethers.ZeroHash)
      ).to.be.revertedWith("Invalid metadata hash");
    });
  });

  describe("Tranche Management", function () {
    async function createProductAndTranche() {
      const fixture = await loadFixture(deployProductCatalogFixture);
      const { productCatalog, operator } = fixture;
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("product metadata"));
      await productCatalog.connect(operator).createProduct(metadataHash);
      
      const trancheParams = {
        productId: 1,
        triggerType: 0, // PRICE
        threshold: ethers.parseEther("2000"), // $2000
        maturityTimestamp: getFutureTimestamp(30), // 30 days from now
        premiumRateBps: 500, // 5%
        payoutType: 0, // FIXED
        payoutAmount: ethers.parseEther("1000"), // $1000 payout
        perAccountMin: ethers.parseEther("100"), // Min $100
        perAccountMax: ethers.parseEther("10000"), // Max $10k
        trancheCap: ethers.parseEther("100000"), // $100k cap
        oracleRouteId: 1
      };
      
      return { ...fixture, trancheParams };
    }

    it("Should allow operator to create tranche", async function () {
      const { productCatalog, operator, trancheParams } = await createProductAndTranche();
      
      await expect(
        productCatalog.connect(operator).createTranche([
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          trancheParams.maturityTimestamp,
          trancheParams.premiumRateBps,
          trancheParams.payoutType,
          trancheParams.payoutAmount,
          trancheParams.perAccountMin,
          trancheParams.perAccountMax,
          trancheParams.trancheCap,
          trancheParams.oracleRouteId
        ])
      ).to.emit(productCatalog, "TrancheCreated")
        .withArgs(
          1, // trancheId
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          trancheParams.maturityTimestamp,
          operator.address
        );
      
      const tranche = await productCatalog.getTranche(1);
      expect(tranche.trancheId).to.equal(1);
      expect(tranche.productId).to.equal(trancheParams.productId);
      expect(tranche.triggerType).to.equal(trancheParams.triggerType);
      expect(tranche.threshold).to.equal(trancheParams.threshold);
      expect(tranche.active).to.be.true;
      
      const activeTranches = await productCatalog.getActiveTranches();
      expect(activeTranches).to.include(1n);
      
      const productTranches = await productCatalog.getProductTranches(1);
      expect(productTranches).to.include(1n);
    });

    it("Should allow operator to update tranche before first round", async function () {
      const { productCatalog, operator, trancheParams } = await createProductAndTranche();
      
      await productCatalog.connect(operator).createTranche([
        trancheParams.productId,
        trancheParams.triggerType,
        trancheParams.threshold,
        trancheParams.maturityTimestamp,
        trancheParams.premiumRateBps,
        trancheParams.payoutType,
        trancheParams.payoutAmount,
        trancheParams.perAccountMin,
        trancheParams.perAccountMax,
        trancheParams.trancheCap,
        trancheParams.oracleRouteId
      ]);
      
      const newPremiumRate = 1000; // 10%
      const newPerAccountMin = ethers.parseEther("200");
      const newPerAccountMax = ethers.parseEther("20000");
      const newTrancheCapt = ethers.parseEther("200000");
      
      await expect(
        productCatalog.connect(operator).updateTranche(
          1,
          newPremiumRate,
          newPerAccountMin,
          newPerAccountMax,
          newTrancheCapt
        )
      ).to.emit(productCatalog, "TrancheUpdated")
        .withArgs(1, operator.address);
      
      const tranche = await productCatalog.getTranche(1);
      expect(tranche.premiumRateBps).to.equal(newPremiumRate);
      expect(tranche.perAccountMin).to.equal(newPerAccountMin);
    });

    it("Should revert when creating tranche for inactive product", async function () {
      const { productCatalog, operator, trancheParams } = await createProductAndTranche();
      
      // Deactivate product
      await productCatalog.connect(operator).setProductActive(1, false);
      
      await expect(
        productCatalog.connect(operator).createTranche([
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          trancheParams.maturityTimestamp,
          trancheParams.premiumRateBps,
          trancheParams.payoutType,
          trancheParams.payoutAmount,
          trancheParams.perAccountMin,
          trancheParams.perAccountMax,
          trancheParams.trancheCap,
          trancheParams.oracleRouteId
        ])
      ).to.be.revertedWithCustomError(productCatalog, "ProductNotActive");
    });

    it("Should revert with invalid tranche parameters", async function () {
      const { productCatalog, operator, trancheParams } = await createProductAndTranche();
      
      // Invalid maturity (in the past)
      await expect(
        productCatalog.connect(operator).createTranche([
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          Math.floor(Date.now() / 1000) - 1000, // Past timestamp
          trancheParams.premiumRateBps,
          trancheParams.payoutType,
          trancheParams.payoutAmount,
          trancheParams.perAccountMin,
          trancheParams.perAccountMax,
          trancheParams.trancheCap,
          trancheParams.oracleRouteId
        ])
      ).to.be.revertedWithCustomError(productCatalog, "InvalidMaturityTimestamp");
      
      // Invalid premium rate (>100%)
      await expect(
        productCatalog.connect(operator).createTranche(
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          trancheParams.maturityTimestamp,
          10001, // >100%
          trancheParams.payoutType,
          trancheParams.payoutAmount,
          trancheParams.perAccountMin,
          trancheParams.perAccountMax,
          trancheParams.trancheCap,
          trancheParams.oracleRouteId
        )
      ).to.be.revertedWithCustomError(productCatalog, "InvalidPremiumRate");
      
      // Invalid account limits (min > max)
      await expect(
        productCatalog.connect(operator).createTranche(
          trancheParams.productId,
          trancheParams.triggerType,
          trancheParams.threshold,
          trancheParams.maturityTimestamp,
          trancheParams.premiumRateBps,
          trancheParams.payoutType,
          trancheParams.payoutAmount,
          ethers.parseEther("1000"), // min
          ethers.parseEther("500"), // max < min
          trancheParams.trancheCap,
          trancheParams.oracleRouteId
        )
      ).to.be.revertedWithCustomError(productCatalog, "InvalidTrancheParams");
    });
  });

  describe("Round Management", function () {
    async function createProductTrancheAndRound() {
      const fixture = await loadFixture(deployProductCatalogFixture);
      const { productCatalog, operator } = fixture;
      
      // Create product
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("product metadata"));
      await productCatalog.connect(operator).createProduct(metadataHash);
      
      // Create tranche
      await productCatalog.connect(operator).createTranche([
        1, // productId
        0, // PRICE trigger
        ethers.parseEther("2000"),
        getFutureTimestamp(30),
        500, // 5%
        0, // FIXED payout
        ethers.parseEther("1000"),
        ethers.parseEther("100"),
        ethers.parseEther("10000"),
        ethers.parseEther("100000"),
        1 // oracleRouteId
      ]);
      
      const roundParams = {
        trancheId: 1,
        salesStartTime: getFutureTimestamp(1), // 1 day from now
        salesEndTime: getFutureTimestamp(7) // 7 days from now
      };
      
      return { ...fixture, roundParams };
    }

    it("Should allow operator to announce round", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      await expect(
        productCatalog.connect(operator).announceRound(
          roundParams.trancheId,
          roundParams.salesStartTime,
          roundParams.salesEndTime
        )
      ).to.emit(productCatalog, "RoundAnnounced")
        .withArgs(
          1, // roundId
          roundParams.trancheId,
          roundParams.salesStartTime,
          roundParams.salesEndTime,
          operator.address
        );
      
      const round = await productCatalog.getRound(1);
      expect(round.roundId).to.equal(1);
      expect(round.trancheId).to.equal(roundParams.trancheId);
      expect(round.state).to.equal(0); // ANNOUNCED
      
      const trancheRounds = await productCatalog.getTrancheRounds(1);
      expect(trancheRounds).to.include(1n);
    });

    it("Should allow operator to open announced round", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      // Announce round that starts now
      const nowTimestamp = Math.floor(Date.now() / 1000);
      await productCatalog.connect(operator).announceRound(
        roundParams.trancheId,
        nowTimestamp,
        nowTimestamp + 86400 // 1 day later
      );
      
      await expect(productCatalog.connect(operator).openRound(1))
        .to.emit(productCatalog, "RoundOpened")
        .withArgs(1, roundParams.trancheId, await productCatalog.getRound(1).then(r => r.stateChangedAt));
      
      const round = await productCatalog.getRound(1);
      expect(round.state).to.equal(1); // OPEN
    });

    it("Should allow operator to close open round", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      // Announce and open round
      const nowTimestamp = Math.floor(Date.now() / 1000);
      await productCatalog.connect(operator).announceRound(
        roundParams.trancheId,
        nowTimestamp,
        nowTimestamp + 86400
      );
      await productCatalog.connect(operator).openRound(1);
      
      await expect(productCatalog.connect(operator).closeRound(1))
        .to.emit(productCatalog, "RoundClosed")
        .withArgs(1, roundParams.trancheId, await productCatalog.getRound(1).then(r => r.stateChangedAt));
      
      const round = await productCatalog.getRound(1);
      expect(round.state).to.equal(2); // MATCHED
    });

    it("Should revert when announcing round with invalid sales window", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      const pastTime = Math.floor(Date.now() / 1000) - 1000;
      
      // Sales start in past
      await expect(
        productCatalog.connect(operator).announceRound(
          roundParams.trancheId,
          pastTime,
          roundParams.salesEndTime
        )
      ).to.be.revertedWithCustomError(productCatalog, "InvalidSalesWindow");
      
      // Sales end before start
      await expect(
        productCatalog.connect(operator).announceRound(
          roundParams.trancheId,
          roundParams.salesEndTime,
          roundParams.salesStartTime
        )
      ).to.be.revertedWithCustomError(productCatalog, "InvalidSalesWindow");
    });

    it("Should revert when trying to open round before sales start time", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      await productCatalog.connect(operator).announceRound(
        roundParams.trancheId,
        roundParams.salesStartTime,
        roundParams.salesEndTime
      );
      
      await expect(
        productCatalog.connect(operator).openRound(1)
      ).to.be.revertedWith("Sales window not started");
    });

    it("Should revert state transitions with invalid current state", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      await productCatalog.connect(operator).announceRound(
        roundParams.trancheId,
        roundParams.salesStartTime,
        roundParams.salesEndTime
      );
      
      // Try to close before opening
      await expect(
        productCatalog.connect(operator).closeRound(1)
      ).to.be.revertedWithCustomError(productCatalog, "InvalidRoundState");
    });

    it("Should update round subscription counters", async function () {
      const { productCatalog, operator, roundParams } = await createProductTrancheAndRound();
      
      await productCatalog.connect(operator).announceRound(
        roundParams.trancheId,
        roundParams.salesStartTime,
        roundParams.salesEndTime
      );
      
      const buyerNotional = ethers.parseEther("5000");
      const sellerCollateral = ethers.parseEther("10000");
      
      await expect(
        productCatalog.connect(operator).updateRoundSubscription(1, buyerNotional, sellerCollateral)
      ).to.emit(productCatalog, "RoundSubscriptionUpdated")
        .withArgs(1, buyerNotional, sellerCollateral);
      
      const round = await productCatalog.getRound(1);
      expect(round.totalBuyerNotional).to.equal(buyerNotional);
      expect(round.totalSellerCollateral).to.equal(sellerCollateral);
    });
  });

  describe("View Functions", function () {
    it("Should return empty arrays initially", async function () {
      const { productCatalog } = await loadFixture(deployProductCatalogFixture);
      
      expect(await productCatalog.getActiveProducts()).to.deep.equal([]);
      expect(await productCatalog.getActiveTranches()).to.deep.equal([]);
    });

    it("Should return correct active products and tranches", async function () {
      const { productCatalog, operator } = await loadFixture(deployProductCatalogFixture);
      
      // Create multiple products and tranches
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      await productCatalog.connect(operator).createProduct(metadataHash);
      await productCatalog.connect(operator).createProduct(metadataHash);
      
      await productCatalog.connect(operator).createTranche(
        1, 0, ethers.parseEther("2000"), getFutureTimestamp(30), 500, 0,
        ethers.parseEther("1000"), ethers.parseEther("100"), ethers.parseEther("10000"),
        ethers.parseEther("100000"), 1
      );
      
      const activeProducts = await productCatalog.getActiveProducts();
      const activeTranches = await productCatalog.getActiveTranches();
      
      expect(activeProducts.length).to.equal(2);
      expect(activeTranches.length).to.equal(1);
      expect(activeProducts).to.include(1n);
      expect(activeProducts).to.include(2n);
      expect(activeTranches).to.include(1n);
    });

    it("Should revert when getting non-existent entities", async function () {
      const { productCatalog } = await loadFixture(deployProductCatalogFixture);
      
      await expect(
        productCatalog.getProduct(999)
      ).to.be.revertedWithCustomError(productCatalog, "ProductNotFound");
      
      await expect(
        productCatalog.getTranche(999)
      ).to.be.revertedWithCustomError(productCatalog, "TrancheNotFound");
      
      await expect(
        productCatalog.getRound(999)
      ).to.be.revertedWithCustomError(productCatalog, "RoundNotFound");
    });
  });

  describe("Emergency Functions", function () {
    it("Should allow pauser to pause contract", async function () {
      const { productCatalog, pauser } = await loadFixture(deployProductCatalogFixture);
      
      await expect(productCatalog.connect(pauser).pause())
        .to.emit(productCatalog, "Paused");
      
      expect(await productCatalog.paused()).to.be.true;
    });

    it("Should allow admin to emergency cancel round", async function () {
      const { productCatalog, admin, operator } = await loadFixture(deployProductCatalogFixture);
      
      // Create product, tranche, and round
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      await productCatalog.connect(operator).createProduct(metadataHash);
      
      await productCatalog.connect(operator).createTranche(
        1, 0, ethers.parseEther("2000"), getFutureTimestamp(30), 500, 0,
        ethers.parseEther("1000"), ethers.parseEther("100"), ethers.parseEther("10000"),
        ethers.parseEther("100000"), 1
      );
      
      await productCatalog.connect(operator).announceRound(
        1,
        getFutureTimestamp(1),
        getFutureTimestamp(7)
      );
      
      await expect(productCatalog.connect(admin).emergencyCancelRound(1))
        .to.emit(productCatalog, "RoundStateChanged")
        .withArgs(1, 0, 6, await productCatalog.getRound(1).then(r => r.stateChangedAt)); // ANNOUNCED -> CANCELED
      
      const round = await productCatalog.getRound(1);
      expect(round.state).to.equal(6); // CANCELED
    });

    it("Should prevent operations when paused", async function () {
      const { productCatalog, operator, pauser } = await loadFixture(deployProductCatalogFixture);
      
      await productCatalog.connect(pauser).pause();
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      
      await expect(
        productCatalog.connect(operator).createProduct(metadataHash)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Access Control", function () {
    it("Should enforce role-based access control", async function () {
      const { productCatalog, user1, admin } = await loadFixture(deployProductCatalogFixture);
      
      const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("metadata"));
      
      // Non-operator cannot create product
      await expect(
        productCatalog.connect(user1).createProduct(metadataHash)
      ).to.be.reverted;
      
      // Non-pauser cannot pause
      await expect(
        productCatalog.connect(user1).pause()
      ).to.be.reverted;
      
      // Non-admin cannot emergency cancel
      await expect(
        productCatalog.connect(user1).emergencyCancelRound(1)
      ).to.be.reverted;
    });

    it("Should allow admin to grant and revoke roles", async function () {
      const { productCatalog, admin, user1 } = await loadFixture(deployProductCatalogFixture);
      
      // Grant operator role
      await expect(
        productCatalog.connect(admin).grantRole(await productCatalog.OPERATOR_ROLE(), user1.address)
      ).to.emit(productCatalog, "RoleGranted");
      
      expect(await productCatalog.hasRole(await productCatalog.OPERATOR_ROLE(), user1.address)).to.be.true;
      
      // Revoke operator role
      await expect(
        productCatalog.connect(admin).revokeRole(await productCatalog.OPERATOR_ROLE(), user1.address)
      ).to.emit(productCatalog, "RoleRevoked");
      
      expect(await productCatalog.hasRole(await productCatalog.OPERATOR_ROLE(), user1.address)).to.be.false;
    });
  });
});
