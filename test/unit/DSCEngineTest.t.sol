//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce; 
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    address public LIQUIDATED_USER = makeAddr("liquidatedUser");
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant STARTING_ERC20_BALANCE = 10e18;
    uint256 public constant MINT_AMOUNT = 100e18;

    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant INITIAL_MINTED_DSC = 800e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }
//-------------------------------------------------------------------------------------------------------------// 

    //modifiers

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositAndMint() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
        _;
    }
//---------------------------------------------------------------------------------------------------------------//
    //constructor test 

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testGetTokenLengthNotMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        
        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPricFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //isAllowToken

    function testRevertUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("Random Token", "RANDOM", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

//---------------------------------------------------------------------------------------------------------------//

      // price test
    
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsdValue = dsce.getUsdValue(weth, ethAmount);
        assert(actualUsdValue == expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usd = 100e18;
        uint256 expectedWeth = 0.05e18;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usd);
        assert(actualWeth == expectedWeth);
    }

//---------------------------------------------------------------------------------------------------------------//
 
//----------------------------------------------------------------------------------------------------------------//

     // moreThanZero modifier tests

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }
    
    function testRevertIfMintDscAmountZero() public depositCollateral {
        vm.startPrank(USER);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertIfBurnDscAmountZero() public depositCollateral {
        vm.startPrank(USER);
        // Mint some DSC first so we can burn it
        dsce.mintDsc(100e18);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertIfRedeemCollateralZero() public depositCollateral {
        vm.startPrank(USER);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfLiquidateDebtToCoverIsZero() public {
        // Create a user that can be liquidated
        vm.startPrank(LIQUIDATED_USER);
        ERC20Mock(weth).mint(LIQUIDATED_USER, 1e18);
        ERC20Mock(weth).approve(address(dsce), 1e18);
        dsce.depositCollateral(weth, 1e18);
        dsce.mintDsc(500e18); // This will likely make them undercollateralized
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(1000e18); // Mint DSC through DSCEngine instead of directly
        dsc.approve(address(dsce), 1000e18);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.liquidate(weth, LIQUIDATED_USER, 0);
        vm.stopPrank();
    }

    function testRevertIfDepositCollateralAndMintDscAmountsAreZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateralAndMintDsc(weth, 0, 0);
        vm.stopPrank();
    }

   // Positive tests for moreThanZero modifier
    
   function testMoreThanZeroModifierAllowsValidAmounts() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        // These should all succeed with valid amounts (moreThanZero modifier should allow them)
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(100e18);
        
        vm.stopPrank();
    } 

//---------------------------------------------------------------------------------------------------------------//
 
    //deposit and mint

    function testDepositCollateralAndMInt() public depositAndMint {
        uint256 userBalance = dsc.balanceOf(USER);
        assert(userBalance == MINT_AMOUNT);

    }

    function testDepositCollateralAndGetAccInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccInfo(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assert(collateralValueInUsd == expectedCollateralValueInUsd); 
        assert(totalDscMinted == expectedTotalDscMinted);  
    }

    function testCorrectDepositTokenAmount () public depositCollateral {
        (, uint256 collateralValueInUsd) = dsce.getAccInfo(USER);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assert(AMOUNT_COLLATERAL == expectedDepositAmount);
    }

    function testMintDsc() public depositCollateral {
        (uint256 totalDscMinted, ) = dsce.getAccInfo(USER);
        vm.startPrank(USER);
        dsce.mintDsc(100e18);
        vm.stopPrank();
        (uint256 newTotalDscMinted, ) = dsce.getAccInfo(USER);
        assert(newTotalDscMinted == totalDscMinted + 100e18);
    }


    function testDepositCollateralWithoutMintDsc() public depositCollateral {
        (uint256 totalDscMinted, ) = dsce.getAccInfo(USER);
        assert(totalDscMinted == 0);
    }

    function testCantMintWithoutDeposit() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBroken.selector, 0));
        dsce.mintDsc(MINT_AMOUNT);
        vm.stopPrank();
    }

    function testRevertIfMintAmountBreakHealthFactor() public depositCollateral {
        (, int256 price, , , ) = AggregatorV3Interface(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint = ((uint256(price) * ADDITIONAL_FEED_PRECISION) * AMOUNT_COLLATERAL) / PRECISION;

        vm.startPrank(USER);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__HealthFactorIsBroken.selector,
                expectedHealthFactor
            )
        );
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    // Burn and redeem Tests  

    function testBurnDscFailsIfInsufficientBalance() public depositCollateral {
        vm.startPrank(USER);
        uint256 amountToMint = 50e18;
        uint256 amountToBurn = 100e18; // More than minted
        
        dsce.mintDsc(amountToMint);
        dsc.approve(address(dsce), amountToBurn);
        
        vm.expectRevert();
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        uint256 UserBalanceBeforeRedeem = dsce.getCollateralBalanceOfUser(USER, weth);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 balanceAfterRedeem = dsce.getCollateralBalanceOfUser(USER, weth);

        assert(UserBalanceBeforeRedeem == AMOUNT_COLLATERAL);
        assert(balanceAfterRedeem == 0);

        vm.stopPrank();
    }

    function testCanRedeemDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(MINT_AMOUNT);  
        // Approve DSC to be burned
        dsc.approve(address(dsce), MINT_AMOUNT);    
        // Redeem collateral and burn DSC in one transaction
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        // Verify DSC was burned
        uint256 userBalance = dsc.balanceOf(USER);
        assert(userBalance == 0);     
        // Verify collateral was redeemed
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        assert(collateralBalance == 0);
        
        vm.stopPrank();
    }

    function testProperlyReportsHealthFactor() public depositAndMint {
        uint256 expectedHealthFactor = 100e18;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        //20000 collateral 50%liquidation, 100 mint
        //20000 * 0.5 = 10000
        //10000/100 = 100 health factor
        assert(healthFactor == expectedHealthFactor);
    }

    function testHealthFactorBelowOne() public depositAndMint {
        int256 ethUsdNewPrice = 2e8; 
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        assert(userHealthFactor == 0.1e18);
    }

    function testLiquidateGivesCorrectBonusToLiquidator() public {
        
        // liquidated user deposit collateral and mint DSC
        vm.startPrank(LIQUIDATED_USER);
        ERC20Mock(weth).mint(LIQUIDATED_USER, AMOUNT_COLLATERAL);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
        
        // liquidator deposit collateral, mint DSC, and approve for liquidation
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(MINT_AMOUNT);
        dsc.approve(address(dsce), MINT_AMOUNT);
        vm.stopPrank();
        
        // Drop price to make liquidated user's health factor < 1
        int256 ethUsdNewPrice = 2e8; // $2 (with 8 decimals)
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);
        
        // liquidated user is liquidatable (health factor < 1)
        uint256 liquidatedUserHealthFactor = dsce.getHealthFactor(LIQUIDATED_USER);

        assert(liquidatedUserHealthFactor < PRECISION);
        
        // Liquidate ALL the debt to ensure health factor improves
        // With 10% bonus, need (100e18 * 1.1) / $2 = 55e18 WETH, but user only has 10e18
        // need more collateral - add more collateral to the liquidated user
        vm.startPrank(LIQUIDATED_USER);
        ERC20Mock(weth).mint(LIQUIDATED_USER, 50e18); // Add more collateral

        ERC20Mock(weth).approve(address(dsce), 50e18);
        dsce.depositCollateral(weth, 50e18);
        vm.stopPrank();
        
        uint256 debtToCover = MINT_AMOUNT; // Cover all 100e18 DSC of debt
        uint256 expectedCollateralFromDebt = dsce.getTokenAmountFromUsd(weth, debtToCover);
        uint256 expectedBonus = (expectedCollateralFromDebt * 10) / 100; // 10% bonus
        
        // expected total collateral to receive
        uint256 expectedTotalCollateral = expectedCollateralFromDebt + expectedBonus;
        
        // before liquidation
        uint256 liquidatorBalanceBefore = ERC20Mock(weth).balanceOf(USER);
        
        // liquidate
        vm.startPrank(USER);
        dsce.liquidate(weth, LIQUIDATED_USER, debtToCover);

        vm.stopPrank();
     
        uint256 liquidatorBalanceAfter = ERC20Mock(weth).balanceOf(USER);
        uint256 actualCollateralReceived = liquidatorBalanceAfter - liquidatorBalanceBefore;
        
        assertEq(actualCollateralReceived, expectedTotalCollateral);
    }
 
    function testRevertLiquidationWhenLiquidatorHasInsufficientDscBalance() public {

        //setup liquidated user
        vm.startPrank(LIQUIDATED_USER);
        ERC20Mock(weth).mint(LIQUIDATED_USER, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();

        //setup liquidator , 100 to cover but only mint 50 DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(50e18); //only mint 50 DSC, not enough
        dsc.approve(address(dsce), MINT_AMOUNT);
        vm.stopPrank();

        //drop price to make liquidated user's health factor < 1
        int256 ethUsdNewPrice = 2e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);

        //verify user is liquidatable
        uint256 liquidatedUserHealthFactor = dsce.getHealthFactor(LIQUIDATED_USER);
        assert(liquidatedUserHealthFactor < PRECISION);

        // liquidator insufficient balance
        uint256 liquidatorDscBalance = dsc.balanceOf(USER);
        assert(liquidatorDscBalance < MINT_AMOUNT);

        //try to liquidate
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__InsufficientDscBalance.selector);
        dsce.liquidate(weth, LIQUIDATED_USER, MINT_AMOUNT);
        vm.stopPrank();      
    }

    function testRevertLiquidationWhenLiquidatorHasNoApproval() public {
        //setup liquidated user
        vm.startPrank(LIQUIDATED_USER);
        ERC20Mock(weth).mint(LIQUIDATED_USER, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
        
        //setup liquidator , mint DSC, not approve
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(MINT_AMOUNT);
        //don't approve
        vm.stopPrank(); 

        //drop price, make liquidated users health factor < 1
        int256 ethUsdNewPrice = 2e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdNewPrice);

        //verify user is liquidatable
        uint256 liquidatedUserHealthFactor = dsce.getHealthFactor(LIQUIDATED_USER);
        assert(liquidatedUserHealthFactor < PRECISION);

        //try to liquidate
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.liquidate(weth, LIQUIDATED_USER, MINT_AMOUNT);
        vm.stopPrank();  

    }

    function testCanRedeemCollateralUpToHealthFactorLimit() public {
     
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(MINT_AMOUNT); // Mint 100e18 DSC
        vm.stopPrank();

        uint256 minCollateralValueInUsd = MINT_AMOUNT * 2; // 200e18 USD
        uint256 minWethNeeded = dsce.getTokenAmountFromUsd(weth, minCollateralValueInUsd);
        uint256 maxRedeemable = AMOUNT_COLLATERAL - minWethNeeded;

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, maxRedeemable);
        vm.stopPrank();
        
        uint256 healthFactorAfter = dsce.getHealthFactor(USER);
        assert(healthFactorAfter >= PRECISION);
    }
} 

