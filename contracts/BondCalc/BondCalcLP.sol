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

interface IERC20 {
    function decimals() external view returns (uint);
}

interface IRouter {
    function getAmountsOut(uint, address[] memory) external view returns (uint[] memory);
}

contract BondCalcLP is Initializable, OwnableUpgradeable {

    address public WETH;
    address public token0;
    address public token1;
    uint token0Decimal;
    uint token1Decimal;
    IPair public pair;
    IRouter public router;
    IChainlink public oracle;
    uint public markdownPerc; // 2 decimals 5000 for 50%

    function initialize(
        uint markdownPerc_,
        IChainlink _oracle,
        IPair _pair,
        IRouter _router,
        address _WETH
    ) external initializer{
        __Ownable_init();
        
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();
        token0Decimal = IERC20(token0).decimals();
        token1Decimal = IERC20(token1).decimals();
        WETH = _WETH;
        router = _router;
        markdownPerc = markdownPerc_;
        oracle = _oracle;

    }

    function changeMarkdownPerc(uint newPerc_) external onlyOwner {
        markdownPerc = newPerc_;
    }

    function getLpTokenPriceInETH() private view returns (uint lpTokenPriceInETH) {
        (uint reserveToken0, uint reserveToken1) = pair.getReserves();

        uint totalReserveTokenInETH;
        if (token0 == WETH) {
            uint token1PriceInETH = router.getAmountsOut(10 ** token1Decimal, getPath(token1, WETH))[1];
            uint reserveToken1InETH = reserveToken1 * token1PriceInETH / 10 ** token1Decimal;
            totalReserveTokenInETH = reserveToken0 + reserveToken1InETH;
        } else if (token1 == WETH) {
            uint token0PriceInETH = router.getAmountsOut(10 ** token0Decimal, getPath(token0, WETH))[1];
            uint reserveToken0InETH = reserveToken0 * token0PriceInETH / 10 ** token0Decimal;
            totalReserveTokenInETH = reserveToken1 + reserveToken0InETH;
        } else {
            uint token0PriceInETH = router.getAmountsOut(10 ** token0Decimal, getPath(token0, WETH))[1];
            uint reserveToken0InETH = reserveToken0 * token0PriceInETH / 10 ** token0Decimal;

            uint token1PriceInETH;
            token1PriceInETH = router.getAmountsOut(10 ** token1Decimal, getPath(token1, WETH))[1];

            uint reserveToken1InETH = reserveToken1 * token1PriceInETH / 10 ** token1Decimal;
            totalReserveTokenInETH = reserveToken0InETH + reserveToken1InETH;
        }

        lpTokenPriceInETH = totalReserveTokenInETH * 1e18 / pair.totalSupply();
    }

    function getLpTokenPriceInUSD() public virtual view returns (uint lpTokenPriceInUSD) {
        (,int _price,,,) = oracle.latestRoundData();
        lpTokenPriceInUSD = uint(_price) * getLpTokenPriceInETH() / 1e8;
    }

    function getPath(address tokenIn, address tokenOut) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    ///@return _value MarkdownPrice in usd (18 decimals)
    function valuation( address, uint amount_ ) external view returns ( uint _value ) {
        return amount_ * getLpTokenPriceInUSD() * markdownPerc / 1e22;
    }

    ///@return Price of LP token in USD (18 decimals)
    function getRawPrice() external view returns (uint) {
        return getLpTokenPriceInUSD();
    }
}
