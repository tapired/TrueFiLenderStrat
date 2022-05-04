// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGauge {
    struct Rewards {
        // track overall cumulative rewards
        uint256 cumulativeRewardPerToken;
        // track previous cumulate rewards for accounts
        mapping(address => uint256) previousCumulatedRewardPerToken;
        // track claimable rewards for accounts
        mapping(address => uint256) claimableReward;
        // track total rewards
        uint256 totalClaimedRewards;
        uint256 totalRewards;
    }
    function staked(IERC20 token, address staker) external view returns (uint256);
    function stake(IERC20 token, uint256 amount) external;
    function unstake(IERC20 token, uint256 amount) external ;
    function claim(IERC20[] calldata tokens) external;
    function exit(IERC20[] calldata tokens) external;
    function claimable(IERC20 token, address account) external view returns (uint256);
}
