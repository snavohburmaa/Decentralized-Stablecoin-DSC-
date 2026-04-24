# DSC Protocol — Security & Bug Fix

Scope: `src/DSCEngine.sol`, `src/DecentralizedStableCoin.sol`, `src/libraries/OracleLib.sol`

---

## Summary of findings


| #   | Severity     | Location                              | Title                                                     |
| --- | ------------ | ------------------------------------- | --------------------------------------------------------- |
| 1   | **CRITICAL** | `DSCEngine.redeemCollateralForDsc`    | Missing health-factor check and input validation          |
| 2   | **HIGH**     | `DSCEngine.getTokenAmountFromUsd`     | No `price <= 0` check — division by zero / underflow-cast |
| 3   | **MEDIUM**   | `OracleLib.staleCheckLatestRoundData` | Oracle accepts non-positive `answer`                      |
| 4   | **LOW**      | `DecentralizedStableCoin.burn / mint` | `_amount <= 0` check on `uint256` (dead code)             |
| 5   | **INFO**     | `DSCEngine.mintDsc / _burnDsc`        | No events emitted for DSC mint/burn                       |
| 6   | **MEDIUM**   | `DSCEngine.liquidate`                 | Self-liquidation lets borrower pocket the 10% penalty     |
| 7   | **LOW**      | `DSCEngine._calculateHealthFactor`    | Two sequential integer divisions lose precision           |


---

## Finding 1 — CRITICAL: `redeemCollateralForDsc` missing health-factor check and modifiers

### Location

`src/DSCEngine.sol::redeemCollateralForDsc`

### Before

```solidity
function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
    external {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
    }
```

### Impact

The external function had **no modifiers at all**:

- No `moreThanZero` on either amount → zero-amount calls silently succeed.
- No `isAllowedToken` → passing a random address produces an obscure underflow-panic revert instead of `DSCEngine__NotAllowedToken`.
- No `nonReentrant` → the function bypasses the reentrancy guard that every other state-changing function uses.
- **Most importantly: no** `_revertIfHealthFactorIsBroken` **at the end.** The function redeems collateral first, then burns DSC. An attacker or user could pass a very large `amountCollateral` with a tiny `amountDscToBurn`, removing collateral while leaving debt almost untouched and ending the call **with a health factor below 1**. That directly breaks the protocol's core invariant (over-collateralization) and is exactly the kind of state the `liquidate` path is meant to prevent.

Additionally, the original order (redeem first, burn after) is the worst ordering: collateral leaves the contract before debt is reduced. Swapping the order (burn → redeem → health check) both improves CEI and avoids a transient under-collateralized state inside the transaction.

### Fix

```solidity
function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
    external
    moreThanZero(amountCollateral)
    isAllowedToken(tokenCollateralAddress)
    nonReentrant
{
        if (amountDscToBurn == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
}
```

Note: `moreThanZero` is only applied once (to the collateral) because a Solidity modifier with the same name used twice with different args in one function is allowed but noisy, the second check is inlined with a direct `revert`.

---

## Finding 2 — HIGH: `getTokenAmountFromUsd` has no price validation

### Location

`src/DSCEngine.sol::getTokenAmountFromUsd`

### Before

```solidity
function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
    return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
}
```

### Impact

`getUsdValue` properly reverts if `price <= 0`, but `getTokenAmountFromUsd` does not. Consequences if the oracle returns `0` or a negative value:

- `price == 0` → division by zero → Panic(0x12) revert (non-descriptive, uses the wrong error surface).
- `price < 0` → `uint256(price)` wraps to ~`2**255`, returning an extremely small but *non-zero* token amount.` liquidate` calls this function to compute payout, a negative price feed could let a liquidator drain collateral for almost nothing while satisfying the rest of the math.

### Fix

```solidity
(, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
if (price <= 0) {
    revert DSCEngine__InvalidPrice();
}
return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
```

Defense-in-depth: Finding 3 also adds the check at the OracleLib level.

---

## Finding 3 — MEDIUM: OracleLib accepts non-positive `answer`

### Location

