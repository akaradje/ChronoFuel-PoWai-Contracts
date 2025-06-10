// contracts/PoWaiCore.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "hardhat/console.sol"; // <<<--- เพิ่มบรรทัดนี้สำหรับ console.log ในสัญญา

// Interface for the ChronoFuel token to access its specific functions
interface IChronoFuel is IERC20 {
    function _mintTokens(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function getUserBurnedAmount(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IBurnCertificateNFT {
    function mintBurnCertificate(address to, uint256 amountBurned, uint256 mintPowerBeforeBurn, uint256 daoPoints, uint256 airdropRights) external returns (uint256 tokenId);
}

interface IAdaptiveHalving {
    function grantAntiHalvingShield(address user, address powaiCoreAddress) external;
    function reduceHalvingRate(uint256 percentageReduction, address powaiCoreAddress) external;
    function consumeAntiHalvingShield(address user, address powaiCoreAddress) external;
}

/**
 * @title PoWaiCore
 * @dev The core contract for the ChronoFuel Proof-of-Wait (PoWai) system.
 * Manages user waiting, staking, burning effects, and reward distribution.
 */
contract PoWaiCore is Ownable, ReentrancyGuard {
    // --- External Contract Instances ---
    IChronoFuel public chronoFuelToken;
    IBurnCertificateNFT public burnCertificateNFT;
    IAdaptiveHalving public adaptiveHalving;

    // --- Constants ---
    uint256 public constant AHBM_DECIMALS = 10**18;
    uint256 public constant PRECISION_FACTOR = 10**10; // 10^10 สำหรับคำนวณส่วนที่มีทศนิยม 10 หลัก

    uint256 public constant BASE_TIME_REWARD_PER_HOUR_AHBM = 1 * AHBM_DECIMALS; // 1 CFL/ชม. (scaled)
    uint256 public constant MAX_WAIT_HOURS = 24;

    uint256 public constant MIN_COOLDOWN_SECONDS = 1 minutes;
    uint256 public constant MAX_COOLDOWN_SECONDS = 15 minutes;
    uint256 public constant COOLDOWN_DECREASE_PER_ACTIVE_USER_SECONDS = 12;

    uint256 public constant BURN_FACTOR_NUMERATOR = 7; // Represents 0.7
    uint256 public constant BURN_FACTOR_DENOMINATOR = 10; // Represents 0.7

    uint256 public constant COMMON_PROB = 70;
    uint256 public constant RARE_PROB = 22;
    uint256 public constant EPIC_PROB = 7;
    uint256 public constant LEGENDARY_PROB = 1;

    // Multipliers จะเป็นค่า raw ที่คูณด้วย 10 เพื่อจัดการทศนิยม 1 ตำแหน่ง
    uint256 public constant COMMON_MULTIPLIER_SCALED = 10;   // 1.0x (scaled by 10)
    uint256 public constant RARE_MULTIPLIER_SCALED = 18;    // 1.8x (scaled by 10)
    uint256 public constant EPIC_MULTIPLIER_SCALED = 35;    // 3.5x (scaled by 10)
    uint256 public constant LEGENDARY_MULTIPLIER_SCALED = 80; // 8.0x (scaled by 10)


    // --- User State ---
    struct UserData {
        uint256 lastClaimTimestamp;
        uint256 stakedAmount;
    }
    mapping(address => UserData) public userData;
    uint256 public totalStakedAmount; // Global sum of all staked amounts

    // --- Dynamic Cooldown Tracking ---
    mapping(address => uint256) public userLastActivityTime;
    address[] private activeUsersList;
    mapping(address => uint256) private activeUsersIndex;
    uint256 public activeUsersCount;
    uint256 public constant ACTIVITY_WINDOW = 24 hours;

    // For randomness nonce (per user, increments with each claim)
    mapping(address => uint256) private _nonce;

    // --- Events ---
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event BurnedForBoost(address indexed burner, uint256 amountBurned, uint256 newBurnCertificateNFTId);
    event RewardClaimed(address indexed user, uint256 timeWaitedSeconds, uint256 stakedAmount, uint256 baseMintPower, uint256 finalReward, uint256 rewardTierId, uint256 cooldownUsed);
    event ChronoFuelTokenSet(address indexed tokenAddress);
    event BurnCertificateNFTSet(address indexed nftAddress);
    event AdaptiveHalvingSet(address indexed halvingAddress);

    /**
     * @dev Constructor. Sets the initial ChronoFuel token address.
     * @param _chronoFuelTokenAddress The address of the ChronoFuel (CFL) token contract.
     */
    constructor(address _chronoFuelTokenAddress) Ownable(msg.sender) {
        console.log("Contract Deploy: PoWaiCore constructor"); // DEBUG
        console.logAddress(_chronoFuelTokenAddress); // DEBUG
        require(_chronoFuelTokenAddress != address(0), "PoWaiCore: ChronoFuel token address cannot be zero");
        chronoFuelToken = IChronoFuel(_chronoFuelTokenAddress);
        emit ChronoFuelTokenSet(_chronoFuelTokenAddress);
    }

    /**
     * @dev Sets the address of the ChronoFuel token contract.
     * Can only be called once by the owner and if not already set.
     * @param _tokenAddress The address of the ChronoFuel token contract.
     */
    function setChronoFuelToken(address _tokenAddress) public onlyOwner {
        console.log("setChronoFuelToken:"); // DEBUG
        console.logAddress(_tokenAddress); // DEBUG
        require(_tokenAddress != address(0), "PoWaiCore: Zero address not allowed");
        require(address(chronoFuelToken) == address(0) || address(chronoFuelToken) == _tokenAddress, "PoWaiCore: ChronoFuel token already set or invalid update");
        chronoFuelToken = IChronoFuel(_tokenAddress);
        emit ChronoFuelTokenSet(_tokenAddress);
    }

    /**
     * @dev Sets the address of the Burn Certificate NFT contract.
     * @param _nftAddress The address of the Burn Certificate NFT contract.
     */
    function setBurnCertificateNFT(address _nftAddress) public onlyOwner {
        console.log("setBurnCertificateNFT:"); // DEBUG
        console.logAddress(_nftAddress); // DEBUG
        require(_nftAddress != address(0), "PoWaiCore: Zero address not allowed for NFT contract");
        require(address(burnCertificateNFT) == address(0) || address(burnCertificateNFT) == _nftAddress, "PoWaiCore: Burn Certificate NFT already set or invalid update");
        burnCertificateNFT = IBurnCertificateNFT(_nftAddress);
        emit BurnCertificateNFTSet(_nftAddress);
    }

    /**
     * @dev Sets the address of the Adaptive Halving contract.
     * @param _halvingAddress The address of the Adaptive Halving contract.
     */
    function setAdaptiveHalving(address _halvingAddress) public onlyOwner {
        console.log("setAdaptiveHalving:"); // DEBUG
        console.logAddress(_halvingAddress); // DEBUG
        require(_halvingAddress != address(0), "PoWaiCore: Zero address not allowed for Halving contract");
        require(address(adaptiveHalving) == address(0) || address(adaptiveHalving) == _halvingAddress, "PoWaiCore: Adaptive Halving already set or invalid update");
        adaptiveHalving = IAdaptiveHalving(_halvingAddress);
        emit AdaptiveHalvingSet(_halvingAddress);
    }

    /**
     * @dev Allows a user to stake CFL tokens.
     * Users must approve this contract to spend their tokens first.
     * @param amount The amount of CFL to stake.
     */
    function stake(uint256 amount) public nonReentrant {
        console.log("stake: amount"); console.logUint(amount); // DEBUG
        require(amount > 0, "PoWaiCore: Stake amount must be positive");
        require(chronoFuelToken.transferFrom(msg.sender, address(this), amount), "PoWaiCore: CFL transfer failed");
        userData[msg.sender].stakedAmount = userData[msg.sender].stakedAmount + amount;
        totalStakedAmount = totalStakedAmount + amount;
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Allows a user to unstake CFL tokens.
     * @param amount The amount of CFL to unstake.
     */
    function unstake(uint256 amount) public nonReentrant {
        console.log("unstake: amount"); console.logUint(amount); // DEBUG
        require(amount > 0, "PoWaiCore: Unstake amount must be positive");
        require(userData[msg.sender].stakedAmount >= amount, "PoWaiCore: Insufficient staked amount");
        userData[msg.sender].stakedAmount = userData[msg.sender].stakedAmount - amount;
        totalStakedAmount = totalStakedAmount - amount;
        require(chronoFuelToken.transfer(msg.sender, amount), "PoWaiCore: CFL transfer failed");
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Core function to claim PoWai rewards.
     * Includes time tracking, staking boost, burn boost, dynamic cooldown, and random rewards.
     */
    function claimReward() public nonReentrant {
        UserData storage user = userData[msg.sender];
        console.log("claimReward called by:"); console.logAddress(msg.sender); // DEBUG

        // <<<--- เพิ่ม require นี้
        require(user.stakedAmount > 0, "PoWaiCore: No active stake found"); 

        _updateActiveUsers(msg.sender);
        uint256 effectiveCooldown = getEffectiveCooldown();
        console.log("Cooldown debug: current_ts"); console.logUint(block.timestamp); // DEBUG
        console.log("Cooldown debug: last_claim_ts"); console.logUint(user.lastClaimTimestamp); // DEBUG
        console.log("Cooldown debug: cooldown"); console.logUint(effectiveCooldown); // DEBUG
        console.log("Cooldown debug: required_ts"); console.logUint(user.lastClaimTimestamp + effectiveCooldown); // DEBUG

        require(block.timestamp >= user.lastClaimTimestamp + effectiveCooldown, "PoWaiCore: Cooldown not yet passed");

        uint256 timeSinceLastClaim = block.timestamp - user.lastClaimTimestamp;
        
        // Adjust timeReward calculation to be more precise and always yield a non-zero reward if time has passed
        uint256 timeReward = (timeSinceLastClaim * BASE_TIME_REWARD_PER_HOUR_AHBM) / (1 hours);
        if (timeReward > BASE_TIME_REWARD_PER_HOUR_AHBM * MAX_WAIT_HOURS) { // Cap reward at max hours
            timeReward = BASE_TIME_REWARD_PER_HOUR_AHBM * MAX_WAIT_HOURS;
        }
        if (timeSinceLastClaim > 0 && timeReward == 0) { // Ensure minimum reward if time passed but calculation results in 0
            timeReward = 1; // Smallest possible non-zero unit (e.g., 1 Wei)
        }
        console.log("Reward calc: timeSinceLastClaim:"); console.logUint(timeSinceLastClaim); // DEBUG
        console.log("Reward calc: timeReward (scaled):"); console.logUint(timeReward); // DEBUG


        uint256 stakeBoostFactor = _calculateStakeBoost(user.stakedAmount);
        uint256 userBurned = chronoFuelToken.getUserBurnedAmount(msg.sender); // In AHBM_DECIMALS (10^18)
        console.log("Reward calc: userBurned (10^18 scaled):"); console.logUint(userBurned); // DEBUG

        uint256 burnFactorComponent;
        if (userBurned > 0) {
            // Convert userBurned from AHBM_DECIMALS (10^18) to base units
            uint256 userBurnedBaseUnits = userBurned / AHBM_DECIMALS; 
            console.log("Reward calc: userBurnedBaseUnits:", userBurnedBaseUnits); // DEBUG

            // Calculate sqrt(userBurned_base_units) scaled by PRECISION_FACTOR
            // x = userBurnedBaseUnits * PRECISION_FACTOR^2 => sqrt(x) = sqrt(userBurnedBaseUnits) * PRECISION_FACTOR
            uint256 userBurnedScaledForSqrt = userBurnedBaseUnits * PRECISION_FACTOR * PRECISION_FACTOR;
            console.log("Reward calc: userBurnedScaledForSqrt (input to sqrt):", userBurnedScaledForSqrt); // DEBUG

            uint256 sqrtValScaled = _integerSqrt(userBurnedScaledForSqrt); // Result is sqrt(userBurned_base_units) * PRECISION_FACTOR
            console.log("Reward calc: sqrtValScaled (output from sqrt):", sqrtValScaled); // DEBUG
            
            // burnFactorComponent = (0.7 * sqrt(userBurned_base_units)) * PRECISION_FACTOR
            // This is the correct scaling for addition with PRECISION_FACTOR
            burnFactorComponent = (BURN_FACTOR_NUMERATOR * sqrtValScaled) / BURN_FACTOR_DENOMINATOR;
            console.log("Reward calc: burnFactorComponent (final scaled):", burnFactorComponent); // DEBUG
        } else {
            burnFactorComponent = 0;
        }

        uint256 totalBurnBoostScaled = PRECISION_FACTOR + burnFactorComponent;
        console.log("Reward calc: totalBurnBoostScaled:", totalBurnBoostScaled); // DEBUG

        uint256 baseMintPower = timeReward * stakeBoostFactor; // timeReward is 10^18 scaled
        console.log("Reward calc: baseMintPower (time * stake, 10^18 scaled):", baseMintPower); // DEBUG

        // effectiveMintPower = baseMintPower (10^18 scaled) * totalBurnBoostScaled (PRECISION_FACTOR scaled) / PRECISION_FACTOR
        // Result is in 10^18 scaled units
        uint256 effectiveMintPower = (baseMintPower * totalBurnBoostScaled) / PRECISION_FACTOR;
        console.log("Reward calc: effectiveMintPower (base * burn, 10^18 scaled):", effectiveMintPower); // DEBUG

        uint256 finalReward;
        uint256 rewardTierId;
        (finalReward, rewardTierId) = _applyRandomRewardTier(msg.sender, effectiveMintPower);
        console.log("Reward calc: finalReward (after random tier):", finalReward, "tierId:", rewardTierId); // DEBUG

        chronoFuelToken._mintTokens(msg.sender, finalReward);
        user.lastClaimTimestamp = block.timestamp;

        emit RewardClaimed(msg.sender, timeSinceLastClaim, user.stakedAmount, effectiveMintPower, finalReward, rewardTierId, effectiveCooldown);
    }

    function boostBurn(uint256 amount) public nonReentrant {
        console.log("boostBurn called by:", msg.sender, " with amount:", amount); // DEBUG
        console.log("boostBurn: BurnCertNFT address in PoWaiCore:", address(burnCertificateNFT)); // DEBUG
        require(amount > 0, "PoWaiCore: Burn amount must be positive");
        require(address(burnCertificateNFT) != address(0), "PoWaiCore: Burn Certificate NFT contract not set"); // <<<--- บรรทัดที่ 256 ที่ Error เกิด

        chronoFuelToken.burnFrom(msg.sender, amount); 
        console.log("boostBurn: Amount burned (from user via burnFrom):", amount); // DEBUG

        uint256 currentTotalUserBurned = chronoFuelToken.getUserBurnedAmount(msg.sender);
        console.log("boostBurn: currentTotalUserBurned (after burn):", currentTotalUserBurned); // DEBUG

        uint256 userBurnedBeforeThisBurn = currentTotalUserBurned - amount; // Correct to get previous burned amount
        console.log("boostBurn: userBurnedBeforeThisBurn:", userBurnedBeforeThisBurn); // DEBUG


        uint256 currentStakeBoost = _calculateStakeBoost(userData[msg.sender].stakedAmount);
        uint256 timeRewardForCertificate = MAX_WAIT_HOURS * BASE_TIME_REWARD_PER_HOUR_AHBM;

        uint256 burnFactorComponentBeforeThisBurn;
    
        if (userBurnedBeforeThisBurn > 0) {
            uint256 userBurnedBeforeThisBurnBaseUnits = userBurnedBeforeThisBurn / AHBM_DECIMALS;
            uint256 userBurnedBeforeThisBurnScaledForSqrt = userBurnedBeforeThisBurnBaseUnits * PRECISION_FACTOR * PRECISION_FACTOR;
            uint256 sqrtValScaledBeforeThisBurn = _integerSqrt(userBurnedBeforeThisBurnScaledForSqrt);
            burnFactorComponentBeforeThisBurn = (BURN_FACTOR_NUMERATOR * sqrtValScaledBeforeThisBurn) / BURN_FACTOR_DENOMINATOR;
        } else {
            burnFactorComponentBeforeThisBurn = 0;
        }
        uint256 totalBurnBoostScaledBeforeBurn = PRECISION_FACTOR + burnFactorComponentBeforeThisBurn;
        uint256 mintPowerBeforeBurn = (timeRewardForCertificate * currentStakeBoost * totalBurnBoostScaledBeforeBurn) / PRECISION_FACTOR;

        uint256 daoPoints = (amount / AHBM_DECIMALS) * 4;
        uint256 airdropRights = amount / AHBM_DECIMALS;

        uint256 newNFTId = burnCertificateNFT.mintBurnCertificate(
            msg.sender,
            amount, // This is uint256
            mintPowerBeforeBurn,
            daoPoints,
            airdropRights
        );
        console.log("boostBurn: newNFTId:", newNFTId); // DEBUG

        emit BurnedForBoost(msg.sender, amount, newNFTId);
    }

    function _calculateStakeBoost(uint256 stakedAmount_in_AHBM_Decimals) internal pure returns (uint256) {
        if (stakedAmount_in_AHBM_Decimals == 0) {
            return 1;
        }
        uint256 stakedBaseUnits = stakedAmount_in_AHBM_Decimals / AHBM_DECIMALS;
        if (stakedBaseUnits == 0) {
            return 1;
        }
        uint256 valueForLog = stakedBaseUnits + 1;

        uint256 logResult = 0;
        if (valueForLog >= 1000000000) logResult = 9;
        else if (valueForLog >= 100000000) logResult = 8;
        else if (valueForLog >= 10000000) logResult = 7;
        else if (valueForLog >= 1000000) logResult = 6;
        else if (valueForLog >= 100000) logResult = 5;
        else if (valueForLog >= 10000) logResult = 4;
        else if (valueForLog >= 1000) logResult = 3;
        else if (valueForLog >= 100) logResult = 2;
        else if (valueForLog >= 10) logResult = 1;
        return 1 + logResult;
    }

    function _integerSqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x / 2) + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function _updateActiveUsers(address userAddress) internal {
        uint256 currentTimestamp = block.timestamp;
        uint256 lastActivity = userLastActivityTime[userAddress];

        if (lastActivity == 0 || currentTimestamp - lastActivity > ACTIVITY_WINDOW) {
            if (activeUsersIndex[userAddress] == 0) {
                activeUsersList.push(userAddress);
                activeUsersIndex[userAddress] = activeUsersList.length;
            }
            userLastActivityTime[userAddress] = currentTimestamp;
        }

        for (int256 i = int256(activeUsersList.length) - 1; i >= 0; i--) {
            address user = activeUsersList[uint256(i)];
            if (currentTimestamp - userLastActivityTime[user] > ACTIVITY_WINDOW) {
                address lastUser = activeUsersList[uint256(i)];
                activeUsersList[uint256(i)] = activeUsersList[activeUsersList.length - 1];
                activeUsersIndex[activeUsersList[uint256(i)]] = uint256(i) + 1;
                activeUsersIndex[user] = 0;
                activeUsersList.pop();
            }
        }
        activeUsersCount = activeUsersList.length;
    }

    function getEffectiveCooldown() public view returns (uint256) {
        uint256 cooldownReduction = COOLDOWN_DECREASE_PER_ACTIVE_USER_SECONDS * activeUsersCount;
        uint256 calculatedCooldown;
        if (cooldownReduction >= MAX_COOLDOWN_SECONDS) {
            calculatedCooldown = MIN_COOLDOWN_SECONDS;
        } else {
            calculatedCooldown = MAX_COOLDOWN_SECONDS - cooldownReduction;
        }
        return calculatedCooldown > MIN_COOLDOWN_SECONDS ? calculatedCooldown : MIN_COOLDOWN_SECONDS;
    }

    function _applyRandomRewardTier(address _user, uint256 _rawMintPower) internal returns (uint256 finalReward, uint256 rewardTierId) {
        _nonce[_user]++;
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            _user,
            _nonce[_user]
        )));

        uint256 rewardTierRoll = seed % 100;
        uint256 chosenMultiplierScaled; // Multiplier already scaled by 10

        if (rewardTierRoll < COMMON_PROB) {
            chosenMultiplierScaled = COMMON_MULTIPLIER_SCALED;
            rewardTierId = 0;
        } else if (rewardTierRoll < COMMON_PROB + RARE_PROB) {
            chosenMultiplierScaled = RARE_MULTIPLIER_SCALED;
            rewardTierId = 1;
        } else if (rewardTierRoll < COMMON_PROB + RARE_PROB + EPIC_PROB) {
            chosenMultiplierScaled = EPIC_MULTIPLIER_SCALED;
            rewardTierId = 2;
            if (address(adaptiveHalving) != address(0)) {
                adaptiveHalving.grantAntiHalvingShield(_user, address(this));
            }
        } else {
            chosenMultiplierScaled = LEGENDARY_MULTIPLIER_SCALED;
            rewardTierId = 3;
            if (address(adaptiveHalving) != address(0)) {
                adaptiveHalving.reduceHalvingRate(3, address(this));
            }
        }
        finalReward = ( _rawMintPower * chosenMultiplierScaled) / 10; // Divide by 10 as multipliers are scaled by 10
        return (finalReward, rewardTierId);
    }

    function getUserLastClaimTime(address user) public view returns (uint256) {
        return userData[user].lastClaimTimestamp;
    }

    function getUserStakedAmount(address user) public view returns (uint256) {
        return userData[user].stakedAmount;
    }

    function getTotalStakedAmount() public view returns (uint256) {
        return totalStakedAmount;
    }

    function isUserActive(address user) public view returns (bool) {
        return userLastActivityTime[user] != 0 && (block.timestamp - userLastActivityTime[user] <= ACTIVITY_WINDOW);
    }

    function getCurrentActiveUsersCount() public view returns (uint256) {
        return activeUsersCount;
    }
}