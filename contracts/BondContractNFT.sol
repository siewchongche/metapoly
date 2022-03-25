// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./BondContract.sol";

contract BondContractNFT is BondContract {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IPrinciple;

    function initialize(
        IERC20Upgradeable _D33D,
        IPrinciple _principle,
        ITreasury _treasury,
        address _DAO,
        IBondCalc _bondCalc,
        IStaking _staking,
        address _admin,
        address _trustedForwarderAddress
    ) external override initializer {
        D33D = _D33D;
        principle  = _principle;
        treasury = _treasury;
        bondCalc = _bondCalc;
        staking = _staking;
        DAO = _DAO;
        admin = _admin;
        _trustedForwarder = _trustedForwarderAddress;

        isLiquidityBond = true;
        principle.setApprovalForAll(address(_treasury), true);
        D33D.safeApprove(address(_staking), type(uint).max);
    }

    /**
        @notice Function to deposit principleToken. Principle token is deposited to treasury
        and D33D is minted. The minted D33D is vested for a specific time.
        @param _tokenId Id of principle token to deposit
        @param _maxPrice Used for slippage handling. Price in terms of principle token.
        @param _depositor address of User to receive bond D33D
     */
    function deposit(
        uint _tokenId, 
        uint _maxPrice,
        address _depositor
    ) external payable override returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );

        decayDebt();
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = bondCalc.getRawPrice();
        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 1e16, "Bond too small" ); // must be > 0.01 D33D ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        principle.safeTransferFrom( _msgSender(), address(this), _tokenId );
        treasury.depositNFT( _tokenId, address(principle), payout);

        // profits are calculated
        if (terms.fee > 0) {
            uint fee = payout * terms.fee / 10000;
            payout -= fee;
            D33D.safeTransfer( DAO, fee ); // fee is transferred to dao 
        }
        
        // total debt is increased
        totalDebt = totalDebt + value;
                
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            payout: bondInfo[ _depositor ].payout + payout,
            vesting: terms.vestingTerm,
            lastTimestamp: block.timestamp,
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated( _tokenId, payout, block.timestamp + terms.vestingTerm, priceInUSD );
        emit BondPriceChanged( bondPriceInUSD(), bondPrice(), debtRatio() );

        adjust(); // control variable is adjusted
        return payout; 
    }
}
