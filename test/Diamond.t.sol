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
    uint24 public vaultRedepositRate=PIPS/10; // % expressed as uint < 1e6
    // we also want to pass in a minimum constant amount (maybe even a % of total pool size, so the vault eventually empties)
    // if we only ever take 1% of the vault, the vault may never empty.
    uint24 public fee=0; // % expressed as uint < 1e6

    int24 public lowerTick;
    int24 public upperTick;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        
        
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
            Currency.wrap(address(token1)),
            Currency.wrap(address(token0)),
            fee,
            tickSpacing,
            hook
        );
        poolId = poolKey.toId();
        uint256 price =1;
        manager.initialize(poolKey, computeNewSQRTPrice(price));
        swapRouter = new PoolSwapTest(manager);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        lowerTick=hook.lowerTick();
        upperTick=hook.upperTick();
        
    }


    function testArb4SwapArb1NonZeroReAdding() public {
        hook.mint(1*10**18,address(this));
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

    function testArb4SwapArb1NonZeroReAdding_Twice() public {
        hook.mint(1*10**18,address(this));
        uint256 height=1;
        vm.roll(height);
        //Letting PIPS be the multiplier on price
        uint256 price=4;

        uint160 newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        (uint160 newPrice,,,,,)=manager.getSlot0(poolId);
        vm.roll(height+1);
        price =1;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        vm.roll(height+2);
        //Letting PIPS be the multiplier on price
        price=4;

        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        vm.roll(height+3);
        price =1;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);

        console.log(token0.balanceOf(address(manager)), "poolManagerBalance0");
        console.log(token1.balanceOf(address(manager)), "poolManagerBalance1");
        console.log(token0.balanceOf(address(hook)), "hook Balance0");
        console.log(token1.balanceOf(address(hook)), "hook Balance1");
        (uint256 token0sInPool, uint256 token1sInPool)=getTokenReservesInPool();
        console.log(token0sInPool,token1sInPool, "tokenReservesInPool");
    }

    function testManyWhipSaws() public {
        hook.mint(1*10**18,address(this));
        uint256 height=1;
        uint256 price;
        uint160 newSQRTPrice;
        vm.roll(height++);
        price =4;
        newSQRTPrice=computeNewSQRTPrice(price);
        console.log(computeNewSQRTPrice(price), computeNewSQRTPrice_PIPS(price*PIPS));
        hook.openPool(newSQRTPrice);
        for(uint256 i = 0; i < 5; i++) {
            console.log(i, "pre");
            vm.roll(height++);
            price =PIPS;
            newSQRTPrice=computeNewSQRTPrice_PIPS(price);
            hook.openPool(newSQRTPrice);
            console.log(i, "mid");
            vm.roll(height++);
            price =4*PIPS;
            newSQRTPrice=computeNewSQRTPrice_PIPS(price);
            hook.openPool(newSQRTPrice);
            console.log(i, "post");
        }
        vm.roll(height++);
        price =PIPS;
        newSQRTPrice=computeNewSQRTPrice_PIPS(price);
        hook.openPool(newSQRTPrice);
        console.log(token0.balanceOf(address(manager)), "poolManagerBalance0");
        console.log(token1.balanceOf(address(manager)), "poolManagerBalance1");
        (uint256 token0sInPool, uint256 token1sInPool)=getTokenReservesInPool();
        console.log(token0sInPool,token1sInPool, "tokenReservesInPool");
        vm.roll(height++);
        price =PIPS+1;
        newSQRTPrice=computeNewSQRTPrice_PIPS(price);
        hook.openPool(newSQRTPrice);
        ( token0sInPool, token1sInPool)=getTokenReservesInPool();
        console.log(token0sInPool,token1sInPool, "tokenReservesInPool");
        
    }

    function testWithdraw() public {
        hook.mint(1*10**18,address(this));
        uint256 height=1;
        uint256 price=4;
        uint160 newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);
        hook.burn(10**16, address(this));
        vm.roll(++height);
        price=2;
        newSQRTPrice=computeNewSQRTPrice(price);
        hook.openPool(newSQRTPrice);
        hook.burn(10**16, address(this));
        hook.mint(1*10**18,address(this));
        vm.roll(++height);
        price=10;
        hook.openPool(newSQRTPrice);
        hook.burn(10**18, address(this));   
    }

    // this version only works when fee=0
    // when fee !=0, both hedgeRequire variables can be positive
    // what can we do to get around this....
    function testSwaps() public {
        hook.mint(1*10**20,address(this));
        uint256 height=1;
        uint256 price=4;
        uint160 newSQRTPrice=computeNewSQRTPrice(price);

        hook.openPool(newSQRTPrice);
        uint128 hedgeCommit0=10**18;
        uint128 hedgeCommit1=10**18;
        //must deposit dege tokens before swap can take place
        hook.depositHedgeCommitment(hedgeCommit0, hedgeCommit1);

        
        console.log("initiate a swap to buy token 1s");
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10**15, sqrtPriceLimitX96:computeNewSQRTPrice(3)});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        swapRouter.swap(poolKey, params, settings);


        //now the swapper is going to sell token 1s for 0s back to the pool
        // in approx the same size as before 
        // to move the pool price back to original price
        uint256 hedgeRequired0=uint256(hook.hedgeRequired0());
        uint256 hedgeRequired1=uint256(hook.hedgeRequired1());
        console.log("hedge required after first swap",hedgeRequired0, hedgeRequired1);
        console.log("initiate another swap to sell back the token 0s");
        params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(hedgeRequired1), sqrtPriceLimitX96:computeNewSQRTPrice(5)});
        //params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: int256((token1sInPoolStart-token1sInPoolAfterSwap1)*(PIPS+fee)/PIPS), sqrtPriceLimitX96:computeNewSQRTPrice(5)});
        
        swapRouter.swap(poolKey, params, settings);
        hedgeRequired0=uint256(hook.hedgeRequired0());
        hedgeRequired1=uint256(hook.hedgeRequired1());
        console.log("hedge required after second swap",hedgeRequired0, hedgeRequired1);


        // hook contract retains 1 wei to perform the kick in the next block
        // this is the reason for the -1
        // using hardcoded hedge committed values for other checks
        if (hook.hedgeRequired0()>0){
            hook.withdrawHedgeCommitment(hedgeCommit0-uint128(uint256((hook.hedgeRequired0())))-1, hedgeCommit1);
        }else{
            hook.withdrawHedgeCommitment(hedgeCommit0,hedgeCommit1-uint128(uint256((hook.hedgeRequired1())))-1);
        }

        console.log("go to next block and arb to a new price as a sense check");
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

    function computeNewSQRTPrice_PIPS(uint256 price) internal pure returns (uint160 y){
        y=uint160((_sqrt(price*2**96)*2**48)/_sqrt(PIPS));
    }

    function computeDecPriceFromNewSQRTPrice_PIPS(uint160 price) internal pure returns (uint256 y){
        y=FullMath.mulDiv(PIPS*uint256(price)**2,1,2**192);
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