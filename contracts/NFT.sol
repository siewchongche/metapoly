// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

contract NFT is Initializable, ERC721Upgradeable {
    
    uint tokenId;

    function initialize(
        string memory name_,
        string memory symbol_
    ) external initializer {
        __ERC721_init(name_, symbol_);
    }

    function mint(address receiver) external {
        _safeMint(receiver, tokenId);
        tokenId ++;
    }
}
