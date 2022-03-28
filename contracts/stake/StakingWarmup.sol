// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IStaking {
    function stakingToken() external view returns (address);
}
contract StakingWarmup is Initializable, OwnableUpgradeable{

    using SafeERC20Upgradeable for IERC20Upgradeable;

    mapping(address => bool) public isStakingContract;
    mapping(address => address) public stakingToken;

    function initialize() external initializer {
        __Ownable_init();
    }

    function addStakingContract(address stakingContract_) external onlyOwner {
        require(stakingContract_ != address(0), "Invalid staking address");
        
        address _stakingToken = IStaking(stakingContract_).stakingToken();
        isStakingContract[stakingContract_] = true;
        stakingToken[stakingContract_] = _stakingToken;
    }

    function removeStakingContract(address stakingContract_) external onlyOwner {
        require(isStakingContract[stakingContract_] == true, "Not a staking contract");
        
        isStakingContract[stakingContract_] = false;
        stakingToken[stakingContract_] = address(0);
    }

    function retrieve( address _receiver, uint _amount ) external {
        require( isStakingContract[msg.sender] == true, "only StakingContract" );
        IERC20Upgradeable(stakingToken[msg.sender]).safeTransfer( _receiver, _amount );
    }
}