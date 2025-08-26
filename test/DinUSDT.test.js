const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { ethers } = require("hardhat");

describe("DinUSDT", function () {
  async function deployUSDTFixture() {
    const [owner, user1, user2, user3] = await ethers.getSigners();
    
    const DinUSDT = await ethers.getContractFactory("DinUSDT");
    const initialSupply = ethers.parseUnits("1000000", 6); // 1M USDT (6 decimals)
    const name = "DIN USD Tether";
    const symbol = "USDT";
    const decimals = 6;
    
    const dinUsdt = await DinUSDT.deploy(initialSupply, name, symbol, decimals);
    await dinUsdt.waitForDeployment();

    return { dinUsdt, owner, user1, user2, user3, initialSupply, name, symbol, decimals };
  }

  describe("Deployment", function () {
    it("Should set the correct token details", async function () {
      const { dinUsdt, name, symbol, decimals } = await loadFixture(deployUSDTFixture);
      
      expect(await dinUsdt.name()).to.equal(name);
      expect(await dinUsdt.symbol()).to.equal(symbol);
      expect(await dinUsdt.decimals()).to.equal(decimals);
    });

    it("Should mint initial supply to owner", async function () {
      const { dinUsdt, owner, initialSupply } = await loadFixture(deployUSDTFixture);
      
      expect(await dinUsdt.totalSupply()).to.equal(initialSupply);
      expect(await dinUsdt.balanceOf(owner.address)).to.equal(initialSupply);
    });

    it("Should not be deprecated initially", async function () {
      const { dinUsdt } = await loadFixture(deployUSDTFixture);
      
      expect(await dinUsdt.isDeprecated()).to.be.false;
      expect(await dinUsdt.deprecated()).to.be.false;
    });

    it("Should not be paused initially", async function () {
      const { dinUsdt } = await loadFixture(deployUSDTFixture);
      
      expect(await dinUsdt.paused()).to.be.false;
    });

    it("Should have zero fees initially", async function () {
      const { dinUsdt } = await loadFixture(deployUSDTFixture);
      
      expect(await dinUsdt.basisPointsRate()).to.equal(0);
      expect(await dinUsdt.maximumFee()).to.equal(0);
    });
  });

  describe("Basic ERC20 Functionality", function () {
    it("Should transfer tokens between accounts", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      const transferAmount = ethers.parseUnits("1000", 6);
      
      // Note: transfer() doesn't return boolean like real USDT
      await expect(dinUsdt.connect(owner).transfer(user1.address, transferAmount))
        .to.emit(dinUsdt, "Transfer")
        .withArgs(owner.address, user1.address, transferAmount);
      
      expect(await dinUsdt.balanceOf(user1.address)).to.equal(transferAmount);
    });

    it("Should handle approve and transferFrom", async function () {
      const { dinUsdt, owner, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      // Owner approves user1
      await expect(dinUsdt.connect(owner).approve(user1.address, amount))
        .to.emit(dinUsdt, "Approval")
        .withArgs(owner.address, user1.address, amount);
      
      expect(await dinUsdt.allowance(owner.address, user1.address)).to.equal(amount);
      
      // User1 transfers from owner to user2 (Note: transferFrom doesn't return boolean like real USDT)
      await expect(dinUsdt.connect(user1).transferFrom(owner.address, user2.address, amount))
        .to.emit(dinUsdt, "Transfer")
        .withArgs(owner.address, user2.address, amount);
      
      expect(await dinUsdt.balanceOf(user2.address)).to.equal(amount);
    });

    it("Should revert transfer with insufficient balance", async function () {
      const { dinUsdt, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      await expect(
        dinUsdt.connect(user1).transfer(user2.address, amount)
      ).to.be.revertedWithCustomError(dinUsdt, "InsufficientBalance");
    });

    it("Should revert transferFrom with insufficient allowance", async function () {
      const { dinUsdt, owner, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      await expect(
        dinUsdt.connect(user1).transferFrom(owner.address, user2.address, amount)
      ).to.be.revertedWithCustomError(dinUsdt, "InsufficientAllowance");
    });

    it("Should prevent approve from non-zero to non-zero", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      // First approval
      await dinUsdt.connect(owner).approve(user1.address, amount);
      
      // Second approval should fail
      await expect(
        dinUsdt.connect(owner).approve(user1.address, amount)
      ).to.be.revertedWith("Approve from non-zero to non-zero");
    });
  });

  describe("Fee Mechanism", function () {
    it("Should transfer with fees when fee is set", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      // Set 1% fee (100 basis points), max fee 10 USDT
      await dinUsdt.connect(owner).setParams(100, 10);
      
      const transferAmount = ethers.parseUnits("1000", 6);
      const expectedFee = transferAmount * 100n / 10000n; // 1% fee
      const expectedReceived = transferAmount - expectedFee;
      
      const ownerBalanceBefore = await dinUsdt.balanceOf(owner.address);
      
      await dinUsdt.connect(owner).transfer(user1.address, transferAmount);
      
      expect(await dinUsdt.balanceOf(user1.address)).to.equal(expectedReceived);
      expect(await dinUsdt.balanceOf(owner.address)).to.equal(ownerBalanceBefore - transferAmount + expectedFee);
    });

    it("Should cap fee at maximum fee", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      // Set 1% fee but cap at 10 USDT  
      await dinUsdt.connect(owner).setParams(100, 10); // 1% fee, 10 USDT max
      
      const transferAmount = ethers.parseUnits("1000", 6); // 1000 USDT
      const expectedFee = ethers.parseUnits("10", 6); // Should be capped at 10 USDT
      const expectedReceived = transferAmount - expectedFee;
      
      const ownerBalanceBefore = await dinUsdt.balanceOf(owner.address);
      
      await dinUsdt.connect(owner).transfer(user1.address, transferAmount);
      
      expect(await dinUsdt.balanceOf(user1.address)).to.equal(expectedReceived);
      expect(await dinUsdt.balanceOf(owner.address)).to.equal(ownerBalanceBefore - transferAmount + expectedFee);
    });

    it("Should emit Params event when setting fee parameters", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      const basisPoints = 50; // 0.5%
      const maxFee = 10; // 10 USDT
      const maxFeeWei = ethers.parseUnits(maxFee.toString(), 6);
      
      await expect(dinUsdt.connect(owner).setParams(basisPoints, maxFee))
        .to.emit(dinUsdt, "Params")
        .withArgs(basisPoints, maxFeeWei);
    });

    it("Should revert if fee is too high", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(owner).setParams(2000, 100) // 20% fee
      ).to.be.revertedWith("Fee too high");
    });

    it("Should revert if max fee is too high", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(owner).setParams(100, 100) // 100 USDT max fee
      ).to.be.revertedWith("Max fee too high");
    });
  });

  describe("Issue and Redeem (Mint/Burn)", function () {
    it("Should allow owner to issue new tokens", async function () {
      const { dinUsdt, owner, initialSupply } = await loadFixture(deployUSDTFixture);
      
      const issueAmount = ethers.parseUnits("100000", 6); // 100k USDT
      
      await expect(dinUsdt.connect(owner).issue(issueAmount))
        .to.emit(dinUsdt, "Issue")
        .withArgs(issueAmount)
        .and.to.emit(dinUsdt, "Transfer")
        .withArgs(ethers.ZeroAddress, owner.address, issueAmount);
      
      expect(await dinUsdt.totalSupply()).to.equal(initialSupply + issueAmount);
      expect(await dinUsdt.balanceOf(owner.address)).to.equal(initialSupply + issueAmount);
    });

    it("Should allow owner to redeem tokens", async function () {
      const { dinUsdt, owner, initialSupply } = await loadFixture(deployUSDTFixture);
      
      const redeemAmount = ethers.parseUnits("100000", 6); // 100k USDT
      
      await expect(dinUsdt.connect(owner).redeem(redeemAmount))
        .to.emit(dinUsdt, "Redeem")
        .withArgs(redeemAmount)
        .and.to.emit(dinUsdt, "Transfer")
        .withArgs(owner.address, ethers.ZeroAddress, redeemAmount);
      
      expect(await dinUsdt.totalSupply()).to.equal(initialSupply - redeemAmount);
      expect(await dinUsdt.balanceOf(owner.address)).to.equal(initialSupply - redeemAmount);
    });

    it("Should revert redeem with insufficient balance", async function () {
      const { dinUsdt, owner, initialSupply } = await loadFixture(deployUSDTFixture);
      
      const redeemAmount = initialSupply + ethers.parseUnits("1", 6);
      
      await expect(
        dinUsdt.connect(owner).redeem(redeemAmount)
      ).to.be.revertedWith("Insufficient total supply");
    });

    it("Should revert when non-owner tries to issue", async function () {
      const { dinUsdt, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(user1).issue(ethers.parseUnits("1000", 6))
      ).to.be.reverted;
    });

    it("Should revert when non-owner tries to redeem", async function () {
      const { dinUsdt, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(user1).redeem(ethers.parseUnits("1000", 6))
      ).to.be.reverted;
    });
  });

  describe("Blacklist Functionality", function () {
    it("Should allow owner to blacklist address", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(dinUsdt.connect(owner).addBlackList(user1.address))
        .to.emit(dinUsdt, "AddedBlackList")
        .withArgs(user1.address);
      
      expect(await dinUsdt.isBlackListed(user1.address)).to.be.true;
      expect(await dinUsdt.getBlackListStatus(user1.address)).to.be.true;
    });

    it("Should allow owner to remove from blacklist", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      // First blacklist
      await dinUsdt.connect(owner).addBlackList(user1.address);
      
      // Then remove
      await expect(dinUsdt.connect(owner).removeBlackList(user1.address))
        .to.emit(dinUsdt, "RemovedBlackList")
        .withArgs(user1.address);
      
      expect(await dinUsdt.isBlackListed(user1.address)).to.be.false;
    });

    it("Should prevent blacklisted address from transferring", async function () {
      const { dinUsdt, owner, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      // Transfer some tokens to user1
      await dinUsdt.connect(owner).transfer(user1.address, ethers.parseUnits("1000", 6));
      
      // Blacklist user1
      await dinUsdt.connect(owner).addBlackList(user1.address);
      
      // User1 should not be able to transfer
      await expect(
        dinUsdt.connect(user1).transfer(user2.address, ethers.parseUnits("100", 6))
      ).to.be.revertedWithCustomError(dinUsdt, "BlacklistedAddress");
    });

    it("Should prevent transfers to blacklisted address", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      // Blacklist user1
      await dinUsdt.connect(owner).addBlackList(user1.address);
      
      // Owner should not be able to transfer to user1
      await expect(
        dinUsdt.connect(owner).transfer(user1.address, ethers.parseUnits("100", 6))
      ).to.be.revertedWithCustomError(dinUsdt, "BlacklistedAddress");
    });

    it("Should allow owner to destroy blacklisted funds", async function () {
      const { dinUsdt, owner, user1, initialSupply } = await loadFixture(deployUSDTFixture);
      
      const transferAmount = ethers.parseUnits("1000", 6);
      
      // Transfer tokens to user1
      await dinUsdt.connect(owner).transfer(user1.address, transferAmount);
      
      // Blacklist user1
      await dinUsdt.connect(owner).addBlackList(user1.address);
      
      // Destroy blacklisted funds
      await expect(dinUsdt.connect(owner).destroyBlackFunds(user1.address))
        .to.emit(dinUsdt, "DestroyedBlackFunds")
        .withArgs(user1.address, transferAmount);
      
      expect(await dinUsdt.balanceOf(user1.address)).to.equal(0);
      expect(await dinUsdt.totalSupply()).to.equal(initialSupply - transferAmount);
    });

    it("Should revert destroying funds of non-blacklisted address", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(owner).destroyBlackFunds(user1.address)
      ).to.be.revertedWith("Address not blacklisted");
    });
  });

  describe("Pause Functionality", function () {
    it("Should allow owner to pause contract", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      await expect(dinUsdt.connect(owner).pause())
        .to.emit(dinUsdt, "Paused")
        .withArgs(owner.address);
      
      expect(await dinUsdt.paused()).to.be.true;
    });

    it("Should allow owner to unpause contract", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      // First pause
      await dinUsdt.connect(owner).pause();
      
      // Then unpause
      await expect(dinUsdt.connect(owner).unpause())
        .to.emit(dinUsdt, "Unpaused")
        .withArgs(owner.address);
      
      expect(await dinUsdt.paused()).to.be.false;
    });

    it("Should prevent transfers when paused", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      await dinUsdt.connect(owner).pause();
      
      await expect(
        dinUsdt.connect(owner).transfer(user1.address, ethers.parseUnits("100", 6))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should revert when non-owner tries to pause", async function () {
      const { dinUsdt, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(user1).pause()
      ).to.be.reverted;
    });
  });

  describe("Deprecation Functionality", function () {
    it("Should allow owner to deprecate contract", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(dinUsdt.connect(owner).deprecate(user1.address))
        .to.emit(dinUsdt, "Deprecate")
        .withArgs(user1.address);
      
      expect(await dinUsdt.isDeprecated()).to.be.true;
      expect(await dinUsdt.deprecated()).to.be.true;
      expect(await dinUsdt.getUpgradedAddress()).to.equal(user1.address);
      expect(await dinUsdt.upgradedAddress()).to.equal(user1.address);
    });

    it("Should revert deprecate with zero address", async function () {
      const { dinUsdt, owner } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(owner).deprecate(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(dinUsdt, "ZeroAddress");
    });

    it("Should revert when non-owner tries to deprecate", async function () {
      const { dinUsdt, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      await expect(
        dinUsdt.connect(user1).deprecate(user2.address)
      ).to.be.reverted;
    });
  });

  describe("Edge Cases", function () {
    it("Should handle MAX_UINT allowance correctly", async function () {
      const { dinUsdt, owner, user1, user2 } = await loadFixture(deployUSDTFixture);
      
      // Set MAX_UINT allowance
      await dinUsdt.connect(owner).approve(user1.address, await dinUsdt.MAX_UINT());
      
      const transferAmount = ethers.parseUnits("1000", 6);
      
      // Transfer should not reduce allowance when it's MAX_UINT
      await dinUsdt.connect(user1).transferFrom(owner.address, user2.address, transferAmount);
      
      expect(await dinUsdt.allowance(owner.address, user1.address)).to.equal(await dinUsdt.MAX_UINT());
    });

    it("Should handle zero transfer amount", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      await expect(dinUsdt.connect(owner).transfer(user1.address, 0))
        .to.emit(dinUsdt, "Transfer")
        .withArgs(owner.address, user1.address, 0);
    });

    it("Should handle approval reset (zero to non-zero)", async function () {
      const { dinUsdt, owner, user1 } = await loadFixture(deployUSDTFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      // Set allowance
      await dinUsdt.connect(owner).approve(user1.address, amount);
      
      // Reset to zero
      await dinUsdt.connect(owner).approve(user1.address, 0);
      
      // Set new allowance
      await dinUsdt.connect(owner).approve(user1.address, amount);
      
      expect(await dinUsdt.allowance(owner.address, user1.address)).to.equal(amount);
    });
  });
});