`src/libraries/OracleLib.sol::staleCheckLatestRoundData`

### Impact

The library that every price read goes through did not validate `answer > 0`. Chainlink feeds should never return 0 or negative values, but the whole point of `OracleLib` is to be the single choke-point that protects the protocol from oracle misbehavior. Pushing the check down to `OracleLib` also covers any future call site in the engine that forgets it.

### Fix

Added a new `OracleLib__InvalidPrice` error and:

```solidity
if (answer <= 0) {
    revert OracleLib__InvalidPrice();
}
```

---

## Finding 4 — LOW: `DecentralizedStableCoin` uses `_amount <= 0` on `uint256`

### Location

`src/DecentralizedStableCoin.sol::burn`, `::mint`

### Before

```solidity
if(_amount <= 0) { revert DecentralizedStableCoin__AmountMustBeMoreThanZero(); }
```

### Impact

`_amount` is a `uint256`, so `_amount < 0` is impossible,  only `_amount == 0` is reachable. No runtime impact today, but the misleading condition can mask real sign related bugs during future edits.

### Fix

Changed both occurrences to `_amount == 0`.

---

## Finding 5 — INFO: No events for DSC mint / burn

### Location

`src/DSCEngine.sol::mintDsc`, `::_burnDsc`

### Impact

`CollateralDeposited` and `CollateralRedeemed` are emitted, but minting and burning DSC, the core debt operations were silent on-chain. This hurts off-chain indexers, auditors, and front-end activity feeds.

### Fix

Added two events and emitted them in the relevant paths:

```solidity
event DscMinted(address indexed user, uint256 amount);
event DscBurned(address indexed dscFrom, address indexed onBehalfOf, uint256 amount);
```

---

## Finding 6 — MEDIUM: Self-liquidation bypasses the liquidation penalty

### Location

`src/DSCEngine.sol::liquidate`

### Impact

`liquidate` had no `user != msg.sender` check. A borrower whose own health factor fell below 1 could call `liquidate(collateral, msg.sender, debt)` on themselves:

- They pay `debtToCover` DSC (already in their wallet, since they minted it).
- They receive `debtToCover + 10% bonus` worth of their own collateral back into their wallet.
- Their position is restored to healthy.

The 10% `LIQUIDATION_BONUS` is meant as a penalty paid to an arm's-length third-party liquidator, the incentive that makes the liquidation market work. Self liquidation lets the borrower collect that penalty themselves and escape the intended punishment for running their position unhealthy. Design-wise this is what Compound explicitly blocks.

### Fix

Added a dedicated error and a guard at the top of the function body (after modifiers):

```solidity
error DSCEngine__CantLiquidateSelf();

function liquidate(address collateral, address user, uint256 debtToCover)
    external
    moreThanZero(debtToCover)
    isAllowedToken(collateral)
    hasEnoughDscBalance(msg.sender, debtToCover)
    nonReentrant
{
    if (user == msg.sender) {
        revert DSCEngine__CantLiquidateSelf();
    }
    ...
}
```

---

## Finding 7 — LOW: Health-factor math lost precision via two divisions

### Location

`src/DSCEngine.sol::_healthFactor`, `::_calculateHealthFactor`

### Before

```solidity
uint256 collateralAdjustedForThreshold =
    (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
```

Two sequential integer divisions, each rounding down. Right at the liquidation boundary (health factor close to `1e18`), the accumulated rounding error can flip whether a position is liquidatable or not.

`_healthFactor` and `_calculateHealthFactor` also duplicated the exact same formula, a maintenance trap.

### Fix

Combined into a single division and made `_healthFactor` delegate to `_calculateHealthFactor` so there is only one implementation:

```solidity
function _healthFactor(address user) private view returns (uint256) {
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
}

function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
    internal pure returns (uint256)
{
    if (totalDscMinted == 0) return type(uint256).max;
    return (collateralValueInUsd * LIQUIDATION_THRESHOLD * PRECISION)
        / (LIQUIDATION_PRECISION * totalDscMinted);
}
```

Single division, less rounding. Also eliminates the duplicate code path.

---

