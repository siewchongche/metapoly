// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IChainlink {
    function latestRoundData() external view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

interface INFTOracle {
    function requestPriceUpdate() external;
}

contract BondCalcNFT is Initializable, OwnableUpgradeable {

    INFTOracle public nftOracle;
    IChainlink public ethOracle;
    address public admin;
    uint public nftPriceInETH;
    uint public markdownPerc; // 2 decimals 5000 for 50%

    function initialize( uint markdownPerc_, INFTOracle nftOracle_, IChainlink ethOracle_ ) external initializer{
        __Ownable_init();

        markdownPerc = markdownPerc_;
        nftOracle = nftOracle_;
        ethOracle = ethOracle_;
        admin = msg.sender;
    }

    function setMarkdownPerc(uint _newPerc) external onlyOwner {
        markdownPerc = _newPerc;
    }

    function setAdmin(address _newAdmin) external onlyOwner {
        admin = _newAdmin;
    }

    function setNFTOracle(INFTOracle _nftOracle) external onlyOwner {
        nftOracle = _nftOracle;
    }

    ///@notice Trigger a price update
    function requestPriceUpdate() external {
        require(msg.sender == admin || msg.sender == owner(), "Not authorized");

        INFTOracle(nftOracle).requestPriceUpdate();
    }

    function setPrice(uint _price) external {
        require(
            msg.sender == admin ||
            msg.sender == address(nftOracle) ||
            msg.sender == owner(),
            "Not authorized"
        );
        
        nftPriceInETH = _price;
    }

    ///@return _value MarkdownPrice in USD (18 decimals)
    function valuation( address, uint ) external view returns ( uint _value ) {
        _value = getRawPrice() * markdownPerc / 10000;
    }

    ///@return Price of 1 token in USD (18 decimals)
    function getRawPrice() public view returns (uint) {
        (,int _ethPriceInUSD,,,) = ethOracle.latestRoundData();
        return nftPriceInETH * uint(_ethPriceInUSD) / 1e8;
    }
}