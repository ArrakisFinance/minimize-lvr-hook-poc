// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

abstract contract BaseFactory {
    /// @notice zero out all but the first byte of the address which is all 1's
    uint160 public constant UNISWAP_FLAG_MASK = 0xff << 152;

    // Uniswap hook contracts must have specific flags encoded in the first byte of their address
    address public immutable TargetPrefix;

    constructor(address _targetPrefix) {
        TargetPrefix = _targetPrefix;
    }

    function deploy(IPoolManager poolManager, bytes32 salt) public virtual returns (address);

    function mineDeploy(IPoolManager poolManager) external returns (address) {
        return deploy(poolManager,0);
    }




    function _computeHookAddress(IPoolManager poolManager, bytes32 salt) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, _hashBytecode(poolManager)));
        return address(uint160(uint256(hash)));
    }

    /// @dev The implementing contract must override this function to return the bytecode hash of its contract
    /// For example, the CounterHook contract would return:
    /// bytecodeHash = keccak256(abi.encodePacked(type(CounterHook).creationCode, abi.encode(poolManager)));
    function _hashBytecode(IPoolManager poolManager) internal pure virtual returns (bytes32 bytecodeHash);

    function _isPrefix(address _address) internal view returns (bool) {
        // zero out all but the first byte of the address
        address actualPrefix = address(uint160(_address) & UNISWAP_FLAG_MASK);
        return actualPrefix == TargetPrefix;
    }
}
