// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IPrinciple is IERC20Upgradeable {
    function decimals() external view returns(uint);
    function deposit() external payable;
    function setApprovalForAll(address, bool) external;
}

interface IStaking {
    function stake(uint _amount, address _receiver) external returns (bool) ;
}

interface ITreasury {
    function deposit(uint amount, address principle, uint payout) external ;
    function depositNFT(uint _tokenId, address _token, uint _payout) external;
    function valueOf( address _token, uint _amount ) external view returns ( uint value_ );
}

interface IBondCalc {
    function getRawPrice() external view returns ( uint );
}

contract BondContract is Initializable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IPrinciple;

    IERC20Upgradeable public D33D; // token given as payment for bond
    IPrinciple public principle; // token used to create bond
    ITreasury public treasury; // mints D33D when receives principle
    IStaking public staking; // to auto-stake payout
    address public DAO;
    address public admin;
    address internal _trustedForwarder;

    bool public isLiquidityBond; // LP and Reserve bonds are treated slightly different
    IBondCalc public bondCalc; // calculates value of LP tokens

    uint public totalDebt; // total value of outstanding bonds; used for pricing
    uint public lastDecay; // reference block for debt decay

    struct Terms {
        uint controlVariable; // scaling variable for price
        uint vestingTerm; // in times
        uint minimumPrice; // vs principle value
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint maxDebt; // 18 decimal debt ratio, max % total supply created as debt
    }
    Terms public terms; // stores terms for new bonds

    // Info for bond holder
    struct Bond {
        uint payout; // D33D remaining to be paid
        uint vesting; // Times left to vest
        uint lastTimestamp; // Last interaction
        uint pricePaid; // In USD, for front end viewing
    }
    mapping(address => Bond) public bondInfo; // stores bond information for depositors

    // Info for incremental adjustments to control variable 
    struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint buffer; // minimum length (in seconds) between adjustments
        uint lastTimestamp; // block timestamp when last adjustment made
    }
    Adjust public adjustment; // stores adjustment to BCV data

    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );

    modifier onlyAdmin {
        require(msg.sender == admin, "Only admin");
        _;
    }

    function initialize(
        IERC20Upgradeable _D33D,
        IPrinciple _principle,
        ITreasury _treasury,
        address _DAO,
        IBondCalc _bondCalc,
        IStaking _staking,
        address _admin,
        address _trustedForwarderAddress
    ) external virtual initializer {
        D33D = _D33D;
        principle  = _principle;
        treasury = _treasury;
        bondCalc = _bondCalc;
        staking = _staking;
        DAO = _DAO;
        admin = _admin;
        _trustedForwarder = _trustedForwarderAddress;

        isLiquidityBond = address(_bondCalc) != address(0);
        principle.safeApprove(address(_treasury), type(uint).max);
        D33D.safeApprove(address(_staking), type(uint).max);
    }

    function initializeBondTerms( 
        uint _controlVariable, 
        uint _vestingTerm,
        uint _minimumPrice,
        uint _maxPayout,
        uint _fee,
        uint _maxDebt,
        uint _initialDebt
    ) external virtual onlyAdmin() {
        require( terms.controlVariable == 0, "Bonds must be initialized from 0" );
        terms = Terms ({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = block.timestamp;
    }

    /**
        @notice Function to deposit principleToken. Principle token is deposited to treasury
        and D33D is minted. The minted D33D is vested for a specific time.
        @param _amount quantity of principle token to deposit
        @param _maxPrice Used for slippage handling. Price in terms of principle token.
        @param _depositor address of User to receive bond D33D
     */
    function deposit(
        uint _amount, 
        uint _maxPrice,
        address _depositor
    ) external payable virtual returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );

        decayDebt();
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = treasury.valueOf( address(principle), _amount );
        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 1e16, "Bond too small" ); // must be > 0.01 D33D ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage


        if (msg.value == 0) {
            principle.safeTransferFrom( _msgSender(), address(this), _amount );
        } else {
            require(_amount == msg.value, "Invalid ETH");
            principle.deposit{value: msg.value}();
        }
        treasury.deposit( _amount, address(principle), payout );

        // profits are calculated
        if (terms.fee > 0) {
            uint fee = payout * terms.fee / 10000;
            payout -= fee;
            D33D.safeTransfer( DAO, fee ); // fee is transferred to DAO
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
        emit BondCreated( _amount, payout, block.timestamp + terms.vestingTerm, priceInUSD );
        emit BondPriceChanged( bondPriceInUSD(), bondPrice(), debtRatio() );

        adjust(); // control variable is adjusted
        return payout; 
    }

    /**
        @notice Function to redeem/stake the vested D33D.
        @param _recipient Address to redeem
        @param _stake Whether to stake/redeem the vested D33D
     */
    function redeem( address _recipient, bool _stake ) external virtual returns ( uint ) {        
        Bond memory info = bondInfo[ _recipient ];
        uint percentVested = percentVestedFor( _recipient ); // (blocks since last interaction / vesting term remaining)


        if ( percentVested >= 10000 ) { // if fully vested
            delete bondInfo[ _recipient ]; // delete user info
            emit BondRedeemed( _recipient, info.payout, 0 ); // emit bond data
            return stakeOrSend( _recipient, _stake, info.payout ); // pay user everything due

        } else { // if unfinished
            // calculate payout vested
            uint payout = info.payout * percentVested / 10000;

            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout - payout,
                vesting: info.vesting - ( block.timestamp - info.lastTimestamp ),
                lastTimestamp: block.timestamp,
                pricePaid: info.pricePaid
            });

            emit BondRedeemed( _recipient, payout, bondInfo[ _recipient ].payout );
            return stakeOrSend( _recipient, _stake, payout );
        }
    }

    function stakeOrSend( address _recipient, bool _stake, uint _amount ) internal virtual returns ( uint ) {
        if ( !_stake ) { // if user does not want to stake
            D33D.safeTransfer( _recipient, _amount ); // send payout
        } else { // if user wants to stake
            staking.stake( _amount, _recipient );
        }
        return _amount;
    }

    /**
     *  @notice calculate amount of D33D available for claim by depositor
     *  @param _depositor address of depositor
     *  @return pendingPayout_ quantity of D33D that can be redeemed
     */
    function pendingPayoutFor( address _depositor ) external virtual view returns ( uint pendingPayout_ ) {
        uint percentVested = percentVestedFor( _depositor );
        uint payout = bondInfo[ _depositor ].payout;

        if ( percentVested >= 10000 ) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout * percentVested / 10000;
        }
    }

    /**
        @notice Function to increase or decrease the BCV
        @param _addition To increase/decrease the BCV. True to increase 
        @param _increment Rate of increase per _buffer
        @param _target Target BCV
        @param _buffer Minimum time between adjustment
     */
    function setAdjustment ( 
        bool _addition,
        uint _increment, 
        uint _target,
        uint _buffer 
    ) external virtual onlyAdmin() {
        require( _increment <= terms.controlVariable * 25 / 1000, "Increment too large" );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastTimestamp: block.timestamp
        });
    }

    enum PARAMETER { VESTING, PAYOUT, FEE, DEBT }
    /// @notice set parameters for new bonds
    function setBondTerms ( PARAMETER _parameter, uint _input ) external virtual onlyAdmin() {
        if ( _parameter == PARAMETER.VESTING ) { // 0
            require( _input >= 129600, "Vesting must be longer than 36 hours" );
            terms.vestingTerm = _input;
        } else if ( _parameter == PARAMETER.PAYOUT ) { // 1
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.FEE ) { // 2
            require( _input <= 10000, "DAO fee cannot exceed payout" );
            terms.fee = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 3
            terms.maxDebt = _input;
        }
    }

    /// @notice makes incremental adjustment to control variable
    function adjust() internal virtual {
        uint blockCanAdjust = adjustment.lastTimestamp + adjustment.buffer;
        if( adjustment.rate != 0 && block.timestamp >= blockCanAdjust ) {
            uint initial = terms.controlVariable;
            if ( adjustment.add ) {
                terms.controlVariable = terms.controlVariable + adjustment.rate;
                if ( terms.controlVariable >= adjustment.target ) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable - adjustment.rate;
                if ( terms.controlVariable <= adjustment.target ) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastTimestamp = block.timestamp;
            emit ControlVariableAdjustment( initial, terms.controlVariable, adjustment.rate, adjustment.add );
        }
    }

    /// @notice calculate how far into vesting a depositor is
    function percentVestedFor( address _depositor ) public virtual view returns ( uint percentVested_ ) {
        Bond memory bond = bondInfo[ _depositor ];
        uint timesSinceLast = block.timestamp - bond.lastTimestamp;
        uint vesting = bond.vesting;

        if ( vesting > 0 ) {
            percentVested_ = timesSinceLast * 10000 / vesting;
        } else {
            percentVested_ = 0;
        }
    }

    /// @notice converts bond price to USD value (in principle decimals)
    function bondPriceInUSD() public virtual view returns ( uint price_ ) {
        if( isLiquidityBond ) {
            price_ = bondPrice() * bondCalc.getRawPrice() / 1e18;
        } else {
            price_ = bondPrice() * 10 ** principle.decimals() / 1e18;
        }
    }

    /**
     *  @notice calculate current bond premium
     *  @return price_ price interms of principle token (18 decimals)
     */
    function bondPrice() public virtual view returns ( uint price_ ) {
        price_ = terms.controlVariable * debtRatio();
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value Value in USD (18 decimals)
     *  @return uint quantity of D33D for the value
     */
    function payoutFor( uint _value ) public virtual view returns ( uint ) {
        return _value * 1e18 / bondPrice();
    }

    /// @notice calculate current ratio of debt to D33D supply
    function debtRatio() public virtual view returns ( uint debtRatio_ ) {   
        uint supply = D33D.totalSupply();
        if(supply == 0)return 0;
        debtRatio_ = currentDebt() * 1e18 / supply;
    }

    /// @notice calculate debt factoring in decay
    function currentDebt() public virtual view returns ( uint ) {
        return totalDebt - debtDecay();
    }

    /// @notice reduce total debt
    function decayDebt() internal virtual {
        totalDebt = totalDebt - debtDecay();
        lastDecay = block.timestamp;
    }

    /// @notice amount to decay total debt by
    function debtDecay() public virtual view returns ( uint decay_ ) {
        uint timesSinceLast = block.timestamp - lastDecay;
        decay_ = totalDebt * timesSinceLast / terms.vestingTerm;
        if ( decay_ > totalDebt ) {
            decay_ = totalDebt;
        }
    }

    /// @notice determine maximum bond size
    function maxPayout() public virtual view returns ( uint ) {
        return D33D.totalSupply() * terms.maxPayout / 100000;
    }

    function setStaking(IStaking _staking) external virtual onlyAdmin {
        staking = _staking;        
    }

    function setMinimumPrice(uint _minimumPrice) external virtual onlyAdmin {
        terms.minimumPrice = _minimumPrice;
    }

    function trustedForwarder() public view returns (address){
        return _trustedForwarder;
    }

    function setTrustedForwarder(address _forwarder) external onlyAdmin {
        _trustedForwarder = _forwarder;
    }

    function isTrustedForwarder(address forwarder) public view returns(bool) {
        return forwarder == _trustedForwarder;
    }

    /**
     * return the sender of this call.
     * if the call came through our trusted forwarder, return the original sender.
     * otherwise, return `msg.sender`.
     * should be used in the contract anywhere instead of msg.sender
     */
    function _msgSender() internal view returns (address ret) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96,calldataload(sub(calldatasize(),20)))
            }
        } else {
            ret = msg.sender;
        }
    }

    function versionRecipient() external pure returns (string memory) {
        return "1";
    }

    uint256[36] private __gap;
}
