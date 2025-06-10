// contracts/ChronoFuel.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ChronoFuel is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 21_000_000 * (10 ** 18); // 21M tokens with 18 decimals
    uint256 public totalGlobalBurned; // Total CFL burned across the entire system
    uint256 public totalMinedTokens;  // Total CFL minted across the entire system

    // Mapping to store user-specific burned amounts for Burn Booster Engine
    mapping(address => uint256) public userBurnedAmounts;

    // The address of the PoWaiCore contract, authorized to mint tokens
    address public powaiCoreContract;

    // --- Events ---
    event TokensBurned(address indexed burner, uint256 amount);
    event TokensMinted(address indexed minter, uint256 amount);
    event PoWaiCoreContractSet(address indexed _powaiCoreContract);

    constructor() ERC20("ChronoFuel", "CFL") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY); // Mint initial supply to the deployer
        totalMinedTokens = INITIAL_SUPPLY; // <<<--- FIX: อัปเดต totalMinedTokens ใน constructor
    }

    function setPoWaiCoreContract(address _powaiCoreContract) public onlyOwner {
        require(_powaiCoreContract != address(0), "ChronoFuel: Zero address not allowed for PoWaiCore");
        require(powaiCoreContract == address(0) || powaiCoreContract == _powaiCoreContract, "ChronoFuel: PoWaiCore address already set or invalid update");
        powaiCoreContract = _powaiCoreContract;
        emit PoWaiCoreContractSet(_powaiCoreContract);
    }

    function _mintTokens(address to, uint256 amount) external { // Changed to external for PoWaiCore to call
        require(msg.sender == powaiCoreContract, "ChronoFuel: Only PoWaiCore can mint");
        require(amount > 0, "ChronoFuel: Cannot mint zero tokens");
        _mint(to, amount);
        totalMinedTokens = totalMinedTokens + amount;
        emit TokensMinted(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
        totalGlobalBurned = totalGlobalBurned + amount;
        userBurnedAmounts[msg.sender] = userBurnedAmounts[msg.sender] + amount;
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @dev Burns `amount` tokens from `from`, deducting from the caller's allowance.
     * This function is intended to be called by authorized contracts (like PoWaiCore).
     * @param from The address whose tokens will be burned.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address from, uint256 amount) public {
        _spendAllowance(from, msg.sender, amount); // msg.sender is PoWaiCore
        _burn(from, amount); // Burn from 'from'
        totalGlobalBurned = totalGlobalBurned + amount;
        userBurnedAmounts[from] = userBurnedAmounts[from] + amount; // Update user's specific burned amount
        emit TokensBurned(from, amount);
    }

    function getTotalGlobalBurned() public view returns (uint256) {
        return totalGlobalBurned;
    }

    function getTotalMinedTokens() public view returns (uint256) {
        return totalMinedTokens;
    }

    function getUserBurnedAmount(address user) public view returns (uint256) {
        return userBurnedAmounts[user];
    }
}