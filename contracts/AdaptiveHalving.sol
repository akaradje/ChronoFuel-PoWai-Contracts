// contracts/AdaptiveHalving.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IChronoFuelStats {
    function getTotalMinedTokens() external view returns (uint256);
    function getTotalGlobalBurned() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IPoWaiCoreStats {
    function getTotalStakedAmount() external view returns (uint256);
}

contract AdaptiveHalving is Ownable {
    IChronoFuelStats public chronoFuelToken;
    IPoWaiCoreStats public powaiCoreContract;

    uint256 public constant INITIAL_HALVING_THRESHOLD = 21_000_000 * (10 ** 18);
    uint256 public constant GLOBAL_BURN_THRESHOLD_FACTOR = 2_100_000_000 * (10 ** 18);
    uint256 public constant BASE_HALVING_RATE_PERCENT = 50;
    // <<<--- แก้ไขตรงนี้: STAKING_RATIO_COEFFICIENT_SCALED แทน STAKING_RATIO_IMPACT_FACTOR
    uint256 public constant STAKING_RATIO_COEFFICIENT_SCALED = 1 * (10**10) / 10; // Represents 0.1 * PRECISION_FACTOR

    uint256 public constant MAX_HALVING_RATE_PERCENT = 80;

    uint256 public constant PRECISION_FACTOR = 10**10;

    uint256 public halvingCount;
    uint256 public currentHalvingThreshold;
    uint256 public halvingKeyEffectPercentage;

    mapping(address => bool) public hasAntiHalvingShield;

    event HalvingTriggered(uint256 newThreshold, uint256 newRate, uint256 count);
    event AntiHalvingShieldGranted(address indexed user);
    event AntiHalvingShieldConsumed(address indexed user);
    event HalvingRateReducedByNFT(uint256 reductionAmount, uint256 newCumulativeReduction);
    event ChronoFuelTokenStatsSet(address indexed tokenAddress);
    event PoWaiCoreContractSet(address indexed coreAddress);

    constructor(address _chronoFuelTokenAddress) Ownable(msg.sender) {
        require(_chronoFuelTokenAddress != address(0), "AdaptiveHalving: ChronoFuel token address cannot be zero");
        chronoFuelToken = IChronoFuelStats(_chronoFuelTokenAddress);
        currentHalvingThreshold = INITIAL_HALVING_THRESHOLD;
        emit ChronoFuelTokenStatsSet(_chronoFuelTokenAddress);
    }

    function setChronoFuelToken(address _tokenAddress) public onlyOwner {
        require(address(chronoFuelToken) == address(0) || address(chronoFuelToken) == _tokenAddress, "AdaptiveHalving: ChronoFuel token already set or invalid update");
        require(_tokenAddress != address(0), "AdaptiveHalving: Zero address not allowed");
        chronoFuelToken = IChronoFuelStats(_tokenAddress);
        emit ChronoFuelTokenStatsSet(_tokenAddress);
    }

    function setPoWaiCoreContract(address _powaiCoreAddress) public onlyOwner {
        require(_powaiCoreAddress != address(0), "AdaptiveHalving: Zero address not allowed for PoWaiCore");
        require(address(powaiCoreContract) == address(0) || address(powaiCoreContract) == _powaiCoreAddress, "AdaptiveHalving: PoWaiCore address already set or invalid update");
        powaiCoreContract = IPoWaiCoreStats(_powaiCoreAddress);
        emit PoWaiCoreContractSet(_powaiCoreAddress);
    }

    function checkAndApplyHalving(address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        uint256 totalMined = chronoFuelToken.getTotalMinedTokens();
        if (totalMined >= currentHalvingThreshold) {
            halvingCount++;
            _calculateNextThreshold();
            uint256 currentRate = getAdjustedHalvingRate();
            emit HalvingTriggered(currentHalvingThreshold, currentRate, halvingCount);
        }
    }

    function grantAntiHalvingShield(address user, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        hasAntiHalvingShield[user] = true;
        emit AntiHalvingShieldGranted(user);
    }

    function consumeAntiHalvingShield(address user, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        require(hasAntiHalvingShield[user], "AdaptiveHalving: User does not have an Anti-Halving Shield");
        hasAntiHalvingShield[user] = false;
        emit AntiHalvingShieldConsumed(user);
    }

    function reduceHalvingRate(uint256 percentageReduction, address _powaiCoreAddress) external onlyOwnerOrPoWaiCore(_powaiCoreAddress) {
        require(percentageReduction > 0, "AdaptiveHalving: Reduction must be positive");
        halvingKeyEffectPercentage = halvingKeyEffectPercentage + percentageReduction;
        emit HalvingRateReducedByNFT(percentageReduction, halvingKeyEffectPercentage);
    }

    function _calculateNextThreshold() internal {
        uint256 globalBurned = chronoFuelToken.getTotalGlobalBurned();
        uint256 burnFactorScaled = (globalBurned * PRECISION_FACTOR) / GLOBAL_BURN_THRESHOLD_FACTOR;
        uint256 multiplierScaled = PRECISION_FACTOR + burnFactorScaled;
        currentHalvingThreshold = (INITIAL_HALVING_THRESHOLD * multiplierScaled) / PRECISION_FACTOR;
    }

    function getAdjustedHalvingRate() public view returns (uint256) {
        require(address(powaiCoreContract) != address(0), "AdaptiveHalving: PoWaiCore contract not set");
        require(address(chronoFuelToken) != address(0), "AdaptiveHalving: ChronoFuel token not set");

        uint256 totalStaked = powaiCoreContract.getTotalStakedAmount();
        uint256 totalSupply = chronoFuelToken.totalSupply();

        uint256 stakingRatioScaled = 0;
        if (totalSupply > 0) {
            stakingRatioScaled = (totalStaked * PRECISION_FACTOR) / totalSupply;
        }

        // <<<--- แก้ไขตรงนี้: ใช้ STAKING_RATIO_COEFFICIENT_SCALED
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