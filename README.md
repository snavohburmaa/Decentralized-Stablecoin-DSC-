# Decentralized StableCoin (DSC) Protocol

A decentralized stablecoin protocol that maintains a 1:1 USD peg through algorithmic stability mechanisms. Similar to MakerDAO's DAI, but simplified with no governance and no fees, backed exclusively by wETH and wBTC.

## Core Properties

### 1. Relative Stability (Anchor/Pegged to USD $)
- Uses **Chainlink Price Feeds** for real-time price data
- Functions to exchange ETH & BTC to USD value
- Maintains 1 DSC = 1 USD peg through algorithmic mechanisms

### 2. Stability Mechanism (Minting): Algorithmic (Decentralized)
- Users can only mint the stablecoin with sufficient collateral (coded requirement)
- Overcollateralized system (minimum 200% collateralization)
- Health factor monitoring ensures system safety

### 3. Collateral: Exogenous (Crypto)
- **wETH** (Wrapped Ethereum)
- **wBTC** (Wrapped Bitcoin)

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [Usage](#usage)
- [Testing](#testing)
- [Security](#security)
- [Project Structure](#project-structure)

## 🎯 Overview

The Decentralized StableCoin (DSC) is a collateralized debt position (CDP) system that allows users to:

- **Deposit** wETH or wBTC as collateral
- **Mint** DSC tokens (up to 50% of collateral value)
- **Redeem** collateral by burning DSC tokens
- **Liquidate** undercollateralized positions

The protocol ensures that the total value of all collateral always exceeds the total DSC supply, maintaining system solvency.

## Architecture

### Core Contracts

#### `DecentralizedStableCoin.sol`
- ERC20 token implementation with burnable functionality
- Ownable by DSCEngine
- Mintable and burnable by owner only
- Represents the stablecoin (DSC)

#### `DSCEngine.sol`
The core engine that manages:
- Collateral deposits and withdrawals
- DSC minting and burning
- Health factor calculations
- Liquidation logic
- Price feed integration via Chainlink

#### `OracleLib.sol`
Library for handling Chainlink price feed staleness and ensuring data freshness.

### Key Mechanisms

#### Health Factor
```
Health Factor = (Collateral Value × 50% × 1e18) / Total DSC Minted
```
- Health Factor < 1e18: Position can be liquidated
- Health Factor ≥ 1e18: Position is safe

#### Collateralization Ratio
- Minimum: 200% (users can mint up to 50% of collateral value)
- Liquidation threshold: 50% of collateral value

#### Liquidation
- Liquidators can repay debt and receive collateral
- 10% liquidation bonus for liquidators
- Health factor must improve after liquidation

## Installation

### Setup

1. Clone the repository:
```bash
git clone <repository-url>
cd StableCoinDeFi
```

2. Install dependencies:
```bash
forge install
```

3. Build the project:
```bash
forge build
```

## Usage

### Deployment

Deploy the contracts using the deployment script:

```bash
forge script script/DeployDSC.s.sol:DeployDSC --rpc-url <RPC_URL> --broadcast --verify
```

### Interacting with the Protocol

#### Deposit Collateral and Mint DSC

```solidity
// Approve collateral
IERC20(weth).approve(address(dscEngine), amount);

// Deposit collateral
dscEngine.depositCollateral(weth, amount);

// Mint DSC (up to 50% of collateral value)
dscEngine.mintDsc(mintAmount);
```

#### Redeem Collateral

```solidity
// Redeem collateral (must maintain health factor >= 1)
dscEngine.redeemCollateral(weth, amount);

// Or redeem and burn DSC in one transaction
dscEngine.redeemCollateralForDsc(weth, collateralAmount, dscAmountToBurn);
```

#### Burn DSC

```solidity
// Approve DSC
dsc.approve(address(dscEngine), amount);

// Burn DSC
dscEngine.burnDsc(amount);
```

#### Liquidate Position

```solidity
// Liquidate undercollateralized position
dscEngine.liquidate(collateralToken, user, debtToCover);
```

## Testing

### Run All Tests

```bash
forge test
```

### Run Specific Test Suites

```bash
# Unit tests
forge test --match-path test/unit/*

# Fuzz/Invariant tests
forge test --match-path test/fuzz/*

# Coverage report
forge coverage
```

### Test Structure

- **Unit Tests** (`test/unit/`): Test individual functions and edge cases
- **Fuzz Tests** (`test/fuzz/`): Property-based testing with invariants
- **Mocks** (`test/mocks/`): Mock contracts for testing

### Key Test Files

- `DSCEngineTest.t.sol`: Comprehensive unit tests for DSCEngine
- `TrueInvariantsTest.t.sol`: Invariant testing ensuring protocol safety
- `Handler.t.sol`: Handler contract for fuzz testing

## Security

### Security Features

- ✅ ReentrancyGuard on all state-changing functions
- ✅ Input validation (non-zero amounts, allowed tokens)
- ✅ Health factor checks before critical operations
- ✅ Price feed staleness checks
- ✅ Overcollateralization requirements

### Security Considerations

- **Price Feed Risks**: Relies on Chainlink price feeds - stale or manipulated feeds could affect the system
- **Liquidation Risks**: Under extreme market conditions, positions may become liquidatable
- **Smart Contract Risks**: As with all DeFi protocols, smart contract bugs pose risks

### Audit Status

This is a learning project and has not been audited. **Do not use in production without a professional audit.**

## Project Structure

```
StableCoinDeFi/
├── src/
│   ├── DecentralizedStableCoin.sol    # Stablecoin token contract
│   ├── DSCEngine.sol                  # Core engine contract
│   └── libraries/
│       └── OracleLib.sol              # Oracle utilities
├── script/
│   ├── DeployDSC.s.sol                # Deployment script
│   └── HelperConfig.s.sol             # Configuration helper
├── test/
│   ├── unit/
│   │   └── DSCEngineTest.t.sol        # Unit tests
│   ├── fuzz/
│   │   ├── Handler.t.sol              # Fuzz test handler
│   │   ├── TrueInvariantsTest.t.sol   # Invariant tests
│   │   └── FalseInvariantsTest.t.sol  # Negative invariant tests
│   └── mocks/
│       ├── ERC20Mock.sol               # Mock ERC20 token
│       └── MockV3Aggregator.sol        # Mock Chainlink aggregator
├── lib/                                # Dependencies
├── foundry.toml                        # Foundry configuration
└── README.md                          # This file
```

## Configuration

### Foundry Configuration

Key settings in `foundry.toml`:

```toml
[invariant]
runs = 200
depth = 200
fail_on_revert = true
```

## Key Concepts

### Collateral Types
- **wETH**: Wrapped Ethereum
- **wBTC**: Wrapped Bitcoin

### Price Feeds
- Uses Chainlink AggregatorV3Interface
- 8 decimals for price feeds
- Additional precision: 1e10
- Total precision: 1e18

### Constants
- `LIQUIDATION_THRESHOLD`: 50% (users can borrow up to 50% of collateral value)
- `MIN_HEALTH_FACTOR`: 1e18 (1.0)
- `LIQUIDATION_BONUS`: 10% (bonus for liquidators)
- `ADDITIONAL_FEED_PRECISION`: 1e10
- `PRECISION`: 1e18

## Contributing

This is a learning project. Contributions, suggestions, and improvements are welcome!

## License

MIT License

## Disclaimer

This project is for educational purposes only. It has not been audited and should not be used in production without proper security audits and testing.

## Author

**OhBurmaa**

---

**Note**: This protocol is inspired by MakerDAO's DAI system but simplified for educational purposes. It maintains the core concepts of overcollateralization and algorithmic stability while removing governance complexity.
