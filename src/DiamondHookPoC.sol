// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ERC20} from "v4-periphery/../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract DiamondHookPoC is BaseHook, ERC20 {
    using PoolIdLibrary for IPoolManager.PoolKey;

    bool internal modifyViaHook;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) ERC20("Diamond LP Token", "DLPT") {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeSwap(address, IPoolManager.PoolKey calldata, IPoolManager.SwapParams calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(address, IPoolManager.PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta)
        external
        pure
        override
        returns (bytes4)
    {
        return BaseHook.afterSwap.selector;
    }

    /// @dev force LPs to provide liquidity through hook by adding some requirements here ??
    function beforeModifyPosition(address, IPoolManager.PoolKey calldata, IPoolManager.ModifyPositionParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(modifyViaHook, "Must mint liquidity via hook");
        return BaseHook.beforeModifyPosition.selector;
    }
}
