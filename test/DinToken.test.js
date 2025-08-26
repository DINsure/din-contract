const { expect } = require("chai");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { ethers } = require("hardhat");

describe("DinToken", function () {
  async function deployTokenFixture() {
    const [admin, minter, pauser, burner, user1, user2] = await ethers.getSigners();
    
    const DinToken = await ethers.getContractFactory("DinToken");
    const initialSupply = 100_000_000; // 100 million tokens
    const dinToken = await DinToken.deploy(admin.address, initialSupply);
    await dinToken.waitForDeployment();

    // Grant roles
    await dinToken.connect(admin).grantRole(await dinToken.MINTER_ROLE(), minter.address);
    await dinToken.connect(admin).grantRole(await dinToken.PAUSER_ROLE(), pauser.address);
    await dinToken.connect(admin).grantRole(await dinToken.BURNER_ROLE(), burner.address);

    return { dinToken, admin, minter, pauser, burner, user1, user2, initialSupply };
  }

  describe("Deployment", function () {
    it("Should set the correct token details", async function () {
      const { dinToken } = await loadFixture(deployTokenFixture);
      
      expect(await dinToken.name()).to.equal("DIN Token");
      expect(await dinToken.symbol()).to.equal("DIN");
      expect(await dinToken.decimals()).to.equal(18);
    });

    it("Should set the correct max supply", async function () {
      const { dinToken } = await loadFixture(deployTokenFixture);
      
      const maxSupply = await dinToken.MAX_SUPPLY();
      expect(maxSupply).to.equal(ethers.parseEther("1000000000")); // 1 billion
    });

    it("Should mint initial supply to admin", async function () {
      const { dinToken, admin, initialSupply } = await loadFixture(deployTokenFixture);
      
      const adminBalance = await dinToken.balanceOf(admin.address);
      const expectedBalance = ethers.parseEther(initialSupply.toString());
      expect(adminBalance).to.equal(expectedBalance);
    });

    it("Should grant all roles to admin", async function () {
      const { dinToken, admin } = await loadFixture(deployTokenFixture);
      
      expect(await dinToken.hasRole(await dinToken.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await dinToken.hasRole(await dinToken.MINTER_ROLE(), admin.address)).to.be.true;
      expect(await dinToken.hasRole(await dinToken.PAUSER_ROLE(), admin.address)).to.be.true;
      expect(await dinToken.hasRole(await dinToken.BURNER_ROLE(), admin.address)).to.be.true;
    });

    it("Should revert if admin is zero address", async function () {
      const DinToken = await ethers.getContractFactory("DinToken");
      
      await expect(
        DinToken.deploy(ethers.ZeroAddress, 100_000_000)
      ).to.be.revertedWithCustomError(DinToken, "ZeroAddress");
    });

    it("Should revert if initial supply exceeds max supply", async function () {
      const { admin } = await loadFixture(deployTokenFixture);
      const DinToken = await ethers.getContractFactory("DinToken");
      
      await expect(
        DinToken.deploy(admin.address, 2_000_000_000) // 2 billion > 1 billion max
      ).to.be.revertedWithCustomError(DinToken, "ExceedsMaxSupply");
    });
  });

  describe("Minting", function () {
    it("Should allow minter to mint tokens", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      const mintAmount = ethers.parseEther("1000");
      
      await expect(dinToken.connect(minter).mint(user1.address, mintAmount))
        .to.emit(dinToken, "TokensMinted")
        .withArgs(user1.address, mintAmount, minter.address);
      
      expect(await dinToken.balanceOf(user1.address)).to.equal(mintAmount);
    });

    it("Should revert when non-minter tries to mint", async function () {
      const { dinToken, user1, user2 } = await loadFixture(deployTokenFixture);
      
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        dinToken.connect(user1).mint(user2.address, mintAmount)
      ).to.be.reverted;
    });

    it("Should revert when minting to zero address", async function () {
      const { dinToken, minter } = await loadFixture(deployTokenFixture);
      
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        dinToken.connect(minter).mint(ethers.ZeroAddress, mintAmount)
      ).to.be.revertedWithCustomError(dinToken, "ZeroAddress");
    });

    it("Should revert when minting zero amount", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(minter).mint(user1.address, 0)
      ).to.be.revertedWithCustomError(dinToken, "ZeroAmount");
    });

    it("Should revert when minting exceeds max supply", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      const remainingSupply = await dinToken.remainingMintableSupply();
      const excessAmount = remainingSupply + ethers.parseEther("1");
      
      await expect(
        dinToken.connect(minter).mint(user1.address, excessAmount)
      ).to.be.revertedWithCustomError(dinToken, "ExceedsMaxSupply");
    });

    it("Should emit MaxSupplyReached when reaching max supply", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      const remainingSupply = await dinToken.remainingMintableSupply();
      
      await expect(dinToken.connect(minter).mint(user1.address, remainingSupply))
        .to.emit(dinToken, "MaxSupplyReached")
        .withArgs(await dinToken.MAX_SUPPLY());
      
      expect(await dinToken.isMaxSupplyReached()).to.be.true;
    });
  });

  describe("Burning", function () {
    it("Should allow users to burn their own tokens", async function () {
      const { dinToken, admin, user1 } = await loadFixture(deployTokenFixture);
      
      // Transfer some tokens to user1
      const transferAmount = ethers.parseEther("1000");
      await dinToken.connect(admin).transfer(user1.address, transferAmount);
      
      const burnAmount = ethers.parseEther("500");
      
      await expect(dinToken.connect(user1).burn(burnAmount))
        .to.emit(dinToken, "TokensBurned")
        .withArgs(user1.address, burnAmount, user1.address);
      
      expect(await dinToken.balanceOf(user1.address)).to.equal(transferAmount - burnAmount);
    });

    it("Should allow burner to burn from any address", async function () {
      const { dinToken, admin, burner, user1 } = await loadFixture(deployTokenFixture);
      
      // Transfer some tokens to user1
      const transferAmount = ethers.parseEther("1000");
      await dinToken.connect(admin).transfer(user1.address, transferAmount);
      
      // User1 approves burner to burn tokens
      const burnAmount = ethers.parseEther("500");
      await dinToken.connect(user1).approve(burner.address, burnAmount);
      
      await expect(dinToken.connect(burner).burnFrom(user1.address, burnAmount))
        .to.emit(dinToken, "TokensBurned")
        .withArgs(user1.address, burnAmount, burner.address);
      
      expect(await dinToken.balanceOf(user1.address)).to.equal(transferAmount - burnAmount);
    });

    it("Should revert when burning zero amount", async function () {
      const { dinToken, user1 } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(user1).burn(0)
      ).to.be.revertedWithCustomError(dinToken, "ZeroAmount");
    });

    it("Should revert when burning from zero address", async function () {
      const { dinToken, burner } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(burner).burnFrom(ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(dinToken, "ZeroAddress");
    });

    it("Should revert when non-burner tries to burnFrom", async function () {
      const { dinToken, user1, user2 } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(user1).burnFrom(user2.address, ethers.parseEther("100"))
      ).to.be.reverted;
    });
  });

  describe("Pausing", function () {
    it("Should allow pauser to pause contract", async function () {
      const { dinToken, pauser } = await loadFixture(deployTokenFixture);
      
      await expect(dinToken.connect(pauser).pause())
        .to.emit(dinToken, "Paused")
        .withArgs(pauser.address);
      
      expect(await dinToken.paused()).to.be.true;
    });

    it("Should allow admin to unpause contract", async function () {
      const { dinToken, admin, pauser } = await loadFixture(deployTokenFixture);
      
      // First pause
      await dinToken.connect(pauser).pause();
      
      // Then unpause
      await expect(dinToken.connect(admin).unpause())
        .to.emit(dinToken, "Unpaused")
        .withArgs(admin.address);
      
      expect(await dinToken.paused()).to.be.false;
    });

    it("Should prevent transfers when paused", async function () {
      const { dinToken, admin, pauser, user1 } = await loadFixture(deployTokenFixture);
      
      await dinToken.connect(pauser).pause();
      
      await expect(
        dinToken.connect(admin).transfer(user1.address, ethers.parseEther("100"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should prevent minting when paused", async function () {
      const { dinToken, minter, pauser, user1 } = await loadFixture(deployTokenFixture);
      
      await dinToken.connect(pauser).pause();
      
      await expect(
        dinToken.connect(minter).mint(user1.address, ethers.parseEther("100"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should prevent burning when paused", async function () {
      const { dinToken, admin, pauser } = await loadFixture(deployTokenFixture);
      
      await dinToken.connect(pauser).pause();
      
      await expect(
        dinToken.connect(admin).burn(ethers.parseEther("100"))
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Role Management", function () {
    it("Should allow admin to grant roles", async function () {
      const { dinToken, admin, user1 } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(admin).grantRole(await dinToken.MINTER_ROLE(), user1.address)
      ).to.emit(dinToken, "RoleGranted");
      
      expect(await dinToken.hasRole(await dinToken.MINTER_ROLE(), user1.address)).to.be.true;
    });

    it("Should allow admin to revoke roles", async function () {
      const { dinToken, admin, minter } = await loadFixture(deployTokenFixture);
      
      await expect(
        dinToken.connect(admin).revokeRole(await dinToken.MINTER_ROLE(), minter.address)
      ).to.emit(dinToken, "RoleRevoked");
      
      expect(await dinToken.hasRole(await dinToken.MINTER_ROLE(), minter.address)).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should return correct remaining mintable supply", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      const initialRemaining = await dinToken.remainingMintableSupply();
      const mintAmount = ethers.parseEther("1000");
      
      await dinToken.connect(minter).mint(user1.address, mintAmount);
      
      const newRemaining = await dinToken.remainingMintableSupply();
      expect(newRemaining).to.equal(initialRemaining - mintAmount);
    });

    it("Should return correct max supply reached status", async function () {
      const { dinToken, minter, user1 } = await loadFixture(deployTokenFixture);
      
      expect(await dinToken.isMaxSupplyReached()).to.be.false;
      
      // Mint remaining supply
      const remainingSupply = await dinToken.remainingMintableSupply();
      await dinToken.connect(minter).mint(user1.address, remainingSupply);
      
      expect(await dinToken.isMaxSupplyReached()).to.be.true;
    });
  });

  describe("Standard ERC20 Functionality", function () {
    it("Should transfer tokens between accounts", async function () {
      const { dinToken, admin, user1 } = await loadFixture(deployTokenFixture);
      
      const transferAmount = ethers.parseEther("1000");
      
      await expect(dinToken.connect(admin).transfer(user1.address, transferAmount))
        .to.emit(dinToken, "Transfer")
        .withArgs(admin.address, user1.address, transferAmount);
      
      expect(await dinToken.balanceOf(user1.address)).to.equal(transferAmount);
    });

    it("Should handle approve and transferFrom", async function () {
      const { dinToken, admin, user1, user2 } = await loadFixture(deployTokenFixture);
      
      const transferAmount = ethers.parseEther("1000");
      
      // Admin approves user1 to spend tokens
      await dinToken.connect(admin).approve(user1.address, transferAmount);
      expect(await dinToken.allowance(admin.address, user1.address)).to.equal(transferAmount);
      
      // User1 transfers from admin to user2
      await expect(dinToken.connect(user1).transferFrom(admin.address, user2.address, transferAmount))
        .to.emit(dinToken, "Transfer")
        .withArgs(admin.address, user2.address, transferAmount);
      
      expect(await dinToken.balanceOf(user2.address)).to.equal(transferAmount);
    });
  });
});
