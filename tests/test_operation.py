import brownie
from brownie import Contract
import pytest
import test_yswap
from utils import checks


def test_operation(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, prepare_trade_factory
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    print(strategy.getVirtualPrice())
    print(strategy.estimatedTotalAssets())
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # tend()
    strategy.tend()

    # withdrawal
    penaltyFee = strategy.exitPenaltyFeeWant(strategy.totalLP())
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})
    assert (
        pytest.approx(token.balanceOf(user) + penaltyFee, rel=RELATIVE_APPROX) == user_balance_before
    )
    print(strategy.estimatedTotalAssets()) # tiny amount is remaining because of the math on "withdrawSome()"
    checks.check_vault_empty(vault)


def test_emergency_exit(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, prepare_trade_factory
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    penaltyFee = strategy.exitPenaltyFeeWant(strategy.totalLP())
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(token.balanceOf(vault) + penaltyFee, rel=RELATIVE_APPROX) == amount
    checks.check_strategy_empty(strategy)


def test_profitable_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, prepare_trade_factory, ymechs_safe, multicall_swapper, unirouter, weth, tru, trade_factory, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    before_pps = vault.pricePerShare()

    # TODO: Add some code before harvest #2 to simulate earning yield

    # Harvest 2: Realize profit
    chain.sleep(86400 * 5)
    chain.mine(1)
    test_yswap.yswap(chain, strategy, token, tru, unirouter, weth, multicall_swapper, ymechs_safe, gov, trade_factory)
    tx = strategy.harvest()
    checks.check_harvest_profitable(tx)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault
    # TODO: Uncomment the lines below
    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_change_debt(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, prepare_trade_factory
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # In order to pass this tests, you will need to implement prepareReturn.
    # TODO: uncomment the following lines.
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    zx = strategy.harvest()
    print("strategy total estimated change debt:", strategy.estimatedTotalAssets())
    assert strategy.estimatedTotalAssets() >= half
    # penalty fee taken by vault 
    # vault received (half - penaltyFee)


def test_sweep(gov, vault, strategy, token, user, amount, weth, weth_amout, prepare_trade_factory):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    before_balance = weth.balanceOf(gov)
    weth.transfer(strategy, weth_amout, {"from": user})
    assert weth.address != strategy.want()
    assert weth.balanceOf(user) == 0
    strategy.sweep(weth, {"from": gov})
    assert weth.balanceOf(gov) == weth_amout + before_balance


def test_triggers(
    chain, gov, vault, strategy, token, amount, user, weth, weth_amout, strategist, prepare_trade_factory
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
