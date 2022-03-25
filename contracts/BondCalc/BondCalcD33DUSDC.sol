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

interface IPair {
    function getReserves() external view returns (uint, uint);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint);
}

interface IRouter {
    function getAmountsOut(uint, address[] memory) external view returns (uint[] memory);
}

contract BondCalcD33DUSDC is Initializable, OwnableUpgradeable {

    address public D33D;
    address public USDC;
    IPair public pair;
    IRouter public router;
    
    uint markdownPerc; // 2 decimals, 5000 for 50%
    
    function initialize(
        uint markdownPerc_, 
        IPair _pair, 
        IRouter _router,
        address _D33D,
        address _USDC
    ) external initializer{
        __Ownable_init();
        
        markdownPerc = markdownPerc_;
        router = _router;
        pair = _pair;
        D33D = _D33D;
        USDC = _USDC;
    }

    function changeMarkdownPerc(uint newPerc_) external onlyOwner {
        markdownPerc = newPerc_;
    }

    function lpPrice(uint _amount) private view returns (uint) {
        (uint reserve0, uint reserve1) = pair.getReserves();
        uint totalSupply_ = pair.totalSupply();

        if(pair.token0() != D33D) {
            (reserve0, reserve1) = (reserve1, reserve0);
        }

        // get D33D price in USDC
        address[] memory path = new address[](2);
        path[0] = D33D;
        path[1] = USDC;
        uint price_ = router.getAmountsOut(1e18, path)[1];

        uint total0 = _amount * reserve0 / totalSupply_;
        uint total1 = _amount * reserve1 / totalSupply_;

        return ((price_ * total0) + (total1 * 1e18)) / 1e6;
    }

    /// @return _value MarkdownPrice in usd (18 decimals)
    function valuation( address, uint amount_ ) external view returns ( uint _value ) {
        return lpPrice(amount_) * markdownPerc / 10000;
    }

    /// @return Price of LP token in USD (18 decimals)
    function getRawPrice() external view returns (uint) {
        return lpPrice(1e18);
    }
}
