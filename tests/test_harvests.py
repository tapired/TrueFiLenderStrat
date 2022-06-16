import brownie
from brownie import Contract
import pytest
from utils import checks
import test_yswap




def test_multipleharvests(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov, prepare_trade_factory, ymechs_safe, multicall_swapper, unirouter, weth, tru, trade_factory
):
    # Deposit to the vault
    vault.setPerformanceFee(0, {"from":gov})
    vault.setManagementFee(0, {"from":gov})
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    pps_before = vault.pricePerShare()
    print("strategy has", strategy.estimatedTotalAssets())
    print("pps before :" , pps_before)

    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has pendingRewards", strategy.pendingRewards())

    test_yswap.yswap(chain, strategy, token, tru, unirouter, weth, multicall_swapper, ymechs_safe, gov, trade_factory)
    tx = strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has pendingRewards", strategy.pendingRewards())
    test_yswap.yswap(chain, strategy, token, tru, unirouter, weth, multicall_swapper, ymechs_safe, gov, trade_factory)
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has pendingRewards", strategy.pendingRewards())
    test_yswap.yswap(chain, strategy, token, tru, unirouter, weth, multicall_swapper, ymechs_safe, gov, trade_factory)
    strategy.harvest()
    chain.sleep(3600*6)

    pps_after = vault.pricePerShare()
    print("pps after :" , pps_after)
    assert(pps_after > pps_before)

    penaltyFee = strategy.exitPenaltyFeeWant(strategy.totalLP())
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from":user})
    print(token.balanceOf(user))
    print(penaltyFee)
    assert (token.balanceOf(user) + penaltyFee) >= amount
