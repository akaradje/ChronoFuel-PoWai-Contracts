// hardhat.config.ts

import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox"; // ควรใช้ @nomicfoundation/hardhat-ethers แทน @nomicfoundation/hardhat-toolbox หรือตรวจสอบว่า toolbox รวม ethers แล้ว

import * as dotenv from "dotenv";
dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20", // ต้องตรงกับ pragma ในสัญญาของคุณ
    settings: {
      metadata: {
        bytecodeHash: "none",
        useLiteralContent: true,
      },
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  
  defaultNetwork: "hardhat", // ควรตั้งค่า defaultNetwork เป็น "hardhat" สำหรับการรัน test

  networks: {
    hardhat: {
      chainId: 31337, // Default Hardhat Network Chain ID
      accounts: {
        // <<--- แก้ไขตรงนี้: ใช้ accountsBalance แทน balance
        mnemonic: "test test test test test test test test test test test test", // Hardhat Network ใช้ mnemonic นี้โดย default
        accountsBalance: "1000000000000000000000000", // 1 million ETH ในหน่วย Wei
      },
    },
    monadTestnet: {
      url: process.env.MONAD_RPC_URL || "https://testnet-rpc.monad.xyz",
      chainId: 10143,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },

  sourcify: {
    enabled: true,
    apiUrl: "https://sourcify-api-monad.blockvision.org",
    browserUrl: "https://testnet.monadexplorer.com",
  },
  etherscan: {
    enabled: false, 
  },
  
  paths: {
    sources: "contracts",
    tests: "test",
    cache: "cache",
    artifacts: "artifacts"
  },
};

export default config;