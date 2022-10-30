# Auto Roller • [![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0) [![ci](https://github.com/sense-finance/auto-roller/actions/workflows/ci.yml/badge.svg)](https://github.com/sense-finance/auto-roller/actions/workflows/ci.yml) [![codecov](https://codecov.io/gh/sense-finance/auto-roller/branch/main/graph/badge.svg?token=ZLT4CP7CEM)](https://codecov.io/gh/sense-finance/auto-roller)

## ELI5
The [auto-roller](https://medium.com/sensefinance/auto-rolling-liquidity-coming-to-sense-c5b1ff0f9aeb) is an ERC4626 compliant vault that automatically migrates Space pool liquidity from a matured series to a new series, thereby creating a passive LP experience.

## What is an Auto-Rolling LP Position?

Because every individual series on Sense [reaches maturity at some point](https://docs.sense.finance/docs/series-lifecycle-detail/), continuing to provide liquidity to active [Space Pools](https://docs.sense.finance/docs/core-concepts/#sense-space) on Sense would normally require moving that liquidity out of old pools (when they mature), and into new pools.  

To avoid this manual process for liquidity providers, Sense has created the auto-roller.  LPs can opt into an “auto-rolling” position. In an auto-rolling LP position, the auto-roller will remove liquidity from an old Space Pool after maturity, redeem its assets, initialize a new series, and add the liquidity to the new series’ Space pool.  This makes the LP experience a true “set it and forget it” passive investment.

Let’s go through an example: an auto-rolling 1-month duration pool. When the series matures, the auto-roller allows a “cool down” period during which exiting LPs incur no slippage (this could be any amount of time and could vary by adapter: perhaps 24hrs for a 1m series or 1 week for a 5yr series). Once the “cool down” period concludes, the auto-rolling position will initialize a new 1-month series automatically, set a starting interest rate, and roll all of its liquidity into the new pool for that new series.

For more details on implementation, relevant concepts, and the life-cycle of auto-rolling series, continue below.

## Actors
There are two actors that interact with the auto-roller:
* Liquidity providers (LP) - they `join` / `exit` the underlying asset to / from the auto-roller vault to earn yield. Though they can `exit` at any time, they’re encouraged to withdraw during the cooldown phase to minimize slippage. They interface with each auto-roller through a single `AutoRollerPeriphery`, which supports slippage protection for their actions.
* Admin - they deploy the auto-rolling vault. At any time, they can change the space factory address, periphery address, owner address, series duration, the max rate, and the cooldown period via the `AutoRoller`. However, they do not have privilege of the rate setting mechanism.

## Implementation Details
The auto-roller conforms to the [ERC4626](https://eips.ethereum.org/EIPS/eip-4626) standard as a single token vault that takes in and returns a target asset (i.e.  a [yield-bearing asset](https://medium.com/sensefinance/yield-in-the-defi-economy-3a83eb24ecba), such as wstETH), while managing Space Pool LP shares, target, principal tokens (PTs), and yield tokens (YTs) over time such that depositors can passively and continuously provide liquidity without having to roll their position manually.

Here are some important concepts to understand so you know how the auto-roller works from a more technical perspective.

### Contracts
* `AutoRoller` - the ERC4626 vault that owns a unique sense adapter and permits unprotected joins/exits from/to some underlying asset.
* `AutoRollerFactory` - onchain auto-roller factory.
* `RollerPeriphery` - the slippage protected LP management interface to all AutoRollers.
* `OwnableAdapter` - Sense adapter owned by a unique auto-roller. Through the auto-roller, series rollers sponsor new series via `roll` and settler series via `settle`.

### Phases
The auto-roller has an **active** and a **cooldown** phase. During the active phase, there is a specific Space pool that the auto-roller is managing, and the liquidity it holds is in the form of Space LP shares and YTs (e.g. sY-wstETH). In contrast, the cooldown phase is in-between active phases when the auto-roller has settled one series but not yet sponsored a new one and deposited liquidity into the new pool (also at the very beginning of the contract’s lifecycle before it has entered the first pool). 

During these cooldown phases, all of the auto-roller’s liquidity is held in target (e.g. wstETH), so auto-roller shares act kind of like target wrappers. The length of the cooldown phase is configurable, and it’s most beneficial for users who will want a window to exit without slippage – if you exit the auto-roller during the cooldown phase, all of your liquidity is already denominated in target (e.g.wstETH) so when you pull it out so there is no slippage from interacting with the pool.

We recommend exiting pools during cool-down phases to prevent any slippage (exiting during other phases can result in receiving part of your LP position in YT or PT terms).

### Rolling
Rolling is the transition point between the **cooldown** and **active** phase. After a series is settled & the cooldown is complete, a series roller calls `AutoRoller.roll` to 1) sponsor a new series, 2) calculate an initial fixed rate, and 3) migrate liquidity from the old series to the new. The series roller is now the [sponsor of the series](https://docs.sense.finance/docs/series-lifecycle-detail/#phase-1-sponsoring) and has privileged access to `AutoRoller.settle` the new series [around maturity](https://docs.sense.finance/docs/series-lifecycle-detail/#phase-3-settling) through the auto-roller. If the sponsor does not settle, then `AutoRoller.settle` becomes public, allowing MEV bots to capture the settlement reward.

### Excess Balances
When a user deposits target during an active phase, some of their target is used to issue PTs and YTs so that they can join the Space pool without trading against it and incurring slippage costs. When we do this action for them, the auto-roller ends up with YTs that it doesn’t immediately use – it instead holds them so that it can redeem PTs (e.g. sP-wstETH) and YTs (e.g. sY-wstETH) together for target when exiting. But, if there are trades in the pool that push the PT price up, then there are fewer PTs than YTs in the contract and it has extra YTs it can't combine with PTs to redeem. The reverse can happen if the PT price is pushed down.  These extra tokens, PTs that don’t have corresponding YTs (or vice versa), are considered “excess balances” and can cause some slippage when exiting with the “Redeem” function during the active phase of a auto-roller.

#### Exiting Pools

### Redeem
During a cooldown phase, the LP holder can use Redeem to exit the pool and receive their target asset. During the active phase, in order for a user to withdraw target with the redeem function, the auto-roller exits their LP shares into target and PTs, and combines whatever PTs it can with the YTs it’s holding in the contract. As discussed above, the share can have either excess YTs or PTs, which it then sells into the pool for target, which can incur slippage.  If that slippage is greater than the slippage max parameter for the auto-roller, it will not allow the LP to exit directly into target, so they must instead use the “Eject” function when exiting.

### Ejecting
Ejecting is an alternative way to pull capital out of an auto-roller.  During the active phase, if the user is OK breaking out of the 4626 standard, they can use the “Eject” function. This function will combine any PTs and YTs it can into target, and then return to the user target + whatever excess PTs or YTs could not be combined.  With this function you always receive the entire value of your LP share (no slippage) but some part of that value may be denominated in PTs or YTs.

### Withdrawals
The withdraw function in the 4626 spec takes in the amount of asset the user would like to receive (target in our case) and then pulls the necessary amount of shares to withdraw that amount of assets for the user. It is extremely difficult in the case of a space pool share to go from the number of assets a user would like to receive, to the number of shares required to get them. As a result we had to implement the secant method on-chain for this function.  

By using a withdraw function, the user exits their liquidity position and receives their capital in target terms (e.g. wstETH for the Web3 Yield Curve).

### Rate Setting
When a series has matured, the autoroller waits for a cooldown period (in which anyone can exit into target with no slippage), and then issues a new series and rolls the liquidity into that new one. In order to start this new series, the autoroller has to pick a starting fixed rate.  The rate-setting function uses the historical average Target rate across the series by digesting the adapter’s scale value at series sponsorship and maturity.

## Deployments

### Mainnet

| Chain   | Address                                                                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------------------------- |
| AutoRoller1 | TBD                 |
| RollerPeriphery  | TBD

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

Sense Space contracts have gone through different independent security audits performed by [Fixed Point Solutions (Kurt Barry)](https://github.com/fixed-point-solutions) and [Spearbit](https://spearbit.com). Reports are located in the [`audits`](./audits) directory.


