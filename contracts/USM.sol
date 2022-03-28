// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract MintableUpgradeable is OwnableUpgradeable {
    
  address internal _minter;

  function __Mintable_init_unchained() internal initializer {
    __Ownable_init();
  }

  function setMinter( address minter_ ) external onlyOwner returns ( bool ) {
    _minter = minter_;

    return true;
  }

  function minter() public view returns (address) {
    return _minter;
  }

  modifier onlyMinter {
    require( _minter == msg.sender, "Mintable: caller is not the minter" );
    _;
  }
}

contract USM is ERC20Upgradeable, MintableUpgradeable {

  mapping(address=>bool) public whitelist;
  uint public transferAmountMax;

  function initialize() external initializer {
    transferAmountMax = 5000e18; // 5k

    __ERC20_init("United States of Metaverse", "USM");
    __Mintable_init_unchained();
  }

  function addWhiltelist(address _account) external onlyOwner {
    if(whitelist[_account] == false) whitelist[_account] = true;
  }

  function removeWhiltelist(address _account) external onlyOwner {
    if(whitelist[_account] == true) delete whitelist[_account];
  }

  function setTransferAmountMax(uint _transferAmountMax) external onlyOwner {
    transferAmountMax = _transferAmountMax;
  }

  function transfer(address recipient, uint256 amount) public override returns (bool) {
    require(amount <= transferAmountMax || whitelist[msg.sender] || whitelist[recipient], "Transfer amount is too large");
    return ERC20Upgradeable.transfer(recipient, amount);
  }

  function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
    require(amount <= transferAmountMax || whitelist[sender] || whitelist[recipient], "Transfer amount is too large");
    return ERC20Upgradeable.transferFrom(sender, recipient, amount);
  }

  function mint(address account_, uint256 amount_) external onlyMinter {
    _mint(account_, amount_);
  }

  function burn(uint256 amount) public virtual {
    _burn(msg.sender, amount);
  }
    
  function burnFrom(address account_, uint256 amount_) public virtual {
    _burnFrom(account_, amount_);
  }

  function _burnFrom(address account_, uint256 amount_) internal virtual {
    uint256 decreasedAllowance_ = allowance(account_, msg.sender) - amount_;
    _approve(account_, msg.sender, decreasedAllowance_);
    _burn(account_, amount_);
  }
}
