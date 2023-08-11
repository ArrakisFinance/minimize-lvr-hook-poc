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

    error AlreadyInitialized();
    error NotPoolManagerToken();
    error OnlyModifyViaHook();
    error InvalidTickBounds();
    error NotTopOfBlock();
    error InvalidTopOfBlockSwap();
    error ZeroLiquidity();

    int24 public immutable lowerTick;
    int24 public immutable upperTick;
    uint16 public immutable baseBeta;
    uint16 public immutable decayRate;

    /// @dev these could be TRANSIENT STORAGE eventually
    uint256 internal _a0;
    uint256 internal _a1;
    bool internal _modifyViaHook;
    /// ----------

    uint256 public lastBlockTouch;
    PoolKey public poolKey;
    bool public initialized;

    struct PoolManagerCallData {
        uint256 amount;
        address msgSender;
        address receiver;
        uint8 actionType; // 0 for mint, 1 for burn, 2 for arb swap
    }

    constructor(
        IPoolManager _poolManager,
        int24 _lowerTick,
        int24 _upperTick,
        uint16 _baseBeta,
        uint16 _decayRate
    ) BaseHook(_poolManager) ERC20("Diamond LP Token", "DLPT") {
        lowerTick = _lowerTick;
        upperTick = _upperTick;
        require(_baseBeta < 10000 && _decayRate < _baseBeta);
        baseBeta = _baseBeta;
        decayRate = _decayRate;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
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
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeInitialize(
        address,
        PoolKey calldata poolKey_,
        uint160
    ) external override returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        if (
            lowerTick % poolKey_.tickSpacing != 0 || 
            upperTick % poolKey_.tickSpacing != 0 || 
            lowerTick < poolKey_.tickSpacing.minUsableTick() || 
            upperTick > poolKey_.tickSpacing.maxUsableTick()
        ) revert InvalidTickBounds();

        poolKey = poolKey_;
        lastBlockTouch = block.number;
        initialized = true;

        return this.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (lastBlockTouch != block.number) revert InvalidTopOfBlockSwap();
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
        // third case arb swap action.
        if (pMCallData.actionType == 2) _lockAcquiredArb(pMCallData);
    }

    function topOfBlockSwap(
        uint256 newSqrtPriceX96_,
        address receiver_
    ) external {
        
        bytes memory data = abi.encode(
            PoolManagerCallData({
                amount: newSqrtPriceX96_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 2
            })
        );

        _modifyViaHook = true;
        poolManager.lock(data);
        _modifyViaHook = false;
    }

    function mint(
        uint256 mintAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(mintAmount_ > 0, "mint 0");

        bytes memory data = abi.encode(
            PoolManagerCallData({
                amount: mintAmount_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 0
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
                amount: burnAmount_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 1
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

    function _lockAcquiredArb(PoolManagerCallData memory pMCallData) internal {
        uint256 blockDelta = block.number - lastBlockTouch;
        if (blockDelta == 0) revert NotTopOfBlock();

        (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        uint160 newSqrtPriceX96 = SafeCast.toUint160(pMCallData.amount);
        if (sqrtPriceX96 == newSqrtPriceX96) return;

        Position.Info memory info = PoolManager(
            payable(address(poolManager))
        ).getPosition(
                PoolIdLibrary.toId(poolKey),
                address(this),
                lowerTick,
                upperTick
            );

        if (info.liquidity == 0) revert ZeroLiquidity();

        (uint256 swap0, uint256 swap1, int256 newLiquidity, bool zeroForOne) = 
            _computeArbSwap(sqrtPriceX96, newSqrtPriceX96, info.liquidity, blockDelta);

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

        lastBlockTouch = block.number;

        poolManager.swap(
            poolKey, 
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 1,
                sqrtPriceLimitX96: newSqrtPriceX96
            })
        );

        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                liquidityDelta: newLiquidity,
                tickLower: lowerTick,
                tickUpper: upperTick
            })
        );
        
        if (zeroForOne) {
            ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                pMCallData.msgSender,
                address(poolManager),
                swap0
            );
            poolManager.settle(poolKey.currency0);
            poolManager.take(
                poolKey.currency1,
                pMCallData.receiver,
                swap1
            );
        } else {
            ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                pMCallData.msgSender,
                address(poolManager),
                swap1
            );
            poolManager.settle(poolKey.currency1);
            poolManager.take(
                poolKey.currency0,
                pMCallData.receiver,
                swap0
            );
        }

        _mintIfLeftOver();
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
                SafeCast.toUint128(pMCallData.amount)
            );

            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(pMCallData.amount),
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
                pMCallData.amount,
                currency0Balance,
                totalSupply
            );
            uint256 amount1 = FullMath.mulDiv(
                pMCallData.amount,
                currency1Balance,
                totalSupply
            );

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

            uint256 liquidity = FullMath.mulDiv(pMCallData.amount, info.liquidity, totalSupply);

            if (liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: SafeCast.toInt256(liquidity),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
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
                    pMCallData.amount,
                    currency0Balance,
                    totalSupply
                );
                uint256 amount1 = FullMath.mulDiv(
                    pMCallData.amount,
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
                uint256 liquidity = uint256(info.liquidity) - FullMath.mulDiv(pMCallData.amount, info.liquidity, totalSupply);

                if (liquidity > 0)
                    poolManager.modifyPosition(
                        poolKey,
                        IPoolManager.ModifyPositionParams({
                            liquidityDelta: SafeCast.toInt256(liquidity),
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

    function _computeArbSwap(
        uint160 sqrtPriceX96,
        uint160 newSqrtPriceX96,
        uint128 liquidity,
        uint256 blockDelta
    ) internal view returns (uint256, uint256, int256, bool) {
        uint256 subtract = (blockDelta-1)*decayRate;
        uint16 factor = subtract >= baseBeta ? 10000: 10000 - (baseBeta - uint16(subtract));

        uint160 sqrtPriceX96A = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtPriceX96B = TickMath.getSqrtRatioAtTick(upperTick);

        (uint256 current0, uint256 current1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            liquidity
        );

        (uint256 new0, uint256 new1) = LiquidityAmounts.getAmountsForLiquidity(
            newSqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            liquidity
        );
        bool zeroForOne = new0 > current0;
        
        uint256 swap0 = FullMath.mulDiv(zeroForOne ? new0 - current0 : current0 - new0, factor, 10000);
        uint256 swap1 = FullMath.mulDiv(zeroForOne ? current1 - new1 : new1 - current1, factor, 10000);
        uint256 finalLiq0 = zeroForOne ? current0 + swap0 - 1 : current0 - swap0;
        uint256 finalLiq1 = zeroForOne ? current1 - swap1 : current1 + swap1 - 1;

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            finalLiq0,
            finalLiq1
        );

        return (swap0, swap1, SafeCast.toInt256(uint256(liquidity)), zeroForOne);
    }
}
