// contracts/AdaptiveHalving.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

// Interface for ChronoFuel token to access total mined/burned amounts and total supply
interface IChronoFuelStats {
    function getTotalMinedTokens() external view returns (uint256);
    function getTotalGlobalBurned() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

// Interface for PoWaiCore to query total staked amount
interface IPoWaiCoreStats {
    function getTotalStakedAmount() external view returns (uint256);
}

/**
 * @title AdaptiveHalving
 * @dev Manages the dynamic halving mechanism and special halving effects (shields, keys).
 * Calculates the next halving threshold and rate based on global token metrics.
 */
contract AdaptiveHalving is Ownable {
    IChronoFuelStats public chronoFuelToken; // Reference to ChronoFuel token for stats
    IPoWaiCoreStats public powaiCoreContract; // Reference to PoWaiCore for staked amount

    // --- Halving Constants & State ---
    uint256 public constant INITIAL_HALVING_THRESHOLD = 21_000_000 * (10 ** 18); // 21M CFL
    uint256 public constant GLOBAL_BURN_THRESHOLD_FACTOR = 2_100_000_000 * (10 ** 18); // 2.1B CFL for burn effect scaling
    uint256 public constant BASE_HALVING_RATE_PERCENT = 50; // 50%
    uint256 public constant STAKING_RATIO_COEFFICIENT_SCALED = 1 * (10**10) / 10; // Represents 0.1 * PRECISION_FACTOR

    uint256 public constant MAX_HALVING_RATE_PERCENT = 80;

    uint256 public constant PRECISION_FACTOR = 10**10; // 10^10

    uint256 public halvingCount; // Number of times halving has occurred
    uint256 public currentHalvingThreshold; // Current threshold for the next halving
    uint256 public halvingKeyEffectPercentage;

    mapping(address => bool) public hasAntiHalvingShield;

    event HalvingTriggered(uint256 newThreshold, uint256 newRate, uint256 count);
    event AntiHalvingShieldGranted(address indexed user);
    event AntiHalvingShieldConsumed(address indexed user);
    event HalvingRateReducedByNFT(uint256 reductionAmount, uint256 newCumulativeReduction);
    event ChronoFuelTokenStatsSet(address indexed tokenAddress);
    event PoWaiCoreContractSet(address indexed coreAddress);


    /**
     * @dev Constructor. Sets the initial ChronoFuel token address for stats.
     * @param _chronoFuelTokenAddress The address of the ChronoFuel token contract.
     */
    constructor(address _chronoFuelTokenAddress) Ownable(msg.sender) {
        require(_chronoFuelTokenAddress != address(0), "AdaptiveHalving: ChronoFuel token address cannot be zero");
        chronoFuelToken = IChronoFuelStats(_chronoFuelTokenAddress);
        currentHalvingThreshold = INITIAL_HALVING_THRESHOLD;
        emit ChronoFuelTokenStatsSet(_chronoFuelTokenAddress);
    }

    /**
     * @dev Sets the address of the ChronoFuel token contract for stats.
     * Can only be called once by the owner.
     * @param _tokenAddress The address of the ChronoFuel token contract.
     */
    function setChronoFuelToken(address _tokenAddress) public onlyOwner {
        require(address(chronoFuelToken) == address(0) || address(chronoFuelToken) == _tokenAddress, "AdaptiveHalving: ChronoFuel token already set or invalid update");
        require(_tokenAddress != address(0), "AdaptiveHalving: Zero address not allowed");
        chronoFuelToken = IChronoFuelStats(_tokenAddress);
        emit ChronoFuelTokenStatsSet(_tokenAddress);
    }

    /**
     * @dev Sets the address of the PoWaiCore contract.
     * This is needed to query the total staked amount for halving rate calculation.
     * @param _powaiCoreAddress The address of the PoWaiCore contract.
     */
    function setPoWaiCoreContract(address _powaiCoreAddress) public onlyOwner {
        require(_powaiCoreAddress != address(0), "AdaptiveHalving: Zero address not allowed for PoWaiCore");
        require(address(powaiCoreContract) == address(0) || address(powaiCoreContract) == _powaiCoreAddress, "AdaptiveHalving: PoWaiCore address already set or invalid update");
        powaiCoreContract = IPoWaiCoreStats(_powaiCoreAddress);
        emit PoWaiCoreContractSet(_powaiCoreAddress);
    }

    /**
     * @dev Checks if halving should occur and applies it.
     * This function should be called periodically (e.g., by a keeper network or during a key transaction).
     * @param _powaiCoreAddress The address of the PoWaiCore contract. Passed explicitly for modifier check.
     */
    function checkAndApplyHalving(address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        uint256 totalMined = chronoFuelToken.getTotalMinedTokens();
        if (totalMined >= currentHalvingThreshold) {
            halvingCount++;
            _calculateNextThreshold();
            uint256 currentRate = getAdjustedHalvingRate();
            emit HalvingTriggered(currentHalvingThreshold, currentRate, halvingCount);
        }
    }

    /**
     * @dev Grants an Anti-Halving Shield to a user.
     * Called by PoWaiCore when an Epic reward is won.
     * @param user The address of the user to grant the shield to.
     * @param _powaiCoreAddress The address of the PoWaiCore contract.
     */
    function grantAntiHalvingShield(address user, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        hasAntiHalvingShield[user] = true;
        emit AntiHalvingShieldGranted(user);
    }

    /**
     * @dev Consumes an Anti-Halving Shield for a user.
     * This function should be called by PoWaiCore when it detects a user with a shield
     * is about to be affected by a halving, allowing their next reward to be exempted.
     * @param user The address of the user whose shield to consume.
     * @param _powaiCoreAddress The address of the PoWaiCore contract.
     */
    function consumeAntiHalvingShield(address user, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        require(hasAntiHalvingShield[user], "AdaptiveHalving: User does not have an Anti-Halving Shield");
        hasAntiHalvingShield[user] = false;
        emit AntiHalvingShieldConsumed(user);
    }

    /**
     * @dev Reduces the system's global halving rate.
     * Called by PoWaiCore when a Legendary reward (Halving Key NFT) is won.
     * @param percentageReduction The percentage amount to reduce the halving rate by (e.g., 3 for 3%).
     * @param _powaiCoreAddress The address of the PoWaiCore contract.
     */
    function reduceHalvingRate(uint256 percentageReduction, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        require(percentageReduction > 0, "AdaptiveHalving: Reduction must be positive");
        
        halvingKeyEffectPercentage = halvingKeyEffectPercentage + percentageReduction;

        emit HalvingRateReducedByNFT(percentageReduction, halvingKeyEffectPercentage);
    }

    /**
     * @dev Calculates the next halving threshold.
     * Formula: Next Halving = 21M * (1 + Global_Burned / 2.1B)
     */
    function _calculateNextThreshold() internal {
        uint256 globalBurned = chronoFuelToken.getTotalGlobalBurned();
        
        // Ensure PRECISION_FACTOR is applied correctly for decimal math
        // (Global_Burned / 2.1B) is scaled by PRECISION_FACTOR
        uint256 burnFactorScaled = (globalBurned * PRECISION_FACTOR) / GLOBAL_BURN_THRESHOLD_FACTOR;
        
        // (1 + burnFactor) scaled by PRECISION_FACTOR
        uint256 multiplierScaled = PRECISION_FACTOR + burnFactorScaled; 

        currentHalvingThreshold = (INITIAL_HALVING_THRESHOLD * multiplierScaled) / PRECISION_FACTOR;
    }

    /**
     * @dev Calculates the current effective halving rate dynamically.
     * Formula: Halving_Rate = 50% * (1 + 0.1 * Staking_Ratio) - HalvingKeyEffect
     * Staking_Ratio = total_staked / total_supply
     * Max 80% when Staking Ratio > 300%
     * @return The calculated halving rate percentage.
     */
    function getAdjustedHalvingRate() public view returns (uint256) {
        require(address(powaiCoreContract) != address(0), "AdaptiveHalving: PoWaiCore contract not set");
        require(address(chronoFuelToken) != address(0), "AdaptiveHalving: ChronoFuel token not set");

        uint256 totalStaked = powaiCoreContract.getTotalStakedAmount();
        uint256 totalSupply = chronoFuelToken.totalSupply();

        uint256 stakingRatioScaled = 0;
        if (totalSupply > 0) {
            stakingRatioScaled = (totalStaked * PRECISION_FACTOR) / totalSupply;
        }

        uint256 stakingImpactScaled = (stakingRatioScaled * STAKING_RATIO_COEFFICIENT_SCALED) / PRECISION_FACTOR;

        uint256 halvingRateMultiplierScaled = PRECISION_FACTOR + stakingImpactScaled;

        uint256 newRate = (BASE_HALVING_RATE_PERCENT * halvingRateMultiplierScaled) / PRECISION_FACTOR;

        if (newRate >= halvingKeyEffectPercentage) {
            newRate = newRate - halvingKeyEffectPercentage;
        } else {
            newRate = 0;
        }

        if (newRate > MAX_HALVING_RATE_PERCENT) {
            return MAX_HALVING_RATE_PERCENT;
        } else {
            return newRate;
        }
    }

    modifier onlyOwnerOrPoWaiCore(address _powaiCoreAddress) {
        require(msg.sender == owner() || msg.sender == _powaiCoreAddress, "AdaptiveHalving: Unauthorized caller");
        _;
    }

    function getCurrentHalvingThreshold() public view returns (uint256) {
        return currentHalvingThreshold;
    }

    function getHalvingCount() public view returns (uint256) {
        return halvingCount;
    }

    function getCumulativeHalvingKeyEffectPercentage() public view returns (uint256) {
        return halvingKeyEffectPercentage;
    }
}