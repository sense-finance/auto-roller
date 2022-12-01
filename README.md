# Rolling Liquidity Vault (RLV) • [![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0) [![ci](https://github.com/sense-finance/auto-roller/actions/workflows/ci.yml/badge.svg)](https://github.com/sense-finance/auto-roller/actions/workflows/ci.yml) [![codecov](https://codecov.io/gh/sense-finance/auto-roller/branch/main/graph/badge.svg?token=ZLT4CP7CEM)](https://codecov.io/gh/sense-finance/auto-roller)

## ELI5
The [Rolling Liquidity Vault](https://medium.com/sensefinance/auto-rolling-liquidity-coming-to-sense-c5b1ff0f9aeb) (also known as the `AutoRoller`) is an ERC4626 compliant vault that automatically migrates Sense Space pool liquidity from a matured series to a new series, thereby creating a passive LP experience. Instead of needing to actively manage liquidity, LPs can opt into an "rolling" position by depositing their assets into an RLV, recieving LP shares in return.  

Let’s go through an example: a 1-month duration RLV pool. When the series matures, the RLV allows a “cool down” period during which exiting LPs incur no slippage (this could be any amount of time and could vary by adapter: perhaps 24hrs for a 1m series or 1 week for a 5yr series). Once the “cooldown” period concludes, the RLV will initialize a new 1-month series automatically, set a starting market fixed rate, and roll all of its liquidity into the new pool for that new series.

For more details on implementation, relevant concepts, and the life-cycle of RLVs, continue below.

## Actors
There are two actors that interact with the RLV:
* Liquidity providers (LPs) - they `deposit`/`withdraw` the underlying asset to / from the RLV vault to earn yield. Though they can exit at any time, they’re encouraged to withdraw during the *cooldown phase* to minimize slippage. They interface with each RLV through a single `RollerPeriphery`, which adds slippage protection to their actions.
* Admin - they deploy the RLV. At any time, they can change the space factory address, periphery address, owner address, series duration, the max post-action fixed rate, and the cooldown period via the `AutoRoller`. However, they do not have the privilege to set the market fixed rate of the new series.

## Implementation Details
The RLV conforms to the [ERC4626](https://eips.ethereum.org/EIPS/eip-4626) standard as a single token vault that takes in and returns a target asset (i.e.  a [yield-bearing asset](https://medium.com/sensefinance/yield-in-the-defi-economy-3a83eb24ecba), such as wstETH), while managing Space Pool LP shares, target, principal tokens (PTs), and yield tokens (YTs) over time such that depositors can passively and continuously provide liquidity without having to roll their position manually.

Here are some important concepts to understand so you know how the RLV works from a more technical perspective.

### Contracts
* `AutoRoller` - the ERC4626 vault that owns a unique sense adapter and permits unprotected LP actions.
* `AutoRollerFactory` - on-chain factory for easy deployment of new RLV instances.

* `RollerPeriphery` - the slippage protected LP management interface to all RLVs.
* `OwnableAdapter` - Sense adapter owned by a unique RLV. Through the RLV, series rollers can sponsor new series via `AutoRoller.roll` and settle series via `AutoRoller.settle`.

### Phases
The RLV has an **active** and a **cooldown** phase. During the active phase, there is a specific Space pool that the RLV is managing, and the liquidity it holds is in the form of Space LP shares and YTs (e.g. sY-wstETH). In contrast, the cooldown phase is in-between active phases when the RLV has settled one series but not yet sponsored a new one and deposited liquidity into the new pool (also at the very beginning of the contract’s lifecycle before it has entered the first pool). 

During these cooldown phases, all of the RLV's liquidity is held in target (e.g. wstETH), so RLV shares act kind of like target wrappers. The length of the cooldown phase is configurable, and it’s most beneficial for users who will want a window to exit without slippage – if you exit the RLV during the cooldown phase, all of your liquidity is already denominated in target (e.g.wstETH) so when you pull it out so there is no slippage from interacting with the pool.

We recommend exiting pools during cooldown phases to prevent any slippage (exiting during other phases can result in receiving part of your LP position in YT or PT terms).

### Rolling
Rolling is the transition point between the **cooldown** and **active** phase. After a series is settled & the cooldown is complete, a series roller calls `AutoRoller.roll` to 1) sponsor a new series, 2) calculate an initial fixed rate, and 3) migrate liquidity from the old series to the new.

The initial fixed rate is set to the historical average Target rate across the previous series by digesting the adapter’s scale value at series sponsorship and maturity. The delta scale across a known time period is used to calculate an annualized avg Target rate.

