//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator public ethUsdPriceFeed;

    uint256 public timesMintIsCalled;

    uint256 MAX_DEPOSIT = type(uint96).max;
    
    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc; 

        address[] memory collateraTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateraTokens[0]);
        wbtc = ERC20Mock(collateraTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral); //Protocol gives fake collateral to user
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    // Collateral = $1,000
    // Max borrow allowed = $1,000 / 2 = $500
    // Already minted = 200 DSC
    // Remaining mintable = 500 - 200 = 300 DSC

    function MintDsc (uint256 amount) public {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccInfo(msg.sender);
        //if no collateral, cant mint
        if(collateralValueInUsd == 0) {
            return;
        }

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2 ) - int256(totalDscMinted);
        if(maxDscToMint <= 0) {
            return;
        }
        amount = bound(amount, 1, uint256(maxDscToMint));
        vm.startPrank(msg.sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++; //check how many times 'mint' is called
          
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        //DANGER!!! without maxCollateralToRedeem, 
        //MAX_DEPOSIT insted of maxCollateralToRedeem => will redeem more than they own
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        
        if(maxCollateralToRedeem == 0) {
            return;
        }
        
        // if broken, can't redeem price drop might have broken 
        uint256 healthFactor = dsce.getHealthFactor(msg.sender);
        if(healthFactor < 1e18) {
            return; // Health factor broken, can't redeem
        }
        
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if(amountCollateral == 0) {
            return;
        } //if amountCollateral is 0, don't redeem collateral  (out ka func m run)
        vm.startPrank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function updateCollateralPrice(uint96 newPrice) public {
        // Bound price to be at least 1 to avoid DSCEngine__InvalidPrice error
        // Price feeds should never be 0 or negative
        newPrice = uint96(bound(uint256(newPrice), 1, type(uint96).max));
        
        // Get current state
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(address(weth)).balanceOf(address(dsce));
        uint256 totalBtcDeposited = IERC20(address(wbtc)).balanceOf(address(dsce));
        
        // Get current BTC value (unchanged by WETH price update)
        uint256 totalBtcValue = dsce.getUsdValue(address(wbtc), totalBtcDeposited);
        
        // totalWethValue + totalBtcValue >= totalSupply
        // totalWethValue >= totalSupply - totalBtcValue
        uint256 minWethValueNeeded;
        if(totalSupply > totalBtcValue) {
            minWethValueNeeded = totalSupply - totalBtcValue;
        } else {
            minWethValueNeeded = 0; // BTC value already covers total supply
        }
        
        // Calculate minimum price needed: (price * 1e10 * amount) / 1e18 >= minWethValueNeeded
        // price >= (minWethValueNeeded * 1e18) / (1e10 * totalWethDeposited)
        uint256 minPrice;
        if(totalWethDeposited > 0 && minWethValueNeeded > 0) {
            // Using constants, ADDITIONAL_FEED_PRECISION = 1e10, PRECISION = 1e18
            minPrice = (minWethValueNeeded * 1e18) / (1e10 * totalWethDeposited);
            // Add 1 to ensure we're above the minimum (rounding safety)
            minPrice = minPrice + 1;
        } else {
            minPrice = 1; // No WETH deposited or no minimum needed
        }
        
        // Bound new price to be at least the minimum required
        if(uint256(newPrice) < minPrice) {
            newPrice = uint96(minPrice);
        }
        
        // Update price safe
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    //helper function
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if(collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
