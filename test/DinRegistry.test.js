const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { ethers } = require("hardhat");

describe("DinRegistry", function () {
  async function deployRegistryFixture() {
    const [admin, operator, treasury, oracleOperator, pauser, user] = await ethers.getSigners();
    
    const DinRegistry = await ethers.getContractFactory("DinRegistry");
    const registry = await DinRegistry.deploy(admin.address, "1.0.0");
    await registry.waitForDeployment();

    // Grant roles
    await registry.connect(admin).grantRole(await registry.OPERATOR_ROLE(), operator.address);
    await registry.connect(admin).grantRole(await registry.TREASURY_ROLE(), treasury.address);
    await registry.connect(admin).grantRole(await registry.ORACLE_OPERATOR_ROLE(), oracleOperator.address);
    await registry.connect(admin).grantRole(await registry.PAUSER_ROLE(), pauser.address);

    return { registry, admin, operator, treasury, oracleOperator, pauser, user };
  }

  describe("Deployment", function () {
    it("Should set the correct admin", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.hasRole(await registry.ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await registry.hasRole(await registry.PAUSER_ROLE(), admin.address)).to.be.true;
    });

    it("Should set initial version", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.version()).to.equal("1.0.0");
    });

    it("Should set default parameter bounds", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.getParameterBound(await registry.MAX_PREMIUM_BPS())).to.equal(5000);
      expect(await registry.getParameterBound(await registry.PROTOCOL_FEE_BPS())).to.equal(1000);
    });

    it("Should set default parameters", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.getParameter(await registry.MAX_PREMIUM_BPS())).to.equal(1000);
      expect(await registry.getParameter(await registry.PROTOCOL_FEE_BPS())).to.equal(200);
    });

    it("Should revert if admin is zero address", async function () {
      const DinRegistry = await ethers.getContractFactory("DinRegistry");
      
      await expect(
        DinRegistry.deploy(ethers.ZeroAddress, "1.0.0")
      ).to.be.revertedWithCustomError(DinRegistry, "ZeroAddress");
    });
  });

  describe("Address Management", function () {
    it("Should allow admin to set addresses", async function () {
      const { registry, admin, user } = await loadFixture(deployRegistryFixture);
      
      const usdtIdentifier = await registry.USDT_TOKEN();
      
      await expect(registry.connect(admin).setAddress(usdtIdentifier, user.address))
        .to.emit(registry, "AddressSet")
        .withArgs(usdtIdentifier, user.address, ethers.ZeroAddress);
      
      expect(await registry.getContractAddress(usdtIdentifier)).to.equal(user.address);
      expect(await registry.getUSDTToken()).to.equal(user.address);
    });

    it("Should revert when non-admin tries to set address", async function () {
      const { registry, user } = await loadFixture(deployRegistryFixture);
      
      const usdtIdentifier = await registry.USDT_TOKEN();
      
      await expect(
        registry.connect(user).setAddress(usdtIdentifier, user.address)
      ).to.be.reverted;
    });

    it("Should revert when setting zero address", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const usdtIdentifier = await registry.USDT_TOKEN();
      
      await expect(
        registry.connect(admin).setAddress(usdtIdentifier, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("Should allow batch address setting", async function () {
      const { registry, admin, user } = await loadFixture(deployRegistryFixture);
      
      const identifiers = [
        await registry.USDT_TOKEN(),
        await registry.PRODUCT_CATALOG()
      ];
      const addresses = [user.address, admin.address];
      
      await expect(registry.connect(admin).setAddresses(identifiers, addresses))
        .to.emit(registry, "AddressSet")
        .withArgs(identifiers[0], addresses[0], ethers.ZeroAddress)
        .and.to.emit(registry, "AddressSet")
        .withArgs(identifiers[1], addresses[1], ethers.ZeroAddress);
      
      expect(await registry.getContractAddress(identifiers[0])).to.equal(user.address);
      expect(await registry.getContractAddress(identifiers[1])).to.equal(admin.address);
    });

    it("Should revert batch setting with mismatched arrays", async function () {
      const { registry, admin, user } = await loadFixture(deployRegistryFixture);
      
      const identifiers = [await registry.USDT_TOKEN()];
      const addresses = [user.address, admin.address]; // More addresses than identifiers
      
      await expect(
        registry.connect(admin).setAddresses(identifiers, addresses)
      ).to.be.revertedWith("Arrays length mismatch");
    });

    it("Should test all convenience getters", async function () {
      const { registry, admin, user } = await loadFixture(deployRegistryFixture);
      
      // Set all contract addresses
      await registry.connect(admin).setAddress(await registry.PRODUCT_CATALOG(), user.address);
      await registry.connect(admin).setAddress(await registry.ROUND_MANAGER(), user.address);
      await registry.connect(admin).setAddress(await registry.TRANCHE_POOL_FACTORY(), user.address);
      await registry.connect(admin).setAddress(await registry.PREMIUM_ENGINE(), user.address);
      await registry.connect(admin).setAddress(await registry.SETTLEMENT_ENGINE(), user.address);
      await registry.connect(admin).setAddress(await registry.ORACLE_ROUTER(), user.address);
      await registry.connect(admin).setAddress(await registry.YIELD_ROUTER(), user.address);
      await registry.connect(admin).setAddress(await registry.FEE_TREASURY(), user.address);
      
      // Test convenience getters
      expect(await registry.getProductCatalog()).to.equal(user.address);
      expect(await registry.getRoundManager()).to.equal(user.address);
      expect(await registry.getTranchePoolFactory()).to.equal(user.address);
      expect(await registry.getPremiumEngine()).to.equal(user.address);
      expect(await registry.getSettlementEngine()).to.equal(user.address);
      expect(await registry.getOracleRouter()).to.equal(user.address);
      expect(await registry.getYieldRouter()).to.equal(user.address);
      expect(await registry.getFeeTreasury()).to.equal(user.address);
    });
  });

  describe("Parameter Management", function () {
    it("Should allow admin to set parameters", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      const newValue = 2000;
      
      await expect(registry.connect(admin).setParameter(maxPremiumIdentifier, newValue))
        .to.emit(registry, "ParameterSet")
        .withArgs(maxPremiumIdentifier, newValue, 1000); // Old value was 1000
      
      expect(await registry.getParameter(maxPremiumIdentifier)).to.equal(newValue);
      expect(await registry.getMaxPremiumBps()).to.equal(newValue);
    });

    it("Should allow operator to set parameters", async function () {
      const { registry, operator } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      const newValue = 1500;
      
      await expect(registry.connect(operator).setParameter(maxPremiumIdentifier, newValue))
        .to.emit(registry, "ParameterSet")
        .withArgs(maxPremiumIdentifier, newValue, 1000);
      
      expect(await registry.getParameter(maxPremiumIdentifier)).to.equal(newValue);
    });

    it("Should revert when non-admin/operator tries to set parameter", async function () {
      const { registry, user } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      
      await expect(
        registry.connect(user).setParameter(maxPremiumIdentifier, 2000)
      ).to.be.revertedWithCustomError(registry, "UnauthorizedAccess");
    });

    it("Should revert when parameter exceeds bound", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      const exceedingValue = 6000; // Bound is 5000
      
      await expect(
        registry.connect(admin).setParameter(maxPremiumIdentifier, exceedingValue)
      ).to.be.revertedWithCustomError(registry, "ParameterExceedsBound");
    });

    it("Should allow admin to set parameter bounds", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      const newBound = 7000;
      
      await expect(registry.connect(admin).setParameterBound(maxPremiumIdentifier, newBound))
        .to.emit(registry, "ParameterBoundSet")
        .withArgs(maxPremiumIdentifier, newBound, 5000); // Old bound was 5000
      
      expect(await registry.getParameterBound(maxPremiumIdentifier)).to.equal(newBound);
    });

    it("Should revert when non-admin tries to set parameter bound", async function () {
      const { registry, operator } = await loadFixture(deployRegistryFixture);
      
      const maxPremiumIdentifier = await registry.MAX_PREMIUM_BPS();
      
      await expect(
        registry.connect(operator).setParameterBound(maxPremiumIdentifier, 7000)
      ).to.be.reverted;
    });

    it("Should test all parameter getters", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.getMaxPremiumBps()).to.equal(1000);
      expect(await registry.getMinMaturitySeconds()).to.equal(24 * 60 * 60); // 1 day
      expect(await registry.getMaxMaturitySeconds()).to.equal(90 * 24 * 60 * 60); // 90 days
      expect(await registry.getProtocolFeeBps()).to.equal(200);
    });
  });

  describe("System Status & Metadata", function () {
    it("Should allow admin to set version", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const newVersion = "2.0.0";
      
      await expect(registry.connect(admin).setVersion(newVersion))
        .to.emit(registry, "VersionSet")
        .withArgs(newVersion, "1.0.0");
      
      expect(await registry.version()).to.equal(newVersion);
    });

    it("Should allow admin to set deployment hash", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const componentName = "ProductCatalog";
      const hash = ethers.keccak256(ethers.toUtf8Bytes("deployment-hash"));
      
      await expect(registry.connect(admin).setDeploymentHash(componentName, hash))
        .to.emit(registry, "DeploymentHashSet")
        .withArgs(componentName, hash);
      
      expect(await registry.deploymentHashes(componentName)).to.equal(hash);
    });

    it("Should return correct pause status", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      expect(await registry.isSystemPaused()).to.be.false;
    });
  });

  describe("Emergency Controls", function () {
    it("Should allow pauser to pause system", async function () {
      const { registry, pauser } = await loadFixture(deployRegistryFixture);
      
      await expect(registry.connect(pauser).pause())
        .to.emit(registry, "Paused")
        .withArgs(pauser.address);
      
      expect(await registry.isSystemPaused()).to.be.true;
    });

    it("Should allow admin to pause system", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      await expect(registry.connect(admin).pause())
        .to.emit(registry, "Paused")
        .withArgs(admin.address);
      
      expect(await registry.isSystemPaused()).to.be.true;
    });

    it("Should revert when non-pauser tries to pause", async function () {
      const { registry, user } = await loadFixture(deployRegistryFixture);
      
      await expect(
        registry.connect(user).pause()
      ).to.be.reverted;
    });

    it("Should allow admin to unpause system", async function () {
      const { registry, admin, pauser } = await loadFixture(deployRegistryFixture);
      
      // First pause
      await registry.connect(pauser).pause();
      expect(await registry.isSystemPaused()).to.be.true;
      
      // Then unpause
      await expect(registry.connect(admin).unpause())
        .to.emit(registry, "Unpaused")
        .withArgs(admin.address);
      
      expect(await registry.isSystemPaused()).to.be.false;
    });

    it("Should revert when non-admin tries to unpause", async function () {
      const { registry, pauser, operator } = await loadFixture(deployRegistryFixture);
      
      // First pause
      await registry.connect(pauser).pause();
      
      // Try to unpause with non-admin
      await expect(
        registry.connect(operator).unpause()
      ).to.be.reverted;
    });

    it("Should prevent operations when paused", async function () {
      const { registry, admin, pauser, user } = await loadFixture(deployRegistryFixture);
      
      // Pause the system
      await registry.connect(pauser).pause();
      
      // Try to set address - should fail
      await expect(
        registry.connect(admin).setAddress(await registry.USDT_TOKEN(), user.address)
      ).to.be.revertedWith("Pausable: paused");
      
      // Try to set parameter - should fail
      await expect(
        registry.connect(admin).setParameter(await registry.MAX_PREMIUM_BPS(), 2000)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Role Management", function () {
    it("Should allow admin to grant roles", async function () {
      const { registry, admin, user } = await loadFixture(deployRegistryFixture);
      
      await expect(
        registry.connect(admin).grantRole(await registry.OPERATOR_ROLE(), user.address)
      ).to.emit(registry, "RoleGranted");
      
      expect(await registry.hasRole(await registry.OPERATOR_ROLE(), user.address)).to.be.true;
    });

    it("Should allow admin to revoke roles", async function () {
      const { registry, admin, operator } = await loadFixture(deployRegistryFixture);
      
      // Verify operator has role initially
      expect(await registry.hasRole(await registry.OPERATOR_ROLE(), operator.address)).to.be.true;
      
      await expect(
        registry.connect(admin).revokeRole(await registry.OPERATOR_ROLE(), operator.address)
      ).to.emit(registry, "RoleRevoked");
      
      expect(await registry.hasRole(await registry.OPERATOR_ROLE(), operator.address)).to.be.false;
    });

    it("Should have correct role hierarchy", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      // Admin should have admin role
      expect(await registry.hasRole(await registry.ADMIN_ROLE(), admin.address)).to.be.true;
      
      // Admin should also have pauser role by default
      expect(await registry.hasRole(await registry.PAUSER_ROLE(), admin.address)).to.be.true;
    });
  });

  describe("Edge Cases", function () {
    it("Should handle parameter with no bound set", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      // Create a custom parameter identifier
      const customParam = ethers.keccak256(ethers.toUtf8Bytes("CUSTOM_PARAM"));
      
      // Should be able to set any value when no bound is set
      await expect(
        registry.connect(admin).setParameter(customParam, ethers.MaxUint256)
      ).to.emit(registry, "ParameterSet");
      
      expect(await registry.getParameter(customParam)).to.equal(ethers.MaxUint256);
    });

    it("Should return zero for unset addresses", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      const customIdentifier = ethers.keccak256(ethers.toUtf8Bytes("CUSTOM_CONTRACT"));
      expect(await registry.getContractAddress(customIdentifier)).to.equal(ethers.ZeroAddress);
    });

    it("Should return zero for unset parameters", async function () {
      const { registry } = await loadFixture(deployRegistryFixture);
      
      const customParam = ethers.keccak256(ethers.toUtf8Bytes("UNSET_PARAM"));
      expect(await registry.getParameter(customParam)).to.equal(0);
    });

    it("Should handle parameter bound of zero correctly", async function () {
      const { registry, admin } = await loadFixture(deployRegistryFixture);
      
      const customParam = ethers.keccak256(ethers.toUtf8Bytes("ZERO_BOUND_PARAM"));
      
      // Set bound to zero
      await registry.connect(admin).setParameterBound(customParam, 0);
      
      // Should be able to set any value when bound is zero
      await expect(
        registry.connect(admin).setParameter(customParam, 999999)
      ).to.emit(registry, "ParameterSet");
    });
  });
});
