// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DiamondHookPoC is BaseHook, ERC20, IERC1155Receiver, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TickMath for int24;
    using Pool for Pool.State;
    using SafeERC20 for ERC20;
    using SafeERC20 for PoolManager;

    error NotPoolManagerToken();
    error OnlyModifyViaHook();

    /// @dev these could be TRANSIENT STORAGE eventually
    bool internal _modifyViaHook;
    uint256 internal _a0;
    uint256 internal _a1;
    /// ----------

    PoolKey public poolKey;
    int24 public lowerTick;
    int24 public upperTick;
    uint256 public lastBlockTouch;

    struct PoolManagerCallData {
        uint8 actionType; // 0 for mint, 1 for burn, 2 for rebalance.
        uint256 mintAmount;
        uint256 burnAmount;
        address receiver;
        address msgSender;
        bytes customPayload;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) ERC20("Diamond LP Token", "DLPT") {}

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManagerToken();
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    function supportsInterface(bytes4) external view returns (bool) {
        return true;
    }

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

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata)
        external
        pure
        override
        returns (bytes4)
    {
        /// TODO !!!
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta)
        external
        pure
        override
        returns (bytes4)
    {
        /// TODO !!!
        return BaseHook.afterSwap.selector;
    }

    function beforeModifyPosition(address, PoolKey calldata, IPoolManager.ModifyPositionParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        /// @dev force LPs to provide liquidity through hook
        if (!_modifyViaHook) revert OnlyModifyViaHook();
        return BaseHook.beforeModifyPosition.selector;
    }

    function lockAcquired(
        uint256,
        /* id */ bytes calldata data_
    ) external poolManagerOnly returns (bytes memory) {
        PoolManagerCallData memory pMCallData = abi.decode(
            data_,
            (PoolManagerCallData)
        );
        // first case mint
        if (pMCallData.actionType == 0) _lockAcquiredMint(pMCallData);
        // second case burn action.
        if (pMCallData.actionType == 1) _lockAcquiredBurn(pMCallData);
    }

    function mint(
        uint256 mintAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(mintAmount_ > 0, "mint 0");

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 0,
                mintAmount: mintAmount_,
                burnAmount: 0,
                receiver: receiver_,
                msgSender: msg.sender,
                customPayload: ""
            })
        );

        _a0 = _a1 = 0;
        
        _modifyViaHook = true;
        poolManager.lock(data);
        _modifyViaHook = false;

        amount0 = _a0;
        amount1 = _a1;

        _mint(receiver_, mintAmount_);
    }

    function burn(
        uint256 burnAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(burnAmount_ > 0, "burn 0");
        require(totalSupply() > 0, "total supply is 0");

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 1,
                mintAmount: 0,
                burnAmount: burnAmount_,
                receiver: receiver_,
                msgSender: msg.sender,
                customPayload: ""
            })
        );

        _a0 = _a1 = 0;

        _modifyViaHook = true;
        poolManager.lock(data);
        _modifyViaHook = false;

        amount0 = _a0;
        amount1 = _a1;

        _burn(msg.sender, burnAmount_);
    }

    function _lockAcquiredMint(PoolManagerCallData memory pMCallData) internal {
        // burn everything positions and erc1155

        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                PoolIdLibrary.toId(poolKey)
            );
            uint160 sqrtPriceX96A = TickMath.getSqrtRatioAtTick(lowerTick);
            uint160 sqrtPriceX96B = TickMath.getSqrtRatioAtTick(upperTick);
            (_a0, _a1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceX96A,
                sqrtPriceX96B,
                SafeCast.toUint128(pMCallData.mintAmount)
            );

            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(pMCallData.mintAmount),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );

            if (_a0 > 0) {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    _a0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (_a1 > 0) {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    _a1
                );
                poolManager.settle(poolKey.currency1);
            }

            _mintIfLeftOver();
        } else {
            Position.Info memory info = PoolManager(
                payable(address(poolManager))
            ).getPosition(
                    PoolIdLibrary.toId(poolKey),
                    address(this),
                    lowerTick,
                    upperTick
                );

            if (info.liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(
                            uint256(info.liquidity)
                        ),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            uint256 currency0Id = CurrencyLibrary.toId(poolKey.currency0);
            uint256 leftOver0 = poolManager.balanceOf(
                address(this),
                currency0Id
            );

            if (leftOver0 > 0)
                PoolManager(payable(address(poolManager))).safeTransferFrom(
                    address(this),
                    address(poolManager),
                    currency0Id,
                    leftOver0,
                    ""
                );

            uint256 currency1Id = CurrencyLibrary.toId(poolKey.currency1);
            uint256 leftOver1 = poolManager.balanceOf(
                address(this),
                currency1Id
            );
            if (leftOver1 > 0)
                PoolManager(payable(address(poolManager))).safeTransferFrom(
                    address(this),
                    address(poolManager),
                    currency1Id,
                    leftOver1,
                    ""
                );

            // check locker balances.

            int256 currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            uint256 currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            uint256 currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            uint256 amount0 = FullMath.mulDiv(
                pMCallData.mintAmount,
                currency0Balance,
                totalSupply
            );
            uint256 amount1 = FullMath.mulDiv(
                pMCallData.mintAmount,
                currency1Balance,
                totalSupply
            );

            // safeTransfer to PoolManager.
            if (amount0 > 0) {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    amount0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (amount1 > 0) {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    amount1
                );
                poolManager.settle(poolKey.currency1);
            }

            _a0 = amount0;
            _a1 = amount1;

            // updated total balances.
            currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            // mint back the position.

            (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                PoolIdLibrary.toId(poolKey)
            );

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                currency0Balance,
                currency1Balance
            );

            if (liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: SafeCast.toInt256(uint256(liquidity)),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            _mintIfLeftOver();
        }
    }

    function _lockAcquiredBurn(PoolManagerCallData memory pMCallData) internal {
        {
            ///@dev burn everything, positions and erc1155

            uint256 totalSupply = totalSupply();

            Position.Info memory info = PoolManager(
                payable(address(poolManager))
            ).getPosition(
                    PoolIdLibrary.toId(poolKey),
                    address(this),
                    lowerTick,
                    upperTick
                );

            if (info.liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(
                            uint256(info.liquidity)
                        ),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            {
                uint256 currency0Id = CurrencyLibrary.toId(poolKey.currency0);
                uint256 leftOver0 = poolManager.balanceOf(
                    address(this),
                    currency0Id
                );

                if (leftOver0 > 0)
                    PoolManager(payable(address(poolManager))).safeTransferFrom(
                        address(this),
                        address(poolManager),
                        currency0Id,
                        leftOver0,
                        ""
                    );

                uint256 currency1Id = CurrencyLibrary.toId(poolKey.currency1);
                uint256 leftOver1 = poolManager.balanceOf(
                    address(this),
                    currency1Id
                );

                if (leftOver1 > 0)
                    PoolManager(payable(address(poolManager))).safeTransferFrom(
                        address(this),
                        address(poolManager),
                        currency1Id,
                        leftOver1,
                        ""
                    );
            }

            // check locker balances.

            int256 currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
            if (currency0BalanceRaw > 0) {
                revert("cannot delta currency0 positive");
            }
            uint256 currency0Balance = SafeCast.toUint256(-currency0BalanceRaw);
            int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
            if (currency1BalanceRaw > 0) {
                revert("cannot delta currency1 positive");
            }
            uint256 currency1Balance = SafeCast.toUint256(-currency1BalanceRaw);

            {
                uint256 amount0 = FullMath.mulDiv(
                    pMCallData.burnAmount,
                    currency0Balance,
                    totalSupply
                );
                uint256 amount1 = FullMath.mulDiv(
                    pMCallData.burnAmount,
                    currency1Balance,
                    totalSupply
                );

                // take amounts and send them to receiver
                if (amount0 > 0) {
                    poolManager.take(
                        poolKey.currency0,
                        pMCallData.receiver,
                        amount0
                    );
                }
                if (amount1 > 0) {
                    poolManager.take(
                        poolKey.currency1,
                        pMCallData.receiver,
                        amount1
                    );
                }

                _a0 = amount0;
                _a1 = amount1;
            }

            // mint back the position.

            // updated total balances.
            currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            {
                (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                    PoolIdLibrary.toId(poolKey)
                );

                uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(lowerTick),
                    TickMath.getSqrtRatioAtTick(upperTick),
                    currency0Balance,
                    currency1Balance
                );

                if (liquidity > 0)
                    poolManager.modifyPosition(
                        poolKey,
                        IPoolManager.ModifyPositionParams({
                            liquidityDelta: SafeCast.toInt256(
                                uint256(liquidity)
                            ),
                            tickLower: lowerTick,
                            tickUpper: upperTick
                        })
                    );
            }

            _mintIfLeftOver();
        }
    }

    function _mintIfLeftOver() internal {
        int256 currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
        if (currency0BalanceRaw > 0) {
            revert("cannot delta currency0 positive");
        }
        uint256 leftOver0 = SafeCast.toUint256(-currency0BalanceRaw);
        int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
        if (currency1BalanceRaw > 0) {
            revert("cannot delta currency1 positive");
        }
        uint256 leftOver1 = SafeCast.toUint256(-currency1BalanceRaw);

        if (leftOver0 > 0) {
            poolManager.mint(poolKey.currency0, address(this), leftOver0);
        }

        if (leftOver1 > 0) {
            poolManager.mint(poolKey.currency1, address(this), leftOver1);
        }
    }
}