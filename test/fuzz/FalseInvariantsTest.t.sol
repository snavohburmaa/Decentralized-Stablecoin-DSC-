// //SPDX-License-Identifier: MIT

// // //total supply of DSC < total value of collateral
// // //getter func should never revert <= evergreeen invariant

// // //fail_on_revert = false

// pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// contract InvariantsTest is Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,, weth, wbtc, ) = config.activeNetworkConfig();

//         targetContract(address(dsce));
//     }

//     //get value of all collateral in the protocol
//     //compare it to all the debt (dsc)
//     //totalValue => pouk zyy = 1000$ , totalSuply => amount that user get => 500$
//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 totalWethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 totalBtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

//         assert(totalWethValue + totalBtcValue >= totalSupply);
//     }
// }
