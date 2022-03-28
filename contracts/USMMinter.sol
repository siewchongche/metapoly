// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../libs/IERC20.sol";
import "../libs/BaseRelayRecipient.sol";

interface IUniswapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

contract USMMinter is BaseRelayRecipient, OwnableUpgradeable {

    using SafeERC20Upgradeable for IERC20;

    IERC20 public USM;
    IERC20 public DVD;
    IERC20 public D33D;
    IERC20 public WETH;
    IERC20 public USDC;

    mapping(IERC20=>IUniswapRouter) public routers;

    mapping(address=>bool) public allowedContract;

    uint constant UNIT_ONE_IN_BPS = 10000;
    uint public mintFeeBasisPoints;
    uint public lastMintTimestamp;
    uint public mintRate; //per second mintable rate, 1 usm = 1e18
    uint public mintBufferMax; //100K USM as max mint buffer
    uint public mintBuffer;
    uint public mintAmountMax;

    function initialize(
        address _USM,
        address _DVD,
        address _D33D,
        address _WETH,
        address _USDC,
        address _DVDRouter,
        address _D33DRouter,
        address _biconomyForwarder
    ) external initializer {
        require(_USM != address(0));

        mintFeeBasisPoints = 10;
        lastMintTimestamp = block.timestamp;
        mintRate = 30e18;
        mintBufferMax = 30000e18; // 30k
        mintAmountMax = 5000e18; // 5k

        __Ownable_init();

        USM = IERC20(_USM);
        DVD = IERC20(_DVD);
        D33D = IERC20(_D33D);
        WETH = IERC20(_WETH);
        USDC = IERC20(_USDC);

        routers[DVD] = IUniswapRouter(_DVDRouter); // DVD => USDC
        routers[D33D] = IUniswapRouter(_D33DRouter); // D33D => USDC

        trustedForwarder = _biconomyForwarder;
    }

    modifier onlyAllowed {
        require(msg.sender == tx.origin || allowedContract[msg.sender] || isTrustedForwarder(msg.sender), "Not allowed");
        _;
    }

    /// @notice Function that required for inherict BaseRelayRecipient
    function _msgSender() internal override(ContextUpgradeable, BaseRelayRecipient) view returns (address) {
        return BaseRelayRecipient._msgSender();
    }

    /// @notice Function that required for inherict BaseRelayRecipient
    function versionRecipient() external pure override returns (string memory) {
        return "1";
    }

    function setBiconomy(address _biconomy) external onlyOwner {
        trustedForwarder = _biconomy;
    }

    function setUSM(address _USM) external onlyOwner {
        require(_USM != address(0));
        USM = IERC20(_USM);
    }

    function setDVD(address _DVD) external onlyOwner {
        require(_DVD != address(0));
        DVD = IERC20(_DVD);
    }

    function setD33D(address _D33D) external onlyOwner {
        require(_D33D != address(0));
        D33D = IERC20(_D33D);
    }

    function setWETH(address _WETH) external onlyOwner {
        require(_WETH != address(0));
        WETH = IERC20(_WETH);
    }

    function setUSDC(address _USDC) external onlyOwner {
        require(_USDC != address(0));
        USDC = IERC20(_USDC);
    }

    function setDvdLpSwapRouter(address _swapRouter) external onlyOwner {
        routers[DVD] = IUniswapRouter(_swapRouter);
    }

    function setD33dLpSwapRouter(address _swapRouter) external onlyOwner {
        routers[D33D] = IUniswapRouter(_swapRouter);
    }

    function setMintFee(uint _mintFeeBasisPoints) external onlyOwner {
        require(_mintFeeBasisPoints<=1000, "fee can't be higher than 1000 bps");
        mintFeeBasisPoints = _mintFeeBasisPoints;
    }
    
    function setMintAmountMax(uint _mintAmountMax) external onlyOwner {
        mintAmountMax = _mintAmountMax;
    }

    function addAllowedContract(address _contract) external onlyOwner {
        if(allowedContract[_contract] == false) allowedContract[_contract] = true;
    }

    function removeAllowedContract(address _contract) external onlyOwner {
        if(allowedContract[_contract] == true) delete allowedContract[_contract];
    }

    function collectFee() external onlyOwner {
        uint usmBalance = USM.balanceOf(address(this));
        if (0 < usmBalance) {
            address ownerAddress = owner();
            require(ownerAddress != address(0), "Invalid owner address");
            USM.safeTransfer(ownerAddress, usmBalance);
        }
    }

    function convertDecimal(IERC20 from, IERC20 to, uint fromAmount) view public returns(uint toAmount) {
        uint8 fromDec = from.decimals();
        uint8 toDec = to.decimals();
        if(fromDec == toDec) toAmount = fromAmount;
        else if(fromDec > toDec) toAmount = fromAmount / (10**(fromDec-toDec));
        else toAmount = fromAmount * (10**(toDec-fromDec));
    }

    function getUsmAmountOut(IERC20 _token, uint _tokenAmount) view public returns(uint _usmAmount) {
        uint USDCAmount = getUsdcAmountOut(_token, _tokenAmount);
        uint usm2mint = convertDecimal(USDC, USM, USDCAmount);
        uint fee = usm2mint * mintFeeBasisPoints / UNIT_ONE_IN_BPS;
        _usmAmount = usm2mint - fee;
    }

    function getUsdcAmountOut(IERC20 _token, uint _tokenAmount) view internal returns(uint _USDCAmount) {
        if (_token == D33D) {
            address[] memory path = new address[](2);
            path[0] = address(_token);
            path[1] = address(USDC);
            uint[] memory amounts = routers[_token].getAmountsOut(_tokenAmount, path);
            _USDCAmount = amounts[1];
        } else {
            address[] memory path = new address[](3);
            path[0] = address(_token);
            path[1] = address(WETH);
            path[2] = address(USDC);
            uint[] memory amounts = routers[_token].getAmountsOut(_tokenAmount, path);
            _USDCAmount = amounts[2];
        }
    }

    function mintWithToken(IERC20 _token, uint _tokenAmount, address _to) internal returns(uint _usmAmount) {
        uint USDCAmount = getUsdcAmountOut(_token, _tokenAmount);
        require(0 < USDCAmount, "invalid amount from swap");

        uint usm2mint = convertDecimal(USDC, USM, USDCAmount);
        require(usm2mint <= mintAmountMax, "Mint amount is too large");

        uint fee = usm2mint * mintFeeBasisPoints / UNIT_ONE_IN_BPS;
        _usmAmount = usm2mint - fee;

        _token.safeTransferFrom(_msgSender(), address(this), _tokenAmount);
        _token.burn(_tokenAmount);
        USM.mint(address(this), usm2mint);
        USM.transfer(_to, _usmAmount);
    }

    function mintWithDvd(uint _DVDAmount, address _to) external onlyAllowed returns(uint _usmAmount) {
        return mintWithToken(DVD, _DVDAmount, _to);
    }

    function mintWithD33d(uint _D33DAmount, address _to) external onlyAllowed returns(uint _usmAmount) {
        return mintWithToken(D33D, _D33DAmount, _to);
    }

    function mint(address _to, uint _usm2mint) external onlyOwner {
        USM.mint(_to, _usm2mint);
    }
}
