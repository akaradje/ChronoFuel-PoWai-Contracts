// contracts/BurnCertificateNFT.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "hardhat/console.sol"; // <<<--- เพิ่มบรรทัดนี้สำหรับ console.log

/**
 * @title BurnCertificateNFT
 * @dev ERC-721 contract for issuing Burn Certificates.
 * Each NFT represents a burn event and holds associated metadata.
 */
contract BurnCertificateNFT is ERC721Enumerable, Ownable {
    uint256 private _tokenIdCounter;

    // PoWaiCore contract address, authorized to mint NFTs
    address public powaiCoreContract;

    // Struct to store metadata for each Burn Certificate
    struct CertificateData {
        address burner;
        uint256 amountBurned;        // The actual amount of CFL burned for this certificate
        uint256 mintPowerBeforeBurn; // Snapshot of theoretical mint power when burned
        uint256 daoPoints;           // DAO points associated with this burn
        uint256 airdropRights;       // Airdrop rights associated with this burn
        uint256 timestamp;
    }
    mapping(uint256 => CertificateData) public certificateDetails;

    event BurnCertificateMinted(uint256 indexed tokenId, address indexed to, uint256 amountBurned, uint256 mintPowerBeforeBurn);
    event PoWaiCoreContractSet(address indexed _powaiCoreContract);

    /**
     * @dev Constructor. Initializes the ERC-721 token.
     */
    constructor() ERC721("ChronoFuelBurnCertificate", "CFBC") Ownable(msg.sender) {
        _tokenIdCounter = 0;
    }

    /**
     * @dev Sets the address of the PoWaiCore contract.
     * Only the owner can call this. Crucial for authorizing NFT minting.
     * @param _powaiCoreAddress The address of the PoWaiCore contract.
     */
    function setPoWaiCoreContract(address _powaiCoreAddress) public onlyOwner {
        console.log("NFT: setPoWaiCoreContract called with:", _powaiCoreAddress); // DEBUG
        require(_powaiCoreAddress != address(0), "BurnCertificateNFT: Zero address not allowed for PoWaiCore");
        require(powaiCoreContract == address(0) || powaiCoreContract == _powaiCoreAddress, "BurnCertificateNFT: PoWaiCore address already set or invalid update");
        powaiCoreContract = _powaiCoreAddress;
        emit PoWaiCoreContractSet(_powaiCoreAddress);
    }

    /**
     * @dev Mints a new Burn Certificate NFT.
     * Only callable by the authorized PoWaiCore contract.
     * @param to The address to mint the NFT to.
     * @param amountBurned The amount of CFL burned for this certificate.
     * @param mintPowerBeforeBurn The calculated mint power snapshot before this burn.
     * @param daoPoints The DAO points granted by this burn.
     * @param airdropRights The airdrop rights granted by this burn.
     * @return tokenId The ID of the newly minted NFT.
     */
    function mintBurnCertificate(
        address to,
        uint256 amountBurned,
        uint256 mintPowerBeforeBurn,
        uint256 daoPoints,
        uint256 airdropRights
    ) external returns (uint256 tokenId) {
        console.log("NFT: mintBurnCertificate called by:", msg.sender); // DEBUG
        console.log("NFT: powaiCoreContract (stored):", powaiCoreContract); // DEBUG
        console.log("NFT: amountBurned received:", amountBurned); // DEBUG
        console.log("NFT: daoPoints received:", daoPoints); // DEBUG

        require(msg.sender == powaiCoreContract, "BurnCertificateNFT: Only PoWaiCore can mint");
        require(to != address(0), "BurnCertificateNFT: Cannot mint to zero address");

        _tokenIdCounter++;
        tokenId = _tokenIdCounter;
        _safeMint(to, tokenId);

        certificateDetails[tokenId] = CertificateData({
            burner: to,
            amountBurned: amountBurned,
            mintPowerBeforeBurn: mintPowerBeforeBurn,
            daoPoints: daoPoints,
            airdropRights: airdropRights,
            timestamp: block.timestamp
        });
        console.log("NFT: Stored amountBurned in cert:", certificateDetails[tokenId].amountBurned); // DEBUG

        emit BurnCertificateMinted(tokenId, to, amountBurned, mintPowerBeforeBurn);
        return tokenId;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}