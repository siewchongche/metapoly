// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

contract Token is Initializable, ERC20BurnableUpgradeable {
    uint8 decimal;

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimal_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        decimal = decimal_;
    }

    function decimals() public view override returns (uint8) {
        return decimal;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}