The series roller is the [series sponsor](https://docs.sense.finance/docs/series-lifecycle-detail/#phase-1-sponsoring) and has privileged access to `AutoRoller.settle` the new series [around maturity](https://docs.sense.finance/docs/series-lifecycle-detail/#phase-3-settling). If the sponsor does not settle within the grace period, then `Divider.settle` becomes public, allowing MEV bots to capture the settlement reward and settle the series. 

When the series is settled external to the RLV, one needs to call `AutoRoller.startCooldown` to initiate the cooldown phase and enable no-slippage withdrawals. We expect LPs and other stakeholders to call this function, but if the RLV remains in the active phase, post series settlement, LPs can still `eject` their assets and later redeem/collect their excess PTs/YTs to at zero-slippage.

### Excess Balances
When a user deposits target during an active phase, some of their target is used to issue PTs and YTs so that they can join the Space pool without trading against it and incurring slippage costs. When we do this action for them, the RLV ends up with YTs that it doesn’t immediately use – it instead holds them so that it can redeem PTs (e.g. sP-wstETH) and YTs (e.g. sY-wstETH) together for target when exiting. But, if there are trades in the pool that push the PT price up, then there are fewer PTs than YTs in the contract and it has extra YTs it can't combine with PTs to redeem. The reverse can happen if the PT price is pushed down.  These extra tokens, PTs that don’t have corresponding YTs (or vice versa), are considered “excess balances” and can cause some slippage when exiting with `AutoRoller.redeem` during the active phase of a RLV.

### Exiting Pools

#### Redeem
During a cooldown phase, the LP holder can use `redeem` to exit the pool and receive their target asset. During the active phase, in order for a user to withdraw target via `redeem`, the RLV exits their LP shares into target and PTs, and combines whatever PTs it can with the YTs it’s holding in the contract. As discussed above, the share can have either excess YTs or PTs, which it then sells into the pool for target, incurring slippage. Three precautions are taken to constrain slippage costs during the active phase:
1. We enocurage all LPs to manage their RLV position via the `RollerPeriphery`, which wraps slippage protection around all RLV actions.
2. If an LP does not enforce slippage protection, the RLV has a backup max rate parameter that prevents the market fixed rate from exceeding a certain threshold (e.g. 100% fixed rate).
3. If an LP wants to exit with zero slippage for *part of their position*, they can `eject` to unlock the Target component from [their LP position](https://docs.sense.finance/docs/space-pool-performance/#what-is-a-space-pool-lp-position).

#### Ejecting
Ejecting is an alternative way to pull capital out of an RLV.  During the active phase, if the user is OK breaking out of the 4626 standard, they can use `AutoRoller.eject`. This function will combine any PTs and YTs it can into target, and then return to the user target + whatever excess PTs or YTs could not be combined.  With this function you always receive the entire value of your LP share (no slippage) but some part of that value may be denominated in PTs or YTs.

#### Withdrawals
The withdraw function in the 4626 spec takes in the amount of asset the user would like to receive (target in our case) and then pulls the necessary amount of shares to withdraw that amount of assets for the user. It is extremely difficult in the case of a space pool share to go from the number of assets a user would like to receive, to the number of shares required to get them. As a result we had to implement the [secant method](https://en.wikipedia.org/wiki/Secant_method) on-chain for this function.  

By using `AutoRoller.withdraw`, the user exits their liquidity position and receives their capital in target terms (e.g. wstETH for the Web3 Yield Curve).

## Deployments

### Mainnet

| Contract   | Address |
| ------- | ------------------------------------------------------------------------------------------------------------------------- |
| [RollerFactory](https://github.com/sense-finance/auto-roller/blob/main/src/AutoRollerFactory.sol) | [0x3B0f35bDD6Da9e3b8513c58Af8Fdf231f60232E5](https://etherscan.io/address/0x3B0f35bDD6Da9e3b8513c58Af8Fdf231f60232E5#code)    |
| [RollerPeriphery](https://github.com/sense-finance/auto-roller/blob/main/src/RollerPeriphery.sol)  | [0xF3244CDCC765B15CbE1479c564f5fa31125d4FC3](https://etherscan.io/address/0xF3244CDCC765B15CbE1479c564f5fa31125d4FC3#code) |
| [RollerUtils](https://github.com/sense-finance/auto-roller/blob/main/src/AutoRoller.sol) | [0xb6f7643fd0831eda3BAbe20EE9c98DA4D473807e](https://etherscan.io/address/0xb6f7643fd0831eda3BAbe20EE9c98DA4D473807e) |
| [wstETHRoller](https://github.com/sense-finance/auto-roller/blob/main/src/AutoRoller.sol) | [0xeb9e7e1F892Bb2931e8C319D6F10FDf147090818](https://etherscan.io/address/0xeb9e7e1F892Bb2931e8C319D6F10FDf147090818#code) |
| [maUSDCRoller](https://github.com/sense-finance/auto-roller/blob/main/src/AutoRoller.sol) | [0x5A41f64eaf49d1582A289B197A4c5D64b2342aAe](https://etherscan.io/address/0x5A41f64eaf49d1582A289B197A4c5D64b2342aAe#code) |
| [maUSDTRoller](https://github.com/sense-finance/auto-roller/blob/main/src/AutoRoller.sol) | [0x321DfB34851E1663C91d07Cb5496e55A70aDE253](https://etherscan.io/address/0x321DfB34851E1663C91d07Cb5496e55A70aDE253#code) |

## Development

This repo uses [Foundry: forge](https://github.com/gakonst/foundry) for development and testing
and git submodules for dependency management.

To install Foundry, use the instructions in the linked repo.

### Test

```bash
# Get contract dependencies
git submodule update --init --recursive

# Run tests
forge test

# Run tests with tracing enabled
forge test -vvv
```

### Format

```bash
# Get node dependencies
yarn install # or npm install

# Run linter
yarn lint

# Run formatter
yarn fix
```

### Deploy


TBD

## Security

Sense Space contracts have gone through different independent security audits performed by [Fixed Point Solutions (Kurt Barry)](https://github.com/fixed-point-solutions). Reports are located in the [`audits`](./audits) directory.


