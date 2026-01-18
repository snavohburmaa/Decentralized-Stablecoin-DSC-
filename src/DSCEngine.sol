//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title DSCEngine
 * @author OhBurmaa
 * System is designed to be minimal as possible, and have the token maintainn a 1 token == 1 USD peg
 * This stablecoin ahs propertie:
 * - EXOGENOUS COLLATERAL
 *  - DOLLAR PEGGED 
 *  - ALGORITHMICALLY STABLE 
 * It's similar to DAI if DAI has no governance, no fees, and was only backed by wETH and wBTC 
 * always lock more value than the DSC we create, so the system stays safe
 * @notice this contract is the core of the DSC system, handle all the logics for mining and 
 * redeeming DSC, as well as depositing n withdrawing collateral.
 * @notice this contract is very loosely based on the MakerDAO DSS(DAI) system 
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

///////////////////////////////////////////////////////////////////////////////////////////////////////////
contract DSCEngine is ReentrancyGuard {
    //Errors
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAndPricFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 userHealthFactor);
    error DSCEngine__InvalidPrice();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__InsufficientDscBalance();

    using OracleLib for AggregatorV3Interface;

//////////////////////////////////////////////////////////////////////////////////////////////////////////

    mapping(address token => address priceFeed) private s_priceFeeds; // token to priceFeed
    mapping(address user => mapping(address token => uint256 amount)) 
        private s_collateralDeposited; // user to token to amount deposited
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // user to amount DSC minted
    address[] private s_collateralTokens; // array of collateral tokens

    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10% bonus

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Modifier
    //1. collateral amount must greater than zero
    modifier moreThanZero(uint256 amount) {
        if(amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }
    //2. token must be allowed, can use that token as collateral or not?
    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //3. liquidator must have enough DSC balance and approval
    modifier hasEnoughDscBalance(address liquidator, uint256 amountDscToCover) {
        uint256 liquidatorDscBalance = i_dsc.balanceOf(liquidator);
        if(liquidatorDscBalance < amountDscToCover) {
            revert DSCEngine__InsufficientDscBalance();
        }
        uint256 liquidatorAllowance = i_dsc.allowance(liquidator, address(this));
        if(liquidatorAllowance < amountDscToCover) {
            revert DSCEngine__TransferFailed();
        }
        _;
    }

////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress //Dsc engine is not dsc contract, so need to pass address of dsc contract
    ) {
        //USD Price Feed Address
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPricFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    //deposit + mint DSC
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    //tokenCollateralAddres is the address of token to deposit as collateral
    //amountCollateral is the amount of collateral to deposit
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if mint too much($150DSC, $100ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

////////////////////////////////////////////////////////////////////////////////////////////////////////
    //redeem + burn DSC
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) 
        external {
            _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
            _burnDsc(amountDscToBurn, msg.sender, msg.sender);
         } 

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    //health factor must be over 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
            _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
            _revertIfHealthFactorIsBroken(msg.sender);
        }

/////////////////////////////////////////////////////////////////////////////////////////////////////////  

    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external moreThanZero(debtToCover) hasEnoughDscBalance(msg.sender, debtToCover) nonReentrant {
            uint256 startingUserHealthFactor = _healthFactor(user);
            if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
                revert DSCEngine__HealthFactorOk();
            }
            uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
            //give 10% bonus
            uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
            uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
            _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

            _burnDsc(debtToCover, user, msg.sender);

            uint256 endingHealthFactor = _healthFactor(user);
            if(endingHealthFactor <= startingUserHealthFactor) {
                revert DSCEngine__HealthFactorNotImproved();
            }
            _revertIfHealthFactorIsBroken(user);
        }

/////////////////////////////////////////////////////////////////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) public pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }


/////////////////////////////////////////////////////////////////////////////////////////////////////////
                //private and internal view               
                
    function _getAccountInformation(address user) private view returns (
        uint256 totalDscMinted, uint256 collateralValueInUsd) {
            totalDscMinted = s_DSCMinted[user];
            collateralValueInUsd = getAccountCollateralValue(user);
        }

////////////////////////////////////////////////  
    function _redeemCollateral(address from,address to, address tokenCollateralAddress, uint256 amountCollateral) 
        private {
            s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
            emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
        }

////////////////////////////////////////////////  
 
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

////////////////////////////////////////////////
    //how close to liquidation?
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if(totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; //take half, make safe
        return(collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // return (collateralValueInUsd / totalDSCMinted);
    }
    
////////////////////////////////////////////////

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns (uint256) {
        if(totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; //take half, make safe
        return(collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

        //1. check Health Factor(enough collateral?)
        //2. if health factor is broken, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////
                   //Public and external view functions

    //loop each collateral token, get amount they deposited
    //map to price and get USD
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }


///////////////////////////////////////  
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        if(price <= 0) {
            revert DSCEngine__InvalidPrice();
        }
      
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

////////////////////////////////////// 
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

//////////////////////////////////////  
    function getAccInfo(address user) external view returns(
        uint256 totalDscMinted, uint256 collateralValueInUsd) {
            (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
        }

/////////////////////////////////////
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralPriceFeed(address token) external view returns(address) {
        return s_priceFeeds[token];
    }

    function getDsc() external view returns(address) {
        return address(i_dsc);
    }

/////////////////////////////////////
} 