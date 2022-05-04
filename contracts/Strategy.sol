// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/IPool.sol";
import "../interfaces/IGauge.sol";
import "../interfaces/IUnirouter.sol";
import "@openzeppelin/contracts/math/Math.sol";

// These are the core Yearn libraries
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

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

// TODO: Follow factory pattern for cheaper deployment using clones
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // gauge is constant and same for all pools
    IGauge public constant gauge =
    IGauge(0xec6c3FD795D6e6f202825Ddb56E01b3c128b0b10);
    address public constant tru =
    address(0x4C19596f5aAfF459fA38B0f7eD92F11AE6543784);
    address public constant unirouter =
    address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    address[] public swapPath;
    IPool public pool;

    constructor(
        address _vault,
        address _pool,
    // TODO: move swappath setting to its own method
        address[] memory _swapPath
    ) public BaseStrategy(_vault) {
        pool = IPool(_pool);
        require(pool.token() == want);
        require(_checkPath(_swapPath));
        swapPath = _swapPath;

        IERC20(address(pool)).approve(address(gauge), type(uint256).max);
        want.approve(address(pool), type(uint256).max);
        IERC20(tru).approve(unirouter, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyTrueFiLender";
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // TODO: need to div by decimals of virtualPrice?
    function balanceOfWantInGauge() public view returns (uint256) {
        return _balanceOfLPInGauge().mul(getVirtualPrice());
    }

    function _balanceOfLP() internal view returns (uint256) {
        return IERC20(address(pool)).balanceOf(address(this));
    }

    function _balanceOfLPInGauge() public view returns (uint256) {
        return gauge.staked(IERC20(address(pool)), address(this));
    }

    function _totalLP() internal view returns (uint256) {
        return _balanceOfLP().add(_balanceOfLPInGauge());
    }

    // TODO: Divide by virtualPrice decimals
    function totalLPtoWant() public view returns (uint256) {
        return (_totalLP().mul(getVirtualPrice())).div(10 ** 6);
    }

    // TODO: pool.decimals() is uint8, you likely need to cast this into uint256 for the math to work out.
    // TODO: I recommend multiplying by higher number for higher precision. Use either 1e18 or 1e36. Think of virtualPrice as a conversion rate in %
    // for some reason I need to hardcode the decimals as 10**6 or its not working the way I want to
    // pool.decimals() not working ?
    function getVirtualPrice() public view returns (uint256) {
        return (pool.poolValue().mul(10 ** 6)).div(pool.totalSupply());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return totalLPtoWant().add(balanceOfWant());
    }

    // pending TRU rewards in gauge
    function pendingRewards() public view returns (uint256) {
        return gauge.claimable(IERC20(address(pool)), address(this));
    }

    // TODO: Reading their contract, looks like the param for this is in units of underlying token
    // total LP positions penalty fee
    function exitPenaltyFee() public view returns (uint256) {
        return pool.liquidExitPenalty(_totalLP());
    }

    function setSwapPath(address[] memory _swapPath)
    external
    onlyVaultManagers
    {
        require(_checkPath(_swapPath));
        swapPath = _swapPath;
    }

    function _checkPath(address[] memory _swapPath)
    internal
    view
    returns (bool)
    {
        require(address(tru) == _swapPath[0], "illegal path!");
        require(
            address(want) == _swapPath[_swapPath.length - 1],
            "illegal path!"
        );
        return true;
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
        _claimRewards();
        _swapRewardToWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 eta = estimatedTotalAssets();
        if (debt > eta) {
            _loss = debt.sub(eta);
        } else {
            _profit = eta.sub(debt);
        }

        uint256 toLiquidate = _debtOutstanding.add(_profit);
        if (toLiquidate > 0) {
            uint256 _amountFreed;
            uint256 _withdrawalLoss;
            (_amountFreed, _withdrawalLoss) = liquidatePosition(toLiquidate);
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
        // thats an ugly way to claim rewards
        if (pendingRewards() > 0) {
            IERC20[] memory tmp = new IERC20[](1);
            tmp[0] = IERC20(address(pool));
            gauge.claim(tmp);
        }
    }

    function _swapRewardToWant() internal {
        uint256 rewards = IERC20(tru).balanceOf(address(this));
        if (rewards > 0) {
            IUnirouter(unirouter).swapExactTokensForTokens(
                rewards,
                0,
                swapPath,
                address(this),
                block.timestamp + 120
            );
        }
    }

    // TODO: change to onlyVaultManagers
    function claimFees() external onlyKeepers {
        _claimFees();
    }

    // TODO: Question: What fees are you claiming here by exiting and re-entering your entire position?
    function _claimFees() internal {
        uint256 allPositionsBefore = estimatedTotalAssets();
        gauge.unstake(IERC20(address(pool)), _balanceOfLPInGauge());
        // TODO: Wouldn't this part incur withdrawal fee everytime? Doesn't seem worth it
        pool.liquidExit(_balanceOfLP());
        pool.join(balanceOfWant());
        gauge.stake(IERC20(address(pool)), _balanceOfLP());

        // make sure we make profit if not then function reverts
        require(
            estimatedTotalAssets() > allPositionsBefore,
            "fees not covering exit fee"
        );
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: since this strategy has withdraw penalty, I would recommend only depositing amount (want - _debtOutstanding)
        uint256 wantBal = balanceOfWant();
        if (balanceOfWant() > 0) {
            // supply to the pool get LP
            pool.join(wantBal);
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
        // we are withdrawing "_amountWant" amount of want worth LP
        uint256 actualWithdrawn =
        Math.min(
            ((_amountWant.mul(10 ** 6)).div(getVirtualPrice())),
            _balanceOfLPInGauge()
        );
        gauge.unstake(IERC20(address(pool)), actualWithdrawn);
        pool.liquidExit(actualWithdrawn);
    }

    function liquidateAllPositions() internal override returns (uint256) {
        require(emergencyExit);
        IERC20[] memory tmp = new IERC20[](1);
        tmp[0] = IERC20(address(pool));
        // TODO: question: What's the difference between gauge.exit and gauge.unstake?
        gauge.exit(tmp);
        pool.liquidExit(_balanceOfLP());
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        if (_balanceOfLPInGauge() > 0) {
            IERC20[] memory tmp = new IERC20[](1);
            tmp[0] = IERC20(address(pool));
            gauge.exit(tmp);
            // TODO: Pool token is IERC20 (transferable), don't need to fully exit and incur penalty
            pool.liquidExit(_balanceOfLP());
        }
        // TODO: transfer pool tokens outside of dependence on balance of lpInGauge
        IERC20(tru).safeTransfer(
            _newStrategy,
            IERC20(tru).balanceOf(address(this))
        );
    }


    // TODO: Opinion: leave this whole method blank so gov can sweep everything. This is a blocker during emergencies
    function protectedTokens()
    internal
    view
    override
    returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(pool);
        protected[1] = tru;
    }

    function ethToWant(uint256 _amtInWei)
    public
    view
    virtual
    override
    returns (uint256)
    {
        return _amtInWei;
    }
}
