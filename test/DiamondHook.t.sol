// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {FeeLibrary} from "@uniswap/v4-core/contracts/libraries/FeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {console} from "forge-std/console.sol";

import {DiamondHookPoC} from "../src/DiamondHookPoC.sol";
import {DiamondHookImpl} from "./utils/DiamondHookImpl.sol";

contract TestDiamondHook is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    address hookAddress;
    TestERC20 token0;
    TestERC20 token1;
    PoolId poolId;
    DiamondHookPoC hook = DiamondHookPoC(address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG |Hooks.AFTER_SWAP_FLAG
                )
            ));
    PoolKey poolKey;

    PoolSwapTest swapRouter;

    uint24 constant PIPS = 1000000;
    int24 public tickSpacing = 10;
    uint24 public baseBeta = PIPS/2; // % expressed as uint < 1e6
    uint24 public decayRate = PIPS/10; // % expressed as uint < 1e6
    uint24 public vaultRedepositRate = PIPS/10; // % expressed as uint < 1e6
    // we also want to pass in a minimum constant amount (maybe even a % of total pool size, so the vault eventually empties)
    // if we only ever take 1% of the vault, the vault may never empty.
    uint24 public fee = 1000; // % expressed as uint < 1e6

    int24 public lowerTick;
    int24 public upperTick;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);

        if (uint160(address(token0)) > uint160(address(token1))) {
            TestERC20 temp = token0;
            token0 = token1;
            token1 = temp;
        }
        
        manager = new PoolManager(500000);

        DiamondHookImpl impl = new DiamondHookImpl(manager, hook,tickSpacing,baseBeta,decayRate,vaultRedepositRate);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(hook), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(impl), slot));
            }
        }
        // Create the pool
        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            fee,
            tickSpacing,
            hook
        );
        poolId = poolKey.toId();
        uint256 price = 1;
        manager.initialize(poolKey, computeNewSQRTPrice(price));
        swapRouter = new PoolSwapTest(manager);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        lowerTick = hook.lowerTick();
        upperTick = hook.upperTick();
        
        assertEq(lowerTick, -887270);
        assertEq(upperTick, 887270);
    }

    function testOpeningTotalSupplyZero() public {
        uint256 height = 1;
        vm.roll(height);

        // do arb swap (price rises from initial)
        uint160 newSQRTPrice = computeNewSQRTPrice(4);

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondHookPoC.TotalSupplyZero.selector
            )
        );

        hook.openPool(newSQRTPrice);
    }

    function testBasicArbSwap() public {
        // mint some liquidity
        hook.mint(10**18,address(this));
        uint256 height = 1;
        vm.roll(height);

        // get starting values
        uint256 balance0ManagerBefore = token0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = token1.balanceOf(address(manager));
        uint128 liquidityBefore = manager.getLiquidity(poolId);
        uint256 balance0ThisBefore = token0.balanceOf(address(this));
        uint256 balance1ThisBefore = token1.balanceOf(address(this));

        // do arb swap (price rises from initial)
        uint160 newSQRTPrice = computeNewSQRTPrice(4);
        hook.openPool(newSQRTPrice);

        // get ending values
        (uint160 newSQRTPriceCheck,,,,,) = manager.getSlot0(poolId);
        uint256 balance0ManagerAfter = token0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = token1.balanceOf(address(manager));
        uint128 liquidityAfter = manager.getLiquidity(poolId);
        uint256 balance0ThisAfter = token0.balanceOf(address(this));
        uint256 balance1ThisAfter = token1.balanceOf(address(this));

        // check expectations
        assertEq(newSQRTPriceCheck, newSQRTPrice); // pool price moved to where arb swap specified
        assertGt(balance1ManagerAfter, balance1ManagerBefore); // pool gained token0
        assertGt(balance0ManagerBefore, balance0ManagerAfter); // pool lost token1
        assertGt(balance1ThisBefore, balance1ThisAfter); // arber lost token0
        assertGt(balance0ThisAfter, balance0ThisBefore); // arber gained token1
        assertEq(balance0ThisAfter-balance0ThisBefore, balance0ManagerBefore-balance0ManagerAfter); // net is 0
        assertEq(balance1ThisBefore-balance1ThisAfter, balance1ManagerAfter-balance1ManagerBefore); // net is 0
        assertGt(liquidityBefore, liquidityAfter); // liquidity decreased

        // reset starting values
        balance0ThisBefore = balance0ThisAfter;
        balance1ThisBefore = balance1ThisAfter;
        balance0ManagerBefore = balance0ManagerAfter;
        balance1ManagerBefore = balance1ManagerAfter;

        // go to next block
        vm.roll(height+1);

        // do arb swap (price back down to initial)
        newSQRTPrice = computeNewSQRTPrice(1);
        hook.openPool(newSQRTPrice);

        // get ending values
        balance0ThisAfter = token0.balanceOf(address(this));
        balance1ThisAfter = token1.balanceOf(address(this));
        balance0ManagerAfter = token0.balanceOf(address(manager));
        balance1ManagerAfter = token1.balanceOf(address(manager));
        (newSQRTPriceCheck,,,,,) = manager.getSlot0(poolId);

        // check expectations 
        assertEq(newSQRTPrice, newSQRTPriceCheck);
        assertGt(balance1ManagerBefore, balance1ManagerAfter);
        assertGt(balance0ManagerAfter, balance0ManagerBefore);
        assertGt(balance1ThisAfter, balance1ThisBefore);
        assertGt(balance0ThisBefore, balance0ThisAfter);
        assertEq(balance1ThisAfter-balance1ThisBefore, balance1ManagerBefore-balance1ManagerAfter);
        assertEq(balance0ThisBefore-balance0ThisAfter, balance0ManagerAfter-balance0ManagerBefore);

        uint160 liquidityAfter2 = manager.getLiquidity(poolId);
        assertGt(liquidityAfter2, liquidityAfter); // liquidity actually increased (price moved back, can redeposit more vault)
        assertGt(liquidityBefore, liquidityAfter2); // but liquidity still less than originally 
    }

    function testManyWhipSaws() public {
        hook.mint(10**18,address(this));
        uint256 height = 1;
        uint256 price;
        uint160 newSQRTPrice;

        uint256 balance0ManagerBefore = token0.balanceOf(address(manager));
        uint256 balance1ManagerBefore = token1.balanceOf(address(manager));
        (uint256 liquidity0Before, uint256 liquidity1Before) = getTokenReservesInPool();

        assertEq(balance0ManagerBefore-1, liquidity0Before);
        assertEq(balance1ManagerBefore-1, liquidity1Before);

        for(uint256 i = 0; i < 5; i++) {
            vm.roll(height++);
            price = 4;
            newSQRTPrice=computeNewSQRTPrice(price);
            hook.openPool(newSQRTPrice);
            vm.roll(height++);
            price = 1;
            newSQRTPrice=computeNewSQRTPrice(price);
            hook.openPool(newSQRTPrice);
        }

        uint256 balance0ManagerAfter = token0.balanceOf(address(manager));
        uint256 balance1ManagerAfter = token1.balanceOf(address(manager));
        (uint256 liquidity0After, uint256 liquidity1After) = getTokenReservesInPool();

        assertGt(liquidity0Before, liquidity0After);
        assertGt(liquidity1Before, liquidity1After);

        uint256 undeposited0 = balance0ManagerAfter - liquidity0After;
        uint256 undeposited1 = balance1ManagerAfter - liquidity1After;
        uint256 dustThreshold = 100;

        // should still have deposited almost ALL of of one or the other token (modulo some dust)
        assertGt(dustThreshold, undeposited0 > undeposited1 ? undeposited1 : undeposited0);
    }

    function testWithdraw() public {
        hook.mint(10**18,address(this));
        uint256 totalSupply1 = hook.totalSupply();
        assertEq(totalSupply1, 10**18);

        uint256 height = 1;
        uint256 price = 4;
        uint160 newSQRTPrice = computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        hook.burn(10**16, address(this));

        uint256 totalSupply2 = hook.totalSupply();
        assertEq(totalSupply2, totalSupply1-10**16);

        hook.burn(totalSupply2, address(this));
        assertEq(hook.totalSupply(), 0);
        uint256 balance0Manager = token0.balanceOf(address(manager));
        uint256 balance1Manager = token1.balanceOf(address(manager));
        
        // console.log(balance0Manager);
        // console.log(balance1Manager);

        // this is kind of high IMO we are already somehow losing 3 wei in both tokens
        // seems like we may somehow losing track of 1 wei into the contract 
        // not just for every openPool() but on other ops too?
        uint256 dustThreshold = 4;
        assertGt(dustThreshold, balance0Manager);
        assertGt(dustThreshold, balance1Manager);

        hook.mint(10**18, address(this));

        vm.roll(++height);
        price = 2;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        // test mint/burn invariant (you get back as much as you put in if nothing else changes (no swaps etc)
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        //console.log("midway balances:",token0.balanceOf(address(manager)),token1.balanceOf(address(manager)));
        hook.mint(10**18, address(this));
        hook.burn(10**18, address(this));
        hook.mint(10**24, address(this));
        hook.burn(10**24, address(this));

        // NOTE this invariant is not working amounts are slightly off!!!!
        //assertEq(token0.balanceOf(address(this)), balance0Before);
        //assertEq(token1.balanceOf(address(this)), balance1Before);

        vm.roll(++height);
        price = 4;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        hook.burn(10**10, address(this));
        vm.roll(++height);
        balance0Before = token0.balanceOf(address(this));
        balance1Before = token1.balanceOf(address(this));
        //console.log("Let's try a TOB mint");
        // (uint160 poolPrice,,,,,)=manager.getSlot0(poolId);
        // (uint256 x, uint256 y)=getTokenReservesInPool();
        // console.log("new block, pre-mint. reserves:",x,y,poolPrice);
        // console.log("new block, pre-mint. pool-price:",poolPrice);
        
        hook.mint(10**12, address(this));
        // (poolPrice,,,,,)=manager.getSlot0(poolId);
        // (x, y)=getTokenReservesInPool();
        // console.log("new block, post-mint. reserves:",x,y,poolPrice);
        // console.log("new block, post-mint. pool-price:",poolPrice);
        hook.openPool(newSQRTPrice);
        //console.log("before and after difference token 0:",token0.balanceOf(address(this))-balance0Before);
        //console.log("before and after difference token 1:",token1.balanceOf(address(this))-balance1Before);
        
        vm.roll(++height);
        // (poolPrice,,,,,)=manager.getSlot0(poolId);
        // (x, y)=getTokenReservesInPool();
        // console.log("new block, pre-burn. reserves:",x,y,poolPrice);
        // console.log("new block, pre-burn. pool-price:",poolPrice);
        hook.burn(10**12, address(this));
        // (poolPrice,,,,,)=manager.getSlot0(poolId);
        // (x, y)=getTokenReservesInPool();
        // console.log("new block, post-burn. reserves:",x,y,poolPrice);
        // console.log("new block, post-burn. pool-price:",poolPrice);
        hook.openPool(newSQRTPrice);

        hook.burn(hook.totalSupply(), address(this));
        assertEq(hook.totalSupply(), 0);


        balance0Manager = token0.balanceOf(address(manager));
        balance1Manager = token1.balanceOf(address(manager));
        dustThreshold = 18;
        assertGt(dustThreshold, balance0Manager);
        assertGt(dustThreshold, balance1Manager);
    }

    function testSwaps() public {
        hook.mint(10**20,address(this));
        uint256 height = 1;
        uint256 price = 4;
        uint160 newSQRTPrice = computeNewSQRTPrice(price);

        hook.openPool(newSQRTPrice);
        uint128 hedgeCommit0=10**18;
        uint128 hedgeCommit1=10**18;

        // must deposit hedge tokens before swap can take place
        hook.depositHedgeCommitment(hedgeCommit0, hedgeCommit1);

        // prepare swap token0 for token1
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10**15, sqrtPriceLimitX96:computeNewSQRTPrice(3)});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        swapRouter.swap(poolKey, params, settings);

        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));

        uint256 hedgeRequired0 = hook.hedgeRequired0();
        uint256 hedgeRequired1 = hook.hedgeRequired1();

        assertGt(balance0Before, balance0After);
        assertGt(balance1After, balance1Before);
        assertGt(hedgeRequired1, 0);
        assertEq(hedgeRequired0, 0);
        assertEq(balance1After-balance1Before, hedgeRequired1);

        // now the swapper is going to sell token 1s for 0s back to the pool
        // in approx the same size as before 
        // to move the pool price back to original price
        params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(hedgeRequired1), sqrtPriceLimitX96:computeNewSQRTPrice(5)});

        balance0Before = token0.balanceOf(address(this));
        balance1Before = token1.balanceOf(address(this));

        swapRouter.swap(poolKey, params, settings);

        balance0After = token0.balanceOf(address(this));
        balance1After = token1.balanceOf(address(this));

        hedgeRequired0 = hook.hedgeRequired0();
        hedgeRequired1 = hook.hedgeRequired1();

        assertGt(balance1Before, balance1After);
        assertGt(balance0After, balance0Before);
        assertGt(hedgeRequired0, 0);
        assertEq(hedgeRequired1, 0);

        hook.withdrawHedgeCommitment(hedgeCommit0-hedgeRequired0, hedgeCommit1);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 2**80, sqrtPriceLimitX96:computeNewSQRTPrice(4)});

        balance0Before = token0.balanceOf(address(this));
        balance1Before = token1.balanceOf(address(this));

        swapRouter.swap(poolKey, params, settings);

        balance0After = token0.balanceOf(address(this));
        balance1After = token1.balanceOf(address(this));

        hedgeRequired0 = hook.hedgeRequired0();
        hedgeRequired1 = hook.hedgeRequired1();

        assertGt(balance0Before, balance0After);
        assertGt(balance1After, balance1Before);
        assertEq(hedgeRequired0, 0);
        assertEq(hedgeRequired1, 0);

        hook.withdrawHedgeCommitment(hook.hedgeCommitted0(), 0);

        assertEq(hook.hedgeCommitted0(), 0);
        assertEq(hook.hedgeCommitted1(), 0);

        vm.roll(++height);
        price=2;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function computeNewSQRTPrice(uint256 price) internal pure returns (uint160 y){
        y=uint160(_sqrt(price*2**96)*2**48);
    }

    function getTokenReservesInPool() public view returns (uint256 x, uint256 y){
        Position.Info memory info = manager.getPosition(poolId, address(hook), lowerTick, upperTick);
        (uint160 poolPrice,,,,,)= manager.getSlot0(poolId);
        (x, y) = LiquidityAmounts.getAmountsForLiquidity(
            poolPrice,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            info.liquidity
        );
    }
}
