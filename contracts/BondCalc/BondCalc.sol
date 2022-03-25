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

contract BondCalc is Initializable, OwnableUpgradeable {

    IChainlink public oracle;
    uint public markdownPerc; // 2 decimals 5000 for 50%

    function initialize( uint markdownPerc_, IChainlink oracle_) external initializer{
        __Ownable_init();

        markdownPerc = markdownPerc_;
        oracle = oracle_;
    }

    function setMarkdownPerc(uint _markdownPerc) external onlyOwner {
        markdownPerc = _markdownPerc;
    }

    ///@return _value MarkdownPrice in usd (18 decimals)
    function valuation( address, uint amount_ ) external view returns ( uint _value ) {
        (,int _price,,,) = oracle.latestRoundData();
        _value = (uint(_price) * amount_ * markdownPerc) / 1e12;
    }

    ///@return Price of 1 token in USD (18 decimals)
    function getRawPrice() public view returns (uint) {
        (,int _price,,,) = oracle.latestRoundData();
        return uint(_price) * 1e10;
    }
}