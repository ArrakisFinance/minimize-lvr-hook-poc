// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";
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


import {DiamondHookPoC} from "../src/DiamondHookPoC.sol";
import {DiamondImplementation} from "./utils/DiamondImplementation.sol";


contract TestDiamond is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    address hookAddress;
    TestERC20 token0;
    TestERC20 token1;
    PoolId poolId;
    DiamondHookPoC hook= DiamondHookPoC(address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.BEFORE_SWAP_FLAG |Hooks.AFTER_SWAP_FLAG
                )
            ));
    PoolKey poolKey;

    PoolSwapTest swapRouter;

    uint24 constant PIPS=1000000;
    int24 public tickSpacing=60;
    uint24 public baseBeta=PIPS/2; // % expressed as uint < 1e6
    uint24 public decayRate=PIPS/10; // % expressed as uint < 1e6
    uint24 public vaultRedepositRate=0; // % expressed as uint < 1e6
    uint24 public fee=PIPS/300; // % expressed as uint < 1e6

    int24 public lowerTick;
    int24 public upperTick;

    function setUp() public {
        token1 = new TestERC20(2**128);
        token0 = new TestERC20(2**128);
        
        manager = new PoolManager(500000);

        DiamondImplementation impl = new DiamondImplementation(manager, hook,tickSpacing,baseBeta,decayRate,vaultRedepositRate);
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
        manager.initialize(poolKey, SQRT_RATIO_1_1);
        swapRouter = new PoolSwapTest(manager);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        lowerTick=hook.lowerTick();
        upperTick=hook.upperTick();
        
    }



    function testArb4SwapArb1() public {
        hook.mint(1*10**18,address(hook));
        console.log(manager.getLiquidity(poolId), "liquidity");
        uint256 height=1;
        vm.roll(height);
        //Letting PIPS be the multiplier on price
        uint256 price=4;

        uint160 newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        (uint160 newPrice,,,,,)=manager.getSlot0(poolId);
        //For getting prices
        console.log(newPrice, "new Price in x96");
        console.log(computeDecPriceFromNewSQRTPrice(newPrice),"new Price in decimal");

        console.log(token0.balanceOf(address(manager)), "poolManagerBalance0");
        console.log(token1.balanceOf(address(manager)), "poolManagerBalance1");
        console.log(token0.balanceOf(address(hook)), "hook Balance0");
        console.log(token1.balanceOf(address(hook)), "hook Balance1");
        console.log(manager.getLiquidity(poolId), "liquidity");
        // go to next block
        vm.roll(height+1);
        price =1;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        (newPrice,,,,,)=manager.getSlot0(poolId);
        
        //For getting prices
        console.log(newPrice, "new Price in x96");
        console.log(computeDecPriceFromNewSQRTPrice(newPrice),"new Price in decimal");

        //For getting active token reserves in the pool
        
        // pushing from 1 to 4 to 1 with Beta 0.5
        // and vaultDepositRate 0 
        // should give us reserves
        // of (15/16 * 10**18, 15/16 * 10**18), and
        // vault tokens (0, 3/16 * 10**18)
        // The discrepancy is because 
        // we don't try to add vault tokens back into the pool 
        // after an arb swap.
        // If we have pool price p, and a vault with both tokens,
        // we want to add as much liquidity at price p back into the 
        // pool.
        console.log(token0.balanceOf(address(manager)), "poolManagerBalance0");
        console.log(token1.balanceOf(address(manager)), "poolManagerBalance1");
        console.log(token0.balanceOf(address(hook)), "hook Balance0");
        console.log(token1.balanceOf(address(hook)), "hook Balance1");
        (uint256 token0sInPool, uint256 token1sInPool)=getTokenReservesInPool();
        console.log(token0sInPool,token1sInPool, "tokenReservesInPool");
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
    function computeDecPriceFromNewSQRTPrice(uint160 price) internal pure returns (uint256 y){
        y=FullMath.mulDiv(uint256(price)**2,1,2**192);
    }

    function getTokenReservesInPool() public returns (uint256 x, uint256 y){
        uint256 liquidity = manager.getLiquidity(poolId);
        (uint160 poolPrice,,,,,)=manager.getSlot0(poolId);
        uint256 sqrtPoolPriceDecimals= _sqrt(computeDecPriceFromNewSQRTPrice(poolPrice));
        x=FullMath.mulDiv(liquidity,1,sqrtPoolPriceDecimals);
        y=liquidity*sqrtPoolPriceDecimals;
    }



}