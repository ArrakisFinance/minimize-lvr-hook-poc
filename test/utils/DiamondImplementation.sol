pragma solidity ^0.8.19;

import {DiamondHookPoC} from "../../src/DiamondHookPoC.sol";

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract DiamondImplementation is DiamondHookPoC{
    constructor(IPoolManager poolManager, DiamondHookPoC addressToEtch, int24 tickSpacing, uint24 baseBeta, uint24 decayRate, uint24 vaultRedepositRate) DiamondHookPoC(poolManager,tickSpacing,baseBeta,decayRate,vaultRedepositRate) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}