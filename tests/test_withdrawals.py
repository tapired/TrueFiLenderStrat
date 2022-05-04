import brownie
from brownie import Contract
import pytest
from utils import checks



def test_lossywithdrawal(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
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

    chain.mine(1)
    print("strategy has", strategy.estimatedTotalAssets())

    # we did all we can by liquidating all
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from":user})
    checks.check_vault_empty(vault)
    checks.check_strategy_empty(strategy)

def test_partialwithdrawal(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
):
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

   chain.mine(1)
   print("strategy has", strategy.estimatedTotalAssets())

   vault.withdraw(vault.balanceOf(user)/2, user, 10_000, {"from":user})

   print(token.balanceOf(user))
