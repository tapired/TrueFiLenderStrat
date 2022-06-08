// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/IPool.sol";
import "../interfaces/IGauge.sol";
import "../interfaces/IUnirouter.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";
import {ITradeFactory} from "./ySwap/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // gauge is constant and same for all pools
    IGauge public constant gauge =
        IGauge(0xec6c3FD795D6e6f202825Ddb56E01b3c128b0b10);
    IERC20 public constant tru =
        IERC20(0x4C19596f5aAfF459fA38B0f7eD92F11AE6543784);
    address public constant unirouter =
        address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    address[] public swapPath;
    IPool public pool;
    address public tradeFactory = address(0);

    constructor(
        address _vault,
        address _pool,
        address[] memory _swapPath
    ) public BaseStrategy(_vault) {
        pool = IPool(_pool);
        require(pool.token() == want);
        _checkPath(_swapPath);
        swapPath = _swapPath;

        IERC20(address(pool)).approve(address(gauge), type(uint256).max);
        want.approve(address(pool), type(uint256).max);
        tru.approve(unirouter, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyTruLender",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfWantInGauge() public view returns (uint256) {
        return (balanceOfLPInGauge().mul(getVirtualPrice())).div(1e18);
    }

    function _balanceOfLP() internal view returns (uint256) {
        return IERC20(address(pool)).balanceOf(address(this));
    }

    function balanceOfLPInGauge() public view returns (uint256) {
        return gauge.staked(IERC20(address(pool)), address(this));
    }

    function totalLP() public view returns (uint256) {
        return _balanceOfLP().add(balanceOfLPInGauge());
    }

    function totalLPtoWant() public view returns (uint256) {
        return (totalLP().mul(getVirtualPrice())).div(1e18);
    }

    function getVirtualPrice() public view returns (uint256) {
        return (pool.poolValue().mul(1e18)).div(pool.totalSupply());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return totalLPtoWant().add(balanceOfWant());
    }

    // pending TRU rewards in gauge
    function pendingRewards() public view returns (uint256) {
        return gauge.claimable(IERC20(address(pool)), address(this));
    }

    function balanceOfTruRewards() public view returns (uint256) {
        return tru.balanceOf(address(this));
    }

    // LP positions penalty fee in terms of want
    function exitPenaltyFeeLP(uint256 _amount) public view returns (uint256) {
        return (10_000 - pool.liquidExitPenalty(_amount)).mul(_amount) / 10_000;
    }

    // LP positions penalty fee in terms of LP
    function exitPenaltyFeeWant(uint256 _amount) public view returns (uint256) {
        uint256 lpLoss =
            (10_000 - pool.liquidExitPenalty(_amount)).mul(_amount) / 10_000;

        return (lpLoss.mul(getVirtualPrice())).div(1e18);
    }

    function setSwapPath(address[] memory _swapPath)
        external
        onlyVaultManagers
    {
        _checkPath(_swapPath);
        swapPath = _swapPath;
    }

    function _checkPath(address[] memory _swapPath) internal {
        require(address(tru) == _swapPath[0], "illegal path!");
        require(
            address(want) == _swapPath[_swapPath.length - 1],
            "illegal path!"
        );
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 assets = estimatedTotalAssets();
        if (debt > assets) {
            _loss = debt.sub(assets);
        } else {
            _profit = assets.sub(debt);
        }

        uint256 toLiquidate = _debtOutstanding.add(_profit);
        if (toLiquidate > 0) {
            (uint256 _amountFreed, uint256 _withdrawalLoss) =
                liquidatePosition(toLiquidate);
            _debtPayment = Math.min(_debtOutstanding, _amountFreed);
            _loss = _loss.add(_withdrawalLoss);
        }

        // net out PnL
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    function _claimRewards() internal {
        if (pendingRewards() > 0) {
            IERC20[] memory tmp = new IERC20[](1);
            tmp[0] = IERC20(address(pool));
            gauge.claim(tmp);
        }
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    function _swapRewardToWant() internal {
        uint256 rewards = tru.balanceOf(address(this));
        if (rewards > 0) {
            IUnirouter(unirouter).swapExactTokensForTokens(
                rewards,
                0,
                swapPath,
                address(this),
                block.timestamp
            );
        }
    }

    function swapRewardToWant() external onlyVaultManagers {
        _swapRewardToWant();
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            // supply to the pool get LP
            pool.join(wantBalance.sub(_debtOutstanding));
        }
        if (_balanceOfLP() > 0) {
            // stake LP to earn TRU
            gauge.stake(IERC20(address(pool)), _balanceOfLP());
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds

        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        _withdrawSome(amountRequired);
        uint256 freeAssets = balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function _withdrawSome(uint256 _amountWant) internal {
        // _amounWant / virtualPrice
        // we are withdrawing "_amountWant" amount of want worth LP + penaltyFee of "_amountWant" LP
        uint256 actualWithdrawn =
            Math.min(
                ((_amountWant.mul(1e18)).div(getVirtualPrice())),
                balanceOfLPInGauge()
            );
        gauge.unstake(IERC20(address(pool)), actualWithdrawn);
        pool.liquidExit(actualWithdrawn);
    }

    function liquidateAllPositions() internal override returns (uint256) {
        IERC20[] memory tmp = new IERC20[](1);
        tmp[0] = IERC20(address(pool));
        gauge.exit(tmp);
        pool.liquidExit(_balanceOfLP());
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        if (balanceOfLPInGauge() > 0) {
            IERC20[] memory tmp = new IERC20[](1);
            tmp[0] = IERC20(address(pool));
            // exit claims rewards and unstake all LP
            gauge.exit(tmp);
            pool.liquidExit(_balanceOfLP());
        }
        tru.safeTransfer(_newStrategy, tru.balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }


    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        tru.safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(tru), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        tru.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

}
