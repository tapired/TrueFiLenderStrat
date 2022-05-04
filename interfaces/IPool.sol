// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IPool {
   function token() external view returns (IERC20 _token);
   function decimals() external  view returns (uint8) ;
   function balanceOf(address account) external view returns (uint256);
   function totalSupply() external view returns (uint256);
   function poolValue() external view returns (uint256);
   function join(uint256 amount) external;
   function collectFees() external ;
   function liquidExit(uint256 amount) external;
   function liquidExitPenalty(uint256 amount) external view returns (uint256);
}
