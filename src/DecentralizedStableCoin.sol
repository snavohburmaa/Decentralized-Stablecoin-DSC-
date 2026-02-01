//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title DecentralizedStableCoin
 * @author OhBurmaa
 * Collateral: exogenous (ETH & BTC)
 * Minting : Algorithmic
 * Relative Stability: Pegged to USD
 * 
 * This is the contract ment to be governed by DSCEngine
 * just ERC20 implementation of stablecoin system
 */

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountMustBeLessThanBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20 ("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn (uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if(_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        if(balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountMustBeLessThanBalance();
        }
        super.burn(_amount);
    }

    function mint (address _to,uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }   
}