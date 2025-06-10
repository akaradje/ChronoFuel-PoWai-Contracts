import { ethers } from "hardhat";
import { ChronoFuel, PoWaiCore, BurnCertificateNFT, AdaptiveHalving } from "../typechain-types"; // Adjust path if necessary

async function main() {
  console.log("🚀 Deploying ChronoFuel PoWai System Contracts...");

  // --- 1. Deploy ChronoFuel Token ---
  console.log("\nDeploying ChronoFuel (CFL) token...");
  const ChronoFuelFactory = await ethers.getContractFactory("ChronoFuel");
  const chronoFuel: ChronoFuel = await ChronoFuelFactory.deploy();
  await chronoFuel.waitForDeployment();
  const chronoFuelAddress = await chronoFuel.getAddress();
  console.log(`✅ ChronoFuel (CFL) deployed to: ${chronoFuelAddress}`);

  // --- 2. Deploy BurnCertificateNFT ---
  console.log("\nDeploying BurnCertificateNFT...");
  const BurnCertificateNFTFactory = await ethers.getContractFactory("BurnCertificateNFT");
  const burnCertificateNFT: BurnCertificateNFT = await BurnCertificateNFTFactory.deploy();
  await burnCertificateNFT.waitForDeployment();
  const burnCertificateNFTAddress = await burnCertificateNFT.getAddress();
  console.log(`✅ BurnCertificateNFT deployed to: ${burnCertificateNFTAddress}`);

  // --- 3. Deploy AdaptiveHalving ---
  // Constructor requires ChronoFuel token address
  console.log("\nDeploying AdaptiveHalving...");
  const AdaptiveHalvingFactory = await ethers.getContractFactory("AdaptiveHalving");
  const adaptiveHalving: AdaptiveHalving = await AdaptiveHalvingFactory.deploy(chronoFuelAddress);
  await adaptiveHalving.waitForDeployment();
  const adaptiveHalvingAddress = await adaptiveHalving.getAddress();
  console.log(`✅ AdaptiveHalving deployed to: ${adaptiveHalvingAddress}`);

  // --- 4. Deploy PoWaiCore ---
  // Constructor requires ChronoFuel token address
  console.log("\nDeploying PoWaiCore...");
  const PoWaiCoreFactory = await ethers.getContractFactory("PoWaiCore");
  const poWaiCore: PoWaiCore = await PoWaiCoreFactory.deploy(chronoFuelAddress);
  await poWaiCore.waitForDeployment();
  const poWaiCoreAddress = await poWaiCore.getAddress();
  console.log(`✅ PoWaiCore deployed to: ${poWaiCoreAddress}`);

  console.log("\n--- Setting up Contract Linkages ---");

  // --- Link ChronoFuel to PoWaiCore ---
  console.log(`Configuring ChronoFuel (CFL) to recognize PoWaiCore...`);
  let tx = await chronoFuel.setPoWaiCoreContract(poWaiCoreAddress);
  await tx.wait();
  console.log(`   ChronoFuel.setPoWaiCoreContract(${poWaiCoreAddress}) called. Tx: ${tx.hash}`);

  // --- Link BurnCertificateNFT to PoWaiCore ---
  console.log(`Configuring BurnCertificateNFT to recognize PoWaiCore...`);
  tx = await burnCertificateNFT.setPoWaiCoreContract(poWaiCoreAddress);
  await tx.wait();
  console.log(`   BurnCertificateNFT.setPoWaiCoreContract(${poWaiCoreAddress}) called. Tx: ${tx.hash}`);

  // --- Link AdaptiveHalving to PoWaiCore ---
  console.log(`Configuring AdaptiveHalving to recognize PoWaiCore...`);
  tx = await adaptiveHalving.setPoWaiCoreContract(poWaiCoreAddress);
  await tx.wait();
  console.log(`   AdaptiveHalving.setPoWaiCoreContract(${poWaiCoreAddress}) called. Tx: ${tx.hash}`);

  // --- Link PoWaiCore to BurnCertificateNFT ---
  console.log(`Configuring PoWaiCore to recognize BurnCertificateNFT...`);
  tx = await poWaiCore.setBurnCertificateNFT(burnCertificateNFTAddress);
  await tx.wait();
  console.log(`   PoWaiCore.setBurnCertificateNFT(${burnCertificateNFTAddress}) called. Tx: ${tx.hash}`);

  // --- Link PoWaiCore to AdaptiveHalving ---
  console.log(`Configuring PoWaiCore to recognize AdaptiveHalving...`);
  tx = await poWaiCore.setAdaptiveHalving(adaptiveHalvingAddress);
  await tx.wait();
  console.log(`   PoWaiCore.setAdaptiveHalving(${adaptiveHalvingAddress}) called. Tx: ${tx.hash}`);

  console.log("\n🎉 All contracts deployed and linked successfully!");
  console.log("\nContract Addresses:");
  console.log(`ChronoFuel (CFL):       ${chronoFuelAddress}`);
  console.log(`PoWaiCore:              ${poWaiCoreAddress}`);
  console.log(`BurnCertificateNFT:     ${burnCertificateNFTAddress}`);
  console.log(`AdaptiveHalving:        ${adaptiveHalvingAddress}`);

  console.log("\n--- Important Manual Step Required ---");
  console.log("Please remember to manually update the `onlyOwnerOrPoWaiCore` modifier");
  console.log("in your `AdaptiveHalving.sol` contract with the deployed `PoWaiCore` address.");
  console.log("Replace `0x...` with:  ", poWaiCoreAddress);
  console.log("This step needs to be done directly in the contract code (and re-deployed if it's the first time),");
  console.log("or managed through a governance system later.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});