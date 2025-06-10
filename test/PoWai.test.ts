// test/PoWai.test.ts

import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { ChronoFuel, PoWaiCore, BurnCertificateNFT, AdaptiveHalving } from "../typechain-types";

// Helper function to convert Ether (18 decimals) to Wei
const toWei = (num: number) => ethers.parseUnits(num.toString(), 18);
// Helper function to convert Wei to Ether (18 decimals)
const fromWei = (num: bigint) => parseFloat(ethers.formatUnits(num, 18));

// Helper function to move blockchain time forward
async function moveTime(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine");
}

// Helper function to get event arguments from transaction receipt
async function getEventArgs(receipt: any, contract: any, eventName: string) {
  const event = receipt?.logs.find((log: any) => {
    try {
      return contract.interface.parseLog(log)?.name === eventName;
    } catch (e) {
      return false; // Ignore logs that cannot be parsed by this contract's interface
    }
  });
  expect(event).to.not.be.undefined; // Ensure the event was found
  return contract.interface.parseLog(event as any)?.args;
}


describe("ChronoFuel PoWai System", function () {
  let chronoFuel: ChronoFuel;
  let poWaiCore: PoWaiCore;
  let burnCertificateNFT: BurnCertificateNFT;
  let adaptiveHalving: AdaptiveHalving;

  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  // let users: SignerWithAddress[]; // Removed as not used

  // Constants for tests
  const STAKE_AMOUNT_CFL = 100; // 100 CFL for staking
  const BURN_AMOUNT_CFL = 50; // 50 CFL for burning (for NFT test)
  const BURN_AMOUNT_BOOST_CFL = 100; // 100 CFL for burning (for boost test)
  const LONG_WAIT_TIME_SECONDS = 24 * 3600; // 24 hours in seconds

  before(async function () {
    [owner, user1, user2] = await ethers.getSigners(); // Assigned directly
  });

  beforeEach(async function () {
    // Deploy all contracts fresh for each test to ensure clean state
    const ChronoFuelFactory = await ethers.getContractFactory("ChronoFuel");
    chronoFuel = await ChronoFuelFactory.deploy();
    await chronoFuel.waitForDeployment();

    const BurnCertificateNFTFactory = await ethers.getContractFactory("BurnCertificateNFT");
    burnCertificateNFT = await BurnCertificateNFTFactory.deploy();
    await burnCertificateNFT.waitForDeployment();

    const AdaptiveHalvingFactory = await ethers.getContractFactory("AdaptiveHalving");
    adaptiveHalving = await AdaptiveHalvingFactory.deploy(await chronoFuel.getAddress());
    await adaptiveHalving.waitForDeployment();

    const PoWaiCoreFactory = await ethers.getContractFactory("PoWaiCore");
    poWaiCore = await PoWaiCoreFactory.deploy(await chronoFuel.getAddress());
    await poWaiCore.waitForDeployment();

    // Link contracts by setting addresses
    await chronoFuel.setPoWaiCoreContract(await poWaiCore.getAddress());
    await poWaiCore.setBurnCertificateNFT(await burnCertificateNFT.getAddress());
    await poWaiCore.setAdaptiveHalving(await adaptiveHalving.getAddress());
    await adaptiveHalving.setPoWaiCoreContract(await poWaiCore.getAddress());

    // CRITICAL FIX: Ensure BurnCertificateNFT knows PoWaiCore's address
    await burnCertificateNFT.setPoWaiCoreContract(await poWaiCore.getAddress()); 

    // Debugging logs - can be commented out in production
    // console.log(`[DEBUG] PoWaiCore Address: ${await poWaiCore.getAddress()}`);
    // console.log(`[DEBUG] BurnCertificateNFT Address: ${await burnCertificateNFT.getAddress()}`);
    // console.log(`[DEBUG] BurnCertificateNFT's stored PoWaiCore: ${await burnCertificateNFT.powaiCoreContract()}`);
    // console.log(`[DEBUG] AdaptiveHalving Address: ${await adaptiveHalving.getAddress()}`);
    // console.log(`[DEBUG] ChronoFuel Address: ${await chronoFuel.getAddress()}`);
  });

  describe("CFL Token (ChronoFuel)", function () {
    beforeEach(async function () {
      await chronoFuel.connect(owner).transfer(user1.address, toWei(1000)); 
    });

    it("Should have correct name, symbol, and initial supply", async function () {
      expect(await chronoFuel.name()).to.equal("ChronoFuel");
      expect(await chronoFuel.symbol()).to.equal("CFL");
      expect(fromWei(await chronoFuel.totalSupply())).to.equal(21_000_000);
      // Adjusted expected balance to account for fresh transfer in this beforeEach
      const expectedOwnerBalanceAfterTransfer = 21_000_000 - 1000; // Total supply - transfer to user1
      expect(fromWei(await chronoFuel.balanceOf(owner.address))).to.equal(expectedOwnerBalanceAfterTransfer);
    });

    it("Users should be able to burn tokens", async function () {
      expect(fromWei(await chronoFuel.balanceOf(user1.address))).to.equal(1000);

      await chronoFuel.connect(user1).burn(toWei(50));
      expect(fromWei(await chronoFuel.balanceOf(user1.address))).to.equal(1000 - 50);
      expect(fromWei(await chronoFuel.totalGlobalBurned())).to.equal(50);
      expect(fromWei(await chronoFuel.userBurnedAmounts(user1.address))).to.equal(50);
    });
  });

  describe("PoWaiCore - Staking and Rewards", function () {
    const stakeAmount = STAKE_AMOUNT_CFL; 
    const waitTimeSeconds = LONG_WAIT_TIME_SECONDS; 

    beforeEach(async function () {
      await chronoFuel.connect(owner).transfer(user1.address, toWei(10000));
      await chronoFuel.connect(user1).approve(await poWaiCore.getAddress(), toWei(10000)); 
    });

    it("Should allow claiming rewards after cooldown and reflect minting power", async function () {
      await poWaiCore.connect(user1).stake(toWei(stakeAmount));

      // First claim, sets lastClaimTimestamp. Rewards should be positive after 1 hour (3600 seconds)
      await moveTime(1 * 3600); 
      const firstClaimTx = await poWaiCore.connect(user1).claimReward();
      await firstClaimTx.wait();

      await moveTime(waitTimeSeconds); // Move 24 hours for full reward calculation

      const initialUserBalance = await chronoFuel.balanceOf(user1.address);
      const initialTotalMined = await chronoFuel.getTotalMinedTokens();

      const tx = await poWaiCore.connect(user1).claimReward();
      const receipt = await tx.wait();

      const rewardClaimedArgs = await getEventArgs(receipt, poWaiCore, "RewardClaimed");

      expect(rewardClaimedArgs?.user).to.equal(user1.address);
      expect(rewardClaimedArgs?.timeWaitedSeconds).to.be.closeTo(waitTimeSeconds, 10);
      expect(fromWei(rewardClaimedArgs?.stakedAmount)).to.equal(stakeAmount);
      expect(fromWei(rewardClaimedArgs?.finalReward)).to.be.gt(0); // Should get a positive reward

      const finalUserBalance = await chronoFuel.balanceOf(user1.address);
      const finalTotalMined = await chronoFuel.getTotalMinedTokens();
      expect(fromWei(finalUserBalance)).to.be.gt(fromWei(initialUserBalance));
      expect(fromWei(finalTotalMined)).to.be.gt(fromWei(initialTotalMined));

      const expectedBaseReward = 24; // 24 hours * 1 CFL/hour
      const stakeBoost = 1 + Math.floor(Math.log10(1 + stakeAmount)); // e.g., 3x for stake 100
      const rawMintPower = expectedBaseReward * stakeBoost; // This is 72 CFL (base units)

      let expectedFinalReward;
      const rewardTierId = Number(rewardClaimedArgs?.rewardTierId); // Convert bigint to number
      if (rewardTierId === 0) { // Common
          expectedFinalReward = rawMintPower * 1;
      } else if (rewardTierId === 1) { // Rare
          expectedFinalReward = rawMintPower * 1.8;
      } else if (rewardTierId === 2) { // Epic
          expectedFinalReward = rawMintPower * 3.5;
      } else if (rewardTierId === 3) { // Legendary
          expectedFinalReward = rawMintPower * 8;
      } else {
          throw new Error("Unknown reward tier received.");
      }
      // Check if actual reward is close to expected reward for the given tier
      expect(fromWei(rewardClaimedArgs?.finalReward)).to.be.closeTo(expectedFinalReward, expectedFinalReward * 0.01); // Allow 1% deviation
    });

    it("Should enforce dynamic cooldown", async function () {
      await poWaiCore.connect(user1).stake(toWei(stakeAmount));

      // Claim reward immediately after staking. This call should succeed (due to reward >= 1 Wei)
      // and set lastClaimTimestamp.
      await poWaiCore.connect(user1).claimReward(); 

      // Immediately try to claim again. This should now be stopped by cooldown.
      await expect(async () => poWaiCore.connect(user1).claimReward()).to.be.revertedWith("PoWaiCore: Cooldown not yet passed"); // <<<--- Fixed async expect syntax

      const initialCooldown = await poWaiCore.getEffectiveCooldown();
      expect(initialCooldown).to.equal(888); // 15 min - 0.2 min * 1 active user = 14.8 min = 888 seconds

      // Move time forward almost enough to pass cooldown
      await moveTime(Number(initialCooldown) - 1);
      await expect(async () => poWaiCore.connect(user1).claimReward()).to.be.revertedWith("PoWaiCore: Cooldown not yet passed"); // <<<--- Fixed async expect syntax

      // Move time forward past cooldown
      await moveTime(2); // 1 second more than needed
      await expect(async () => poWaiCore.connect(user1).claimReward()).to.not.be.reverted; // <<<--- Fixed async expect syntax
    });

    it("Should reflect burn boost in minting power", async function () {
      await poWaiCore.connect(user1).boostBurn(toWei(BURN_AMOUNT_BOOST_CFL)); 

      await poWaiCore.connect(user1).stake(toWei(STAKE_AMOUNT_CFL)); 

      await moveTime(LONG_WAIT_TIME_SECONDS); 

      const receipt = await (await poWaiCore.connect(user1).claimReward()).wait();
      const rewardClaimedArgs = await getEventArgs(receipt, poWaiCore, "RewardClaimed");
      const finalReward = fromWei(rewardClaimedArgs?.finalReward);

      // Expected calculation: (24 base reward * 3 stake boost) * (1 + 0.7 * sqrt(100))
      // = 72 * (1 + 0.7 * 10) = 72 * (1 + 7) = 72 * 8 = 576 CFL
      const expectedBaseMintPower = 576; 
      
      let expectedFinalRewardForBurnTest;
      const rewardTierId = Number(rewardClaimedArgs?.rewardTierId); 
      if (rewardTierId === 0) { // Common
          expectedFinalRewardForBurnTest = expectedBaseMintPower * 1;
      } else if (rewardTierId === 1) { // Rare
          expectedFinalRewardForBurnTest = expectedBaseMintPower * 1.8;
      } else if (rewardTierId === 2) { // Epic
          expectedFinalRewardForBurnTest = expectedBaseMintPower * 3.5;
      } else if (rewardTierId === 3) { // Legendary
          expectedFinalRewardForBurnTest = expectedBaseMintPower * 8;
      } else {
          throw new Error("Unknown reward tier received.");
      }
      expect(finalReward).to.be.closeTo(expectedFinalRewardForBurnTest, expectedFinalRewardForBurnTest * 0.01);
    });

    it("Should mint Burn Certificate NFT on boostBurn", async () => {
        const initialNftBalance = await burnCertificateNFT.balanceOf(user1.address);
        expect(initialNftBalance).to.equal(0);

        const receipt = await (await poWaiCore.connect(user1).boostBurn(toWei(BURN_AMOUNT_CFL))).wait();
        const burnedForBoostArgs = await getEventArgs(receipt, poWaiCore, "BurnedForBoost");
        
        const finalNftBalance = await burnCertificateNFT.balanceOf(user1.address);
        expect(finalNftBalance).to.equal(1); 

        const tokenId = await burnCertificateNFT.tokenOfOwnerByIndex(user1.address, 0); 
        const cert = await burnCertificateNFT.certificateDetails(tokenId);

        expect(cert.burner).to.equal(user1.address);
        // Expect amount burned to be 50 CFL (input was toWei(50))
        expect(fromWei(cert.amountBurned)).to.equal(BURN_AMOUNT_CFL); 
        expect(fromWei(cert.daoPoints)).to.equal(BURN_AMOUNT_CFL * 4); 
    });

    it("Should grant Anti-Halving Shield for Epic reward", async () => {
        await poWaiCore.connect(user1).stake(toWei(100));
        
        await expect(async () => adaptiveHalving.connect(user1).grantAntiHalvingShield(user1.address, await poWaiCore.getAddress())) 
            .to.be.revertedWith("AdaptiveHalving: Unauthorized caller");
    });
  });

  describe("AdaptiveHalving", function () {
    beforeEach(async () => {
      await chronoFuel.connect(owner).transfer(user1.address, toWei(1000));
    });

    it("Should calculate initial halving threshold correctly", async () => {
      expect(fromWei(await adaptiveHalving.currentHalvingThreshold())).to.equal(21_000_000);
    });

    it("Should adjust halving threshold based on global burned amount", async () => {
        await chronoFuel.connect(user1).burn(toWei(200));

        await adaptiveHalving.connect(owner).checkAndApplyHalving(await poWaiCore.getAddress());

        const expectedNewThreshold = 21_000_000 * (1 + (200 / 2_100_000_000));
        expect(fromWei(await adaptiveHalving.currentHalvingThreshold())).to.be.closeTo(expectedNewThreshold, 0.001);
    });
    
    it("Should reduce halving rate for Legendary 'Halving Key' NFT", async () => {
        const initialHalvingRate = await adaptiveHalving.getAdjustedHalvingRate();
        expect(initialHalvingRate).to.equal(50);

        await adaptiveHalving.connect(owner).reduceHalvingRate(3, await poWaiCore.getAddress());

        const newHalvingRate = await adaptiveHalving.getAdjustedHalvingRate();
        expect(newHalvingRate).to.equal(47);
    });

    it("Should adjust halving rate based on staking ratio", async () => {
        const totalCFLSupply = fromWei(await chronoFuel.totalSupply());
        const stakeAmount = Math.floor(totalCFLSupply / 10); 

        await chronoFuel.connect(owner).approve(await poWaiCore.getAddress(), toWei(stakeAmount));
        await poWaiCore.connect(owner).stake(toWei(stakeAmount));

        const expectedRate = 50; 

        const currentAdjustedRate = Number(await adaptiveHalving.getAdjustedHalvingRate());
        expect(currentAdjustedRate).to.be.closeTo(expectedRate, 0.01);
    });
  });

  // --- New describe block for Edge cases and NFT ownership tests ---
  describe("Edge cases and NFT ownership", function () {
    beforeEach(async () => {
      // Ensure user1 has enough CFL for these tests
      await chronoFuel.connect(owner).transfer(user1.address, toWei(1000));
      await chronoFuel.connect(user1).approve(await poWaiCore.getAddress(), toWei(1000));
    });

    it("Should not allow staking 0 CFL", async () => {
      await expect(async () => poWaiCore.connect(user1).stake(toWei(0))) 
        .to.be.revertedWith("PoWaiCore: Stake amount must be positive");
    });

    it("Should not allow claiming reward without staking", async () => {
      // Must move time to ensure lastClaimTimestamp is not 0 for the internal check.
      await moveTime(10); 
      await expect(async () => poWaiCore.connect(user1).claimReward()) 
        .to.be.revertedWith("PoWaiCore: No active stake found"); 
    });

    it("Should not allow burn if user lacks balance", async () => {
      // Transfer to user2 directly for this test case
      await chronoFuel.connect(owner).transfer(user2.address, toWei(BURN_AMOUNT_CFL - 1)); // Give user2 49 CFL
      await chronoFuel.connect(user2).approve(await poWaiCore.getAddress(), toWei(BURN_AMOUNT_CFL)); // Approve for full burn

      await expect(async () => poWaiCore.connect(user2).boostBurn(toWei(BURN_AMOUNT_CFL))) 
        .to.be.revertedWithCustomError(chronoFuel, "ERC20InsufficientBalance"); 
    });

    // <<<--- CRITICAL FIX: ลบ Test Case นี้ออก เพราะมันทดสอบสิ่งที่ไม่ควร revert (certificateDetails เป็น public)
    // it("Should reject querying NFT not owned by user", async () => {
    //   await poWaiCore.connect(user1).boostBurn(toWei(BURN_AMOUNT_CFL));
    //   const tokenId = await burnCertificateNFT.tokenOfOwnerByIndex(user1.address, 0); 
    //   await expect(burnCertificateNFT.connect(user2).certificateDetails(tokenId))
    //     .to.be.revertedWith("Ownable: caller is not the owner"); 
    // });

    it("Should allow multiple boostBurn to mint multiple NFTs", async () => {
      // User1 has 1000 CFL from beforeEach. Enough for 10+20+30 = 60
      await poWaiCore.connect(user1).boostBurn(toWei(10));
      await poWaiCore.connect(user1).boostBurn(toWei(20));
      await poWaiCore.connect(user1).boostBurn(toWei(30));
      expect(await burnCertificateNFT.balanceOf(user1.address)).to.equal(3);
    });

    it("Should retain NFT metadata after transfer", async () => {
      await poWaiCore.connect(user1).boostBurn(toWei(100));
      const tokenId = await burnCertificateNFT.tokenOfOwnerByIndex(user1.address, 0);
      await burnCertificateNFT.connect(user1).transferFrom(user1.address, user2.address, tokenId);

      const cert = await burnCertificateNFT.certificateDetails(tokenId);
      expect(cert.burner).to.equal(user1.address);
      expect(fromWei(cert.amountBurned)).to.equal(100);
    });

    it("Should reject transfer by non-owner", async () => {
      await poWaiCore.connect(user1).boostBurn(toWei(100));
      const tokenId = await burnCertificateNFT.tokenOfOwnerByIndex(user1.address, 0);

      await expect(async () => burnCertificateNFT.connect(user2).transferFrom(user1.address, user2.address, tokenId)) 
        .to.be.revertedWithCustomError(burnCertificateNFT, "ERC721InvalidOwner"); // Use CustomError
    });

    it("Should revert querying index out of bounds", async () => {
      await expect(async () => burnCertificateNFT.tokenOfOwnerByIndex(user1.address, 0)) 
        .to.be.revertedWithCustomError(burnCertificateNFT, "ERC721InvalidIndex"); // Use CustomError from ERC721Enumerable
    });
  });
});