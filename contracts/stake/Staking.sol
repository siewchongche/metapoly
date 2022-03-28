// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IStakingToken is IERC20Upgradeable{
    function gonsForBalance(uint _amount) external view returns (uint);
    function balanceForGons(uint _amount) external view returns (uint);
    function circulatingSupply() external view returns (uint);
    function index() external view returns (uint);

    function rebase(uint _profit, uint _epoch) external ;
}

interface IStakingWarmUp {
    function retrieve( address _receiver, uint _amount ) external ;
}

interface IDistributor {
    function distribute() external;
}

interface IUSMMinter {
    function mintWithD33d(uint _D33DAmount, address _to) external returns(uint _usmAmount);
    function getUsmAmountOut(address _token, uint _tokenAmount) view external returns(uint _usmAmount);
}

interface IVD33D is IERC20Upgradeable {
    function mint(address to, uint amount) external;
    function burn(uint amount) external;
}

contract Staking is Initializable, OwnableUpgradeable {

    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IStakingToken;
    using SafeERC20Upgradeable for IVD33D;

    IERC20Upgradeable public D33D;
    IERC20Upgradeable public USM;
    IStakingToken public stakingToken;
    IStakingWarmUp public stakingWarmUp;
    IUSMMinter public usmMinter;
    IVD33D public vD33D;

    address public distributor;    
    address public _trustedForwarder;


    struct Claim {
        uint deposit;
        uint gons;
        // uint expiry;
        // bool lock; // prevents malicious delays
    }
    
    struct Epoch {
        uint length; //epoch length in seconds
        uint number;
        uint timestamp;
        uint distribute;
    }
    Epoch public epoch;

    mapping( address => Claim ) public warmupInfo;
    address public DAO;
    
    uint public USMClaimLimit;

    function initialize(address _trustedForwarderAddress, address _USM, uint _USMClaimLimit) external initializer {
        __Ownable_init();

        _trustedForwarder = _trustedForwarderAddress;
        USMClaimLimit = _USMClaimLimit;

        USM = IERC20Upgradeable(_USM);
    }

    function initializeStaking(IERC20Upgradeable _D33D, IStakingToken _sD33D, address distributor_, address _stakingWarmUp, 
        uint _epochLength, uint _firstEpochNumber,
        uint _firstEpochTimestamp, address _DAO, address _usmMinter, address _vD33D) external onlyOwner {

        require(address(D33D) == address(0), "Already initalized");

        D33D = _D33D;
        stakingToken = _sD33D;
        distributor = distributor_;
        DAO = _DAO;
        usmMinter = IUSMMinter(_usmMinter);
        vD33D = IVD33D(_vD33D);

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            timestamp: _firstEpochTimestamp + _epochLength,
            distribute: 0
        });


        stakingWarmUp = IStakingWarmUp(_stakingWarmUp);

        D33D.safeApprove(_usmMinter, type(uint).max);
        
    }

    ///@notice Function to  deposit D33D. stakingToken will not be trensferred in this function.
    function stake(uint _amount, address _receiver) external returns (bool) {
        address _sender = _msgSender();

        rebase();

        D33D.safeTransferFrom(_sender, address(this), _amount);

        Claim memory info = warmupInfo[ _receiver ];

        warmupInfo[ _receiver ] = Claim ({
            deposit: info.deposit +  _amount ,
            gons: info.gons + stakingToken.gonsForBalance( _amount )
        });

        stakingToken.transfer(address(stakingWarmUp), _amount);
        vD33D.mint(_receiver, _amount);
        return true;

    }

    ///@dev Releases stakingToken after the minimum lockup period
    function claim(address _sender) internal returns (uint amount){

        Claim memory info = warmupInfo[_sender];

        //withdraw deposited D33d (don't withdraw rewards if any). Rewards should have been withdrawn 
        //in previous step(_claimRewards). Any remaining rewards is still there because of USMRewardLimit
        amount = info.deposit;

        warmupInfo[_sender] = Claim({
            deposit: 0,
            gons: info.gons - stakingToken.gonsForBalance(info.deposit) //subtract deposited amount equivalent gons. 
            //Remaining if any is the rewards(rewards > usmRewardLimit).
        });

        stakingWarmUp.retrieve(address(this), amount);
        
    }

    /// @notice Claims D33D and stakes again. Users will receive vD33D
    function claimAndStakeD33D() external {
        _claimRewards(_msgSender(), false);
    }

    /// @notice Collects rewards in USM by burning rewards in D33D within this contract
    function claimRewards() external {
        _claimRewards(_msgSender(), true);
    }

    function _claimRewards(address _sender, bool asUSM) internal {
        Claim memory info = warmupInfo[_sender];
        //difference in deposited amount and current sTOKEN amount are the rewards
        uint _amount = stakingToken.balanceForGons( info.gons ); //check before changing this var. Used below again
        uint rewards = _amount - info.deposit;

        if(rewards > 0) {

            if(asUSM) {
                uint diff;
                uint maxD33d = USMClaimLimit * 1e18 / usmMinter.getUsmAmountOut(address(D33D), 1e18);

                if(rewards > maxD33d) {
                    diff = rewards - maxD33d;
                    // rewards = rewards - diff;
                    rewards = maxD33d;
                }

                stakingWarmUp.retrieve(address(this), rewards);
                warmupInfo[_sender].gons = stakingToken.gonsForBalance( info.deposit + diff );

                usmMinter.mintWithD33d(rewards, _sender);
            } else {
                //AutoCompound
                /**
                    1. retrieve reward amount of sD33D
                    2. update warmupInfo.gons to gonsForBalance(info.deposit) -> To collect the rewards
                    3. update warmupInfo.deposit to info.deposit + gonsForBalance(rewards)
                    4. transfer same amount of retrieved sD33D in step 1 back to staking warmup

                    we ignore step1 and step4 to save gas
                */

                warmupInfo[_sender].gons = stakingToken.gonsForBalance(info.deposit); //collects rewards
                warmupInfo[_sender].deposit = _amount;
                vD33D.mint(_sender, rewards);


            }

        }
    }

    ///@notice Returns all the staked D33D + USM rewards 
    /// #if_succeeds {:msg "Should not withdraw more/less than deposited"} old(warmupInfo[_msgSender()].deposit) == _D33DAmt;
    function unStake(bool _trigger) external returns (uint _D33DAmt){
        address _sender = _msgSender();
        if(_trigger == true) {
            rebase();
        }

        _claimRewards(_sender, true); // user receives USM rewards

        _D33DAmt = claim(_sender);
        if(_D33DAmt > 0) {
            vD33D.safeTransferFrom(_sender, address(this), _D33DAmt); //D33D and vD33D are 1:1
            vD33D.burn(_D33DAmt);

            D33D.safeTransfer( _sender, _D33DAmt );
        }
    }

    /// @notice trigger rebase if epoch over
    function rebase() public {
        if(epoch.timestamp <= block.timestamp) {
            stakingToken.rebase(epoch.distribute, epoch.number);

            epoch.timestamp = epoch.timestamp + epoch.length;

            epoch.number++;

            IDistributor( distributor ).distribute();

            uint balance = D33D.balanceOf(address(this));
            uint staked = stakingToken.circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance -  staked;
            }
        }
    }

    function adjustRewardLimit(uint _limit) external onlyOwner {
        USMClaimLimit = _limit;
    }

    /// @notice returns the sD33D index, which tracks rebase growth
    function index() public view returns ( uint ) {
        return stakingToken.index();
    }


    function trustedForwarder() external view returns (address) {
        return _trustedForwarder;
    }

    function setTrustedForwarder(address _forwarder) external onlyOwner {
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
    function _msgSender() internal override view returns (address ret) {
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
}