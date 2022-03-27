// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

interface IBondCalculator {
  function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}

interface ID33D is IERC20Upgradeable{
    function mint(address, uint amount) external;
    function burnFrom(address, uint amount) external;
    function decimals() external view returns(uint8);
}

interface IToken is IERC20Upgradeable {
    function decimals() external view returns(uint8);
}

interface INFTBond {
    function priciple() external view returns(address);
}

contract Treasury is Initializable, OwnableUpgradeable, IERC721ReceiverUpgradeable {

    using SafeERC20Upgradeable for ID33D;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    ID33D public D33D;

    address[] public reserveTokens; // Push only, beware false-positives.
    mapping( address => bool ) public isReserveToken;

    address[] public reserveDepositors; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveDepositor;

    address[] public reserveSpenders; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveSpender;

    address[] public liquidityTokens; // Push only, beware false-positives.
    mapping( address => bool ) public isLiquidityToken;

    address[] public liquidityDepositors; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isLiquidityDepositor;

    mapping( address => address ) public bondCalculator; // bond calculator for liquidity token

    address[] public reserveManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveManager;

    address[] public liquidityManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isLiquidityManager;

    address[] public rewardManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isRewardManager;

    address[] public supportedNFTs; // Push only, beware false-positives. Only for viewing.
    mapping(address => bool)public isSupportedNFT;

    address[] public nftDepositors; // Push only, beware false-positives. Only for viewing.
    mapping(address => bool)public isNFTDepositor;

    uint public totalReserves; // Risk-free value of all assets

    uint public D33DPrice; // Should not be used as oracle

    event Deposit( address indexed token, uint amount, uint value );
    event DepositNFT( address indexed token, uint id, uint value );
    event Withdrawal( address indexed token, uint amount, uint value );
    event RewardsMinted( address indexed caller, address indexed recipient, uint amount );
    event ChangeActivated( MANAGING indexed managing, address activated, bool result );
    event ReservesManaged( address indexed token, uint amount );
    event NFTManaged( address indexed token, uint tokenId );
    event ReservesUpdated( uint indexed totalReserves );
    event ReservesAudited( uint indexed totalReserves );

    function initialize(
        address _D33D,         
        address _USDC,
        uint _D33DPrice
    ) external initializer {
        __Ownable_init();

        D33DPrice = _D33DPrice;
        D33D = ID33D(_D33D);

        isReserveToken[ _USDC ] = true;
        reserveTokens.push( _USDC );
    }

    function updateD33DPrice(uint _D33DPrice) external onlyOwner {
        D33DPrice = _D33DPrice;
    }

    function lpValuation(uint _amount, address _token) public view returns (uint) {
        return IBondCalculator( bondCalculator[ _token ] ).valuation( _token, _amount );
    }

    /**
        @notice takes inventory of all tracked assets
        @notice always consolidate to recognized reserves before audit
    */
    function auditReserves() external onlyOwner {
        uint reserves;
        for( uint i = 0; i < reserveTokens.length; i++ ) {
            reserves = reserves + ( 
                valueOf( reserveTokens[ i ], IERC20Upgradeable( reserveTokens[ i ] ).balanceOf( address(this) ) )
            );
        }

        for( uint i = 0; i < liquidityTokens.length; i++ ) {
            reserves = reserves + lpValuation(IERC20Upgradeable( liquidityTokens[ i ] ).balanceOf( address(this) ), liquidityTokens[ i ]);
        }

        for( uint i = 0; i< supportedNFTs.length; i++ ) {
            reserves = reserves + lpValuation(IERC721Upgradeable( supportedNFTs[ i ] ).balanceOf( address(this) ), supportedNFTs[ i ]);
        }

        totalReserves = reserves;
        emit ReservesUpdated( reserves );
        emit ReservesAudited( reserves );
    }

    /// @notice allow approved address to deposit an asset for D33D
    function deposit( uint _amount, address _token, uint _payout ) external {
        require( isReserveToken[ _token ] || isLiquidityToken[ _token ], "Not accepted" );
        if ( isReserveToken[ _token ] ) {
            require( isReserveDepositor[ msg.sender ], "Not approved" );
        } else {
            require( isLiquidityDepositor[ msg.sender ], "Not approved" );
        }

        IERC20Upgradeable( _token ).safeTransferFrom( msg.sender, address(this), _amount );
        D33D.mint(msg.sender, _payout);

        uint value;
        if (isReserveToken[ _token ]) {
            value = valueOf( _token, _amount );
        } else {
            value = lpValuation(_amount, _token);
        }
        totalReserves = totalReserves + value;
        emit ReservesUpdated( totalReserves );

        emit Deposit( _token, _amount, value );
    }

    /// @notice allow approved address to deposit an NFT for D33D
    function depositNFT(uint _tokenId, address _token, uint _payout) external {
        require(isSupportedNFT[_token], "Not accepted");
        require(isNFTDepositor[msg.sender], "Not approved");

        IERC721Upgradeable(_token).safeTransferFrom(msg.sender, address(this), _tokenId);
        D33D.mint(msg.sender, _payout);

        // 1 is just represent 1 NFT; It won't be used in lpValuation and its subsequent functions 
        uint _value = lpValuation(1, _token);
        totalReserves = totalReserves + _value;
        emit ReservesUpdated( totalReserves );

        emit DepositNFT( _token, _tokenId, _value );
    }

    /// @notice allow approved address to burn D33D for reserves
    function withdraw( uint _amount, address _token ) external {
        require( isReserveToken[ _token ], "Not accepted" ); // Only reserves can be used for redemptions
        require( isReserveSpender[ msg.sender ] == true, "Not approved" );

        uint value = valueOf( _token, _amount );
        uint quantity = value * 1e18 / D33DPrice;

        D33D.burnFrom( msg.sender, quantity );

        totalReserves = totalReserves - value ;
        emit ReservesUpdated( totalReserves );
        
        IERC20Upgradeable( _token ).safeTransfer( msg.sender, _amount );
        emit Withdrawal( _token, _amount, value );

    }

    /// @notice allow approved address to withdraw assets
    function manage( address _token, uint _amount ) external {
        uint value;

        if( isLiquidityToken[ _token ] ) {
            require( isLiquidityManager[ msg.sender ], "Not approved" );
            value = lpValuation(_amount, _token);
        } else {
            require( isReserveManager[ msg.sender ], "Not approved" );
            value = valueOf( _token, _amount );
        }

        
        require( value <= excessReserves(), "reserves" );

        totalReserves = totalReserves - value;
        emit ReservesUpdated( totalReserves );

        IERC20Upgradeable( _token ).safeTransfer( msg.sender, _amount );
        emit ReservesManaged( _token, _amount );

    }

    function manageNFT( address _token, uint _tokenId ) external {
        require(isLiquidityManager[msg.sender], "Not approved");
        // 1 is just represent 1 NFT; It won't be used in lpValuation and its subsequent functions 
        uint value = lpValuation(1, _token);

        require( value <= excessReserves(), "reserves" );
        
        totalReserves = totalReserves - value;
        emit ReservesUpdated( totalReserves );

        IERC721Upgradeable( _token ).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit NFTManaged( _token, _tokenId );
    }

    /// @notice send epoch reward to staking contract
    function mintRewards( address _recipient, uint _amount ) external {
        require( isRewardManager[ msg.sender ], "Not approved" );
        require( _amount <= excessReserves(), "reserves" );

        D33D.mint(_recipient, _amount);

        emit RewardsMinted( msg.sender, _recipient, _amount );
    } 

    /// @notice returns D33D valuation of asset
    function valueOf( address _token, uint _amount ) public view returns ( uint value_ ) {
        value_ = _amount * ( 10 ** D33D.decimals() ) / ( 10 ** IToken( _token ).decimals() );
    }

    /// @notice returns excess reserves not backing tokens
    function excessReserves() public view returns ( uint ) {
        return totalReserves - (D33D.totalSupply() * D33DPrice / 1e18);
    }

    enum MANAGING { RESERVEDEPOSITOR, RESERVESPENDER, RESERVETOKEN, RESERVEMANAGER, LIQUIDITYDEPOSITOR, 
        LIQUIDITYTOKEN, LIQUIDITYMANAGER, REWARDMANAGER, NFTDEPOSITOR, SUPPORTEDNFT  }

    function editPermission(MANAGING _managing, address _address, bool _status) external onlyOwner {
        require( _address != address(0) );
        
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            isReserveDepositor[_address] = _status;
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            isReserveSpender[_address] = _status;
        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
            isReserveToken[_address] = _status;
        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            isReserveManager[_address] = _status;
        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            isLiquidityDepositor[_address] = _status;
        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            isLiquidityToken[_address] = _status;
        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            isLiquidityManager[_address] = _status;
        } else if ( _managing == MANAGING.REWARDMANAGER ) { // 7
            isRewardManager[_address] = _status;
        } else if ( _managing == MANAGING.NFTDEPOSITOR ) { // 8
            isNFTDepositor[_address] = _status;
        } else if ( _managing == MANAGING.SUPPORTEDNFT ) { // 9
            isSupportedNFT[_address] = _status;
        }
    }

    function toggle( MANAGING _managing, address _address, address _calculator ) external onlyOwner {
        require( _address != address(0) );
        bool result;
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            if( !listContains( reserveDepositors, _address ) ) {
                reserveDepositors.push( _address );
            }
            result = !isReserveDepositor[ _address ];
            isReserveDepositor[ _address ] = result;
            
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            if( !listContains( reserveSpenders, _address ) ) {
                reserveSpenders.push( _address );
            }
            result = !isReserveSpender[ _address ];
            isReserveSpender[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
            if( !listContains( reserveTokens, _address ) ) {
                reserveTokens.push( _address );
            }
            result = !isReserveToken[ _address ];
            isReserveToken[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            if( !listContains( reserveManagers, _address ) ) {
                reserveManagers.push( _address );
            }
            
            result = !isReserveManager[ _address ];
            isReserveManager[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            if( !listContains( liquidityDepositors, _address ) ) {
                liquidityDepositors.push( _address );
            }
            result = !isLiquidityDepositor[ _address ];
            isLiquidityDepositor[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            if( !listContains( liquidityTokens, _address ) ) {
                liquidityTokens.push( _address );
            }
            result = !isLiquidityToken[ _address ];
            isLiquidityToken[ _address ] = result;
            bondCalculator[ _address ] = _calculator;

        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            if( !listContains( liquidityManagers, _address ) ) {
                liquidityManagers.push( _address );
            }
            result = !isLiquidityManager[ _address ];
            isLiquidityManager[ _address ] = result;

        } else if ( _managing == MANAGING.REWARDMANAGER ) { // 7
            if( !listContains( rewardManagers, _address ) ) {
                rewardManagers.push( _address );
            }
            result = !isRewardManager[ _address ];
            isRewardManager[ _address ] = result;

        } else if ( _managing == MANAGING.NFTDEPOSITOR ) { // 8
            if( !listContains( rewardManagers, _address ) ) {
                nftDepositors.push( _address );
            }
            result = !isNFTDepositor[ _address ];
            isNFTDepositor[ _address ] = result;

        } else if ( _managing == MANAGING.SUPPORTEDNFT ) { // 9
            if( !listContains( rewardManagers, _address ) ) {
                supportedNFTs.push( _address );
            }
            result = !isSupportedNFT[ _address ];
            isSupportedNFT[ _address ] = result;
            bondCalculator[ _address ] = _calculator;
        }

        emit ChangeActivated( _managing, _address, result );
    }

    /// @notice checks array to ensure against duplicate
    function listContains( address[] storage _list, address _token ) internal view returns ( bool ) {
        for( uint i = 0; i < _list.length; i++ ) {
            if( _list[ i ] == _token ) {
                return true;
            }
        }
        return false;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }
}
