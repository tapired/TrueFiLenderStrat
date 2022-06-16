import pytest
from utils import checks

def test_revoke_strategy_from_vault(
    chain, token, vault, strategy, amount, user, gov, RELATIVE_APPROX, prepare_trade_factory
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    penaltyFee = strategy.exitPenaltyFeeWant(strategy.totalLP())
    print(penaltyFee)

    # In order to pass this tests, you will need to implement prepareReturn.
    # TODO: uncomment the following lines.
    vault.revokeStrategy(strategy.address, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    print(token.balanceOf(vault) + penaltyFee)
    assert pytest.approx(token.balanceOf(vault) + penaltyFee, rel=RELATIVE_APPROX) == amount


def test_revoke_strategy_from_strategy(
    chain, token, vault, strategy, amount, gov, user, RELATIVE_APPROX, prepare_trade_factory
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    penaltyFee = strategy.exitPenaltyFeeWant(strategy.totalLP())
    print(penaltyFee)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()

    print(token.balanceOf(vault) + penaltyFee)
    assert pytest.approx(token.balanceOf(vault) + penaltyFee, rel=RELATIVE_APPROX) == amount
    checks.check_strategy_empty(strategy)
