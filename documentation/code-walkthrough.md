# The Diamond Hook Explained

Let’s dive straight into the `src/DiamondHookPoC.sol` file which contains the Diamond Hook contract. An important thing to note with our implementation is the fact that the Hook contract itself controls the liquidity positions. This is a result of the pool liquidity (pool constant in V2 terms) changing when the pool price updates at the beginning of a block. More on this soon. Users depositing or withdrawing liquidity to the pool must do so through Hook functionalities, namely `mint()` and `burn()`.

[img]

The Diamond protocol requires 4 hooks, `beforeInitialize`, `beforeModifyPosition`, `beforeSwap`, and `afterSwap`.

Let’s go through what is being checked for in each:
- beforeInitialize: Basic checks to ensure the pool hasn’t been created before.
- beforeModifyPosition: As mentioned earlier, the Diamond Hook contract controls the liquidity positions in the pool. This hook ensures users can only access pool liquidity through the hook. 
- beforeSwap: checks that the builder has updated the pool price in the current block, reverting if not.
- afterSwap: ensures that there is enough collateral in the PoolManager contract to move the price back to the committed price, committedSqrtPriceX96, after each swap has taken place. If this check didn’t happen, the builder could move the price arbitrarily at the top of the block

## Updating pool price

A key functionality mentioned above is the updating of the pool price in a block before any swaps can take place. This price update is performed via the `openPool()` function in the Hook contract. This `openPool()` function takes as input the price to which the builder will commit to in the block, which we expect to correspond to the LVR maximizing price. This function routes to the `lockAcquiredArb()` function. Given the starting price and committed price, the function calculates the implied trade size X that would normally take place in the AMM to move the pool to the committed price. This trade size X is discounted by the LVR-rebate parameter, which has been hardcoded in the `_getBeta()` function, returning some number between 0 and 1. If `_getBeta()` returns 0.75, the builder is only allowed to execute _(1-0.75)X=0.25X_.

By only executing a fraction of the desired trade size, the pool price will not correspond to the committed price by only pushing along the V2 curve. To move the price to the committed price, some additional amount of the token being bought by the builder must be removed from the pool. These additional tokens are temporarily stored in the PoolManager contract (the vault as described [here](https://ethresear.ch/t/lvr-minimization-in-uniswap-v4/15900)), and added back into the pool slowly each block. Specifically, `vaultRedepositRate` of the vault tokens are added back to the liquidity pool per-block. We recommend `vaultRedepositRate` to be somewhere between 1% and 5%. The reasons for this are described [here](https://ethresear.ch/t/lvr-minimization-in-uniswap-v4/15900) related to “low impact re-adding”.

## Swaps

For any swap to take place in a Diamond Hook-managed pool, the builder must deposit some collateral, effectively committing to returning the pool price to the price committed at the start of the block. Collateral can be deposited and withdrawn using `depositHedgeCommitment()` and `withdrawHedgeCommitment()` respectively. In the case of withdrawing, there is a check to ensure the withdrawn amount does not violate any existing collateral requirements caused by moving the pool price away from the committed price. 

Given collateral has been deposited, and the `beforeSwap` and `afterSwap` hooks are not violated, swaps take place as normal in the pool. 

## Typical block containing Diamond swaps

To avoid repetition, we define **Condition 1** to be: _The amount of collateral deposited in `depositHedgeCommitment()` is enough to move the price of the pool back to the price committed to in the `openPool()` transaction for that block._

- `openPool()` is called, moving the pool price to the committed price.
- `depositHedgeCommitment()` is called, depositing collateral to the Hook protocol. This can be called arbitrarily many times in the block if more collateral is required later in the block.
- Swaps take place. A swap can only take place in a block if both `openPool()` and `depositHedgeCommitment()` have already been called, and Condition 1 holds after the swap is executed.
- Liquidity additions and removal can take place through the calling of mint() and burn() at any point in the block as long as Condition 1 holds after the liquidity addition/removal occurs.
- `withdrawHedgeCommitment()` can be called at any time, as long as Condition 1 holds after the collateral withdrawal takes place.

## Tests

In the `test/DiamondHook.t.sol` file, we perform a series of basic, (hopefully) self-explanatory tests. First, `setUp()` performs the required setup to deploy a V4 pool with 2 test tokens. We initialize the pool to price 1, although without any tokens in the `setup()` contract. 

- `testOpeningTotalSupplyZero()`: a sanity check to ensure the pool price couldn’t be moved without some tokens in the pool (price moves burn 1 wei from the pool).
- `testBasicArbSwap()`: mints some tokens, moves the pool price first to 4, then back to 1. The test contains a series of assertions ensuring the token balances in the pool and pool manager act as expected.
- `testManyWhipSaws()`: repeats the previous test multiple times in a row to track the amount of wei being lost is manageable, and as expected.
- `testWithdraw()`: performs a series of mints and burns (liquidity adds and removals), with several price moves mixed in. Another sanity check.
- `testSwaps()`: mints liquidity, then performs some swaps at various committed pool prices (the way swaps would be performed from a normal users perspective).

## Caveats

**This code is not audited and likely contains bugs. Do not deploy without auditing.**

This code is pinned to use an older version of the Uniswap V4 codebase (which is not frozen and continues to change). Adapting the code to use dependencies that are up to date should be relatively straightforward.

The PoC is built specifically to handle Uniswap V2 style liquidity positions. This was due to the need to constantly update the pool liquidity and track the resulting per-LP changes which become unwieldy with V3 positions. Developers intending to add V3 compatibility should be aware that V2-specific math is used on occasion, and must be adapted to handle V3 positions.
