// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;


import {console} from "forge-std/console.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {FeeLibrary} from "@uniswap/v4-core/contracts/libraries/FeeLibrary.sol";
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

import {BaseFactory} from "./BaseFactory.sol";

contract DiamondHookPoC is BaseHook, ERC20, IERC1155Receiver, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using FeeLibrary for uint24;
    using TickMath for int24;
    using Pool for Pool.State;
    using SafeERC20 for ERC20;
    using SafeERC20 for PoolManager;

    error AlreadyInitialized();
    error NotPoolManagerToken();
    error InvalidTickSpacing();
    error InvalidMsgValue();
    error OnlyModifyViaHook();
    error PoolAlreadyOpened();
    error PoolNotOpen();
    error ArbTooSmall();
    error LiquidityZero();
    error InsufficientHedgeCommitted();
    error MintZero();
    error BurnZero();
    error BurnExceedsSupply();
    error WithdrawExceedsAvailable();
    error OnlyCommitter();
    error PriceOutOfBounds();

    uint24 internal constant _PIPS = 1000000;

    int24 public immutable lowerTick;
    int24 public immutable upperTick;
    int24 public immutable tickSpacing;
    uint24 public immutable baseBeta; // % expressed as uint < 1e6
    uint24 public immutable decayRate; // % expressed as uint < 1e6
    uint24 public immutable vaultRedepositRate; // % expressed as uint < 1e6

    /// @dev these could be TRANSIENT STORAGE eventually
    uint256 internal _a0;
    uint256 internal _a1;
    /// ----------

    uint256 public lastBlockOpened;
    uint256 public lastBlockReset;
    int256 public hedgeRequired0;
    int256 public hedgeRequired1;
    uint160 public committedSqrtPriceX96;
    uint128 public hedgeCommitted0;
    uint128 public hedgeCommitted1;
    PoolKey public poolKey;
    PoolId public poolId;
    address public committer;
    bool public initialized;

    struct PoolManagerCalldata {
        uint256 amount; /// mintAmount | burnAmount | newSqrtPriceX96 (inferred from actionType)
        address msgSender;
        address receiver;
        uint8 actionType; /// 0 = mint | 1 = burn | 2 = arbSwap
    }

    struct ArbSwapParams {
        uint160 sqrtPriceX96;
        uint160 newSqrtPriceX96;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint128 liquidity;
        uint24 betaFactor;
    }

    constructor(
        IPoolManager _poolManager,
        int24 _tickSpacing,
        uint24 _baseBeta,
        uint24 _decayRate,
        uint24 _vaultRedepositRate
    ) BaseHook(_poolManager) ERC20("Diamond LP Token", "DLPT") {
        lowerTick = _tickSpacing.minUsableTick();
        upperTick = _tickSpacing.maxUsableTick();
        tickSpacing = _tickSpacing;
        require(_baseBeta < _PIPS && _decayRate <= _baseBeta && _vaultRedepositRate < _PIPS);
        baseBeta = _baseBeta;
        decayRate = _decayRate;
        vaultRedepositRate = _vaultRedepositRate;
        poolId=poolKey.toId();
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
        uint160 sqrtPriceX96
    ) external override returns (bytes4) {
        /// can only initialize one pool once.

        if (initialized) revert AlreadyInitialized();

        /// validate tick bounds on pool initialization
        if (poolKey_.tickSpacing != tickSpacing) revert InvalidTickSpacing();

        /// initialize state variable
        poolKey = poolKey_;
        lastBlockOpened = block.number-1;
        lastBlockReset = block.number;
        committedSqrtPriceX96 = sqrtPriceX96;
        initialized = true;

        return this.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        /// if swap is coming from the hook then its a 1 wei swap to kick the price and not a "normal" swap
        if (sender != address(this)) {
            /// disallow normal swaps at top of block
            if (lastBlockOpened != block.number) revert PoolNotOpen();
        }
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta delta)
        external
        override
        returns (bytes4)
    {
        /// if swap is coming from the hook then its a 1 wei swap to kick the price and not a "normal" swap
        if (sender != address(this)) {
            /// cannot move price to edge of LP positin
            (, int24 tick, , , , ) = poolManager.getSlot0(
                PoolIdLibrary.toId(poolKey)
            );
            if (tick >= upperTick || tick <= lowerTick) revert PriceOutOfBounds();
            
            /// NOTE this assumes static fees !!!
            uint24 fee = poolKey.fee.getStaticFee();
            
            /// infer swap direction
            bool zeroForOne = delta.amount0() < 0;
            if (zeroForOne) {
                int256 amount0LessFee = SafeCast.toInt256(FullMath.mulDiv(uint128(-delta.amount0()), _PIPS - fee, _PIPS));
                hedgeRequired0 -= amount0LessFee;
                hedgeRequired1 += int256(delta.amount1());
            } else {
                int256 amount1LessFee = SafeCast.toInt256(FullMath.mulDiv(uint128(-delta.amount1()), _PIPS - fee, _PIPS));
                hedgeRequired1 -= amount1LessFee;
                hedgeRequired0 += int256(delta.amount0());
            }

            /// the extra +1 here is to handle the 1 wei swap which would be necessary to move pool price back to committedSqrtPriceX96 at top of next block
            if (hedgeRequired0 > 0) {
                if (hedgeRequired0+1 > int256(uint256(hedgeCommitted0))) revert InsufficientHedgeCommitted();
            } else if (hedgeRequired1 > 0) {
                if (hedgeRequired1+1 > int256(uint256(hedgeCommitted1))) revert InsufficientHedgeCommitted();
            } else {
                /// sanity check that if neither hedgeRequrired0 or hedgeRequired1 are positive then both must be 0
                if (hedgeRequired0 != 0 || hedgeRequired1 != 0) revert("should not be possible");
            }
        }

        return BaseHook.afterSwap.selector;
    }

    function beforeModifyPosition(address sender, PoolKey calldata, IPoolManager.ModifyPositionParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        /// force LPs to provide liquidity through hook
        if (sender != address(this)) revert OnlyModifyViaHook();
        return BaseHook.beforeModifyPosition.selector;
    }

    /// method called back on PoolManager.lock()
    function lockAcquired(
        bytes calldata data_
    ) external poolManagerOnly override returns (bytes memory) {
        /// decode calldata passed through lock()

        PoolManagerCalldata memory pmCalldata = abi.decode(
            data_,
            (PoolManagerCalldata)
        );
        /// first case mint action
        if (pmCalldata.actionType == 0) _lockAcquiredMint(pmCalldata);
        /// second case burn action
        if (pmCalldata.actionType == 1) _lockAcquiredBurn(pmCalldata);
        /// third case arbSwap action
        if (pmCalldata.actionType == 2) _lockAcquiredArb(pmCalldata);
    }

    /// anyone can call this method to "open the pool" with top of block arb swap.
    /// no swaps will be processed in a block unless this method is called first in that block.
    function openPool(uint160 newSqrtPriceX96_) external payable nonReentrant {
        /// encode calldata to pass through lock()
        bytes memory data = abi.encode(
            PoolManagerCalldata({
                amount: uint256(newSqrtPriceX96_),
                msgSender: msg.sender,
                receiver: msg.sender,
                actionType: 2 /// arbSwap action
            })
        );

        /// begin pool actions (passing data through lock() into _lockAcquiredArb())
        poolManager.lock(data);

        committer = msg.sender;
        committedSqrtPriceX96 = newSqrtPriceX96_;
        lastBlockOpened = block.number;

        /// handle eth refunds (question: may not be necessary as block producer should know exactly the amount of eth needed ??)
        if (poolKey.currency0.isNative()) {
            uint256 leftover = address(this).balance;
            if (leftover > 0) _nativeTransfer(msg.sender, leftover);
        }
        if (poolKey.currency1.isNative()) {
            uint256 leftover = address(this).balance;
            if (leftover > 0) _nativeTransfer(msg.sender, leftover);
        }
    }

    function depositHedgeCommitment(uint128 amount0, uint128 amount1) external payable {
        if (lastBlockOpened != block.number) revert PoolNotOpen();

        if (amount0 > 0) {
            if (poolKey.currency0.isNative()) {
                if (msg.value != amount0) revert InvalidMsgValue();
            } else {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount0
                );
            }
            hedgeCommitted0 += amount0;
        }

        if (amount1 > 0) {
            if (poolKey.currency1.isNative()) {
                if (msg.value != amount1) revert InvalidMsgValue();
            } else {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount1
                );
            }
            hedgeCommitted1 += amount1;
        }
    }

    function withdrawHedgeCommitment(uint128 amount0, uint128 amount1) external nonReentrant {
        if (committer != msg.sender) revert OnlyCommitter();

        if (amount0 > 0) {
            uint256 withdrawAvailable0 = hedgeRequired0 > 0 ? hedgeCommitted0 - uint256(hedgeRequired0) - 1 : hedgeCommitted0;
            if (amount0 > withdrawAvailable0) revert WithdrawExceedsAvailable();
            hedgeCommitted0 -= amount0;
            if (poolKey.currency0.isNative()) {
                _nativeTransfer(msg.sender, amount0);
            } else {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(
                    msg.sender,
                    amount0
                );
            }
        }

        if (amount1 > 0) {
            uint256 withdrawAvailable1 = hedgeRequired1 > 0 ? hedgeCommitted1 - uint256(hedgeRequired1) - 1 : hedgeCommitted1;
            if (amount1 > withdrawAvailable1) revert WithdrawExceedsAvailable();
            hedgeCommitted1 -= amount1;
            if (poolKey.currency1.isNative()) {
                _nativeTransfer(msg.sender, amount1);
            } else {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(
                    msg.sender,
                    amount1
                );
            }
        }
    }

    /// how LPs add and remove liquidity into the hook
    function mint(
        uint256 mintAmount_,
        address receiver_
    ) external payable nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (mintAmount_ == 0) revert MintZero();
        
        /// encode calldata to pass through lock()
        bytes memory data = abi.encode(
            PoolManagerCalldata({
                amount: mintAmount_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 0 /// mint action
            })
        );
        /// state variables to be able to bubble up amount0 and amount1 as return args
        _a0 = _a1 = 0;

        /// begin pool actions (passing data through lock() into _lockAcquiredMint())
        poolManager.lock(data);

        /// handle eth refunds
        if (poolKey.currency0.isNative()) {
            uint256 leftover = address(this).balance - hedgeCommitted0;
            if (leftover > 0) _nativeTransfer(msg.sender, leftover);
        }
        if (poolKey.currency1.isNative()) {
            uint256 leftover = address(this).balance - hedgeCommitted1;
            if (leftover > 0) _nativeTransfer(msg.sender, leftover);
        }

        /// set return arguments (stored during lock callback)
        amount0 = _a0;
        amount1 = _a1;

        /// remit ERC20 liquidity shares to target receiver
        _mint(receiver_, mintAmount_);
    }

    function burn(
        uint256 burnAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (burnAmount_ == 0) revert BurnZero();
        if (totalSupply() < burnAmount_) revert BurnExceedsSupply();

        /// encode calldata to pass through lock()
        bytes memory data = abi.encode(
            PoolManagerCalldata({
                amount: burnAmount_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 1 // burn action
            })
        );

        /// state variables to be able to bubble up amount0 and amount1 as return args
        _a0 = _a1 = 0;

        /// begin pool actions (passing data through lock() into _lockAcquiredBurn())
        poolManager.lock(data);

        /// set return arguments (stored during lock callback)
        amount0 = _a0;
        amount1 = _a1;

        /// burn ERC20 LP shares of the caller
        _burn(msg.sender, burnAmount_);
    }

    function _lockAcquiredArb(PoolManagerCalldata memory pmCalldata) internal {
        uint256 blockDelta = _checkLastOpen();

        (
            uint160 sqrtPriceX96Real,
            uint160 sqrtPriceX96Virtual,
            uint128 liquidityReal,
            uint128 liquidityVirtual
        ) = _resetLiquidity(false);

        uint160 newSqrtPriceX96 = SafeCast.toUint160(pmCalldata.amount);

        /// compute swap amounts, swap direction, and amount of liquidity to mint
        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(upperTick);
        {
            (uint256 swap0, uint256 swap1) = _getArbSwap(
                ArbSwapParams({
                    sqrtPriceX96: sqrtPriceX96Virtual,
                    newSqrtPriceX96: newSqrtPriceX96,
                    sqrtPriceX96Lower: sqrtPriceX96Lower,
                    sqrtPriceX96Upper: sqrtPriceX96Upper,
                    liquidity: liquidityVirtual,
                    betaFactor: _getBeta(blockDelta)
                })
            );

            /// burn all liquidity
            if (liquidityReal > 0) {
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(uint256(liquidityReal)),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );
                _clear1155Balances();
            }

            /// swap 1 wei in zero liquidity to kick the price to newSqrtPriceX96
            bool zeroForOne = newSqrtPriceX96 < sqrtPriceX96Virtual;
            if (newSqrtPriceX96 != sqrtPriceX96Real) {
                bool zeroForOneReal = newSqrtPriceX96 < sqrtPriceX96Real;
                poolManager.swap(
                    poolKey, 
                    IPoolManager.SwapParams({
                        zeroForOne: zeroForOneReal,
                        amountSpecified: 1,
                        sqrtPriceLimitX96: newSqrtPriceX96
                    })
                );

                // Conor
                // 0/1 ERROR ???
                if (zeroForOneReal) {
                    if (zeroForOne) {
                        swap0 += 1;
                    } else {
                        swap0 -= 1;
                    }
                } else {
                    if (zeroForOne) {
                        swap1 -= 1;
                    } else {
                        swap1 += 1;
                    }
                }
            }

            /// handle swap transfers (send to / transferFrom arber)
            if (zeroForOne) {
                /// transfer swapInAmt to PoolManager
                _transferFromOrTransferNative(
                    poolKey.currency0,
                    pmCalldata.msgSender,
                    address(poolManager),
                    swap0
                );
                poolManager.settle(poolKey.currency0);
                
                /// transfer swapOutAmt to arber
                poolManager.take(
                    poolKey.currency1,
                    pmCalldata.receiver,
                    swap1
                );
            } else {
                /// transfer swapInAmt to PoolManager
                
                _transferFromOrTransferNative(
                    poolKey.currency1,
                    pmCalldata.msgSender,
                    address(poolManager),
                    swap1
                );
                // CONOR
                // THIS SETTLE SEEMS TO BE FAULTY
                // it was faulty at one point...
                poolManager.settle(poolKey.currency1);
                /// transfer swapOutAmt to arber
                poolManager.take(
                    poolKey.currency0,
                    pmCalldata.receiver,
                    swap0
                );
            }
        }

        (uint256 totalHoldings0, uint256 totalHoldings1) = _checkCurrencyBalances();

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            sqrtPriceX96Lower,
            sqrtPriceX96Upper,
            totalHoldings0,
            totalHoldings1
        );

        /// mint new liquidity around newSqrtPriceX96
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                liquidityDelta: SafeCast.toInt256(uint256(newLiquidity)),
                tickLower: lowerTick,
                tickUpper: upperTick
            })
        );
        
        /// if any positive balances remain in PoolManager after all operations, mint erc1155 shares
        _mintLeftover();
    }

    function _lockAcquiredMint(PoolManagerCalldata memory pmCalldata) internal {
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(pmCalldata.amount),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );

            // casting to uint256 is ok for minting
            // needed to get around a rounding error
            _a0=uint256(poolManager.currencyDelta(address(this),poolKey.currency0));
            _a1=uint256(poolManager.currencyDelta(address(this),poolKey.currency1));
            if (_a0 > 0) {
                _transferFromOrTransferNative(
                    poolKey.currency0,
                    pmCalldata.msgSender,
                    address(poolManager),
                    _a0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (_a1 > 0) {
                _transferFromOrTransferNative(
                    poolKey.currency1,
                    pmCalldata.msgSender,
                    address(poolManager),
                    _a1
                );
                poolManager.settle(poolKey.currency1);
            }
        } else {
            uint128 liquidity;
            /// if this is first touch in this block, then we need to _resetLiquidity() first
            if (lastBlockOpened != block.number) {
                ( , , liquidity,) = _resetLiquidity(true);
            } else {
                Position.Info memory info = PoolManager(
                    payable(address(poolManager))
                ).getPosition(
                        PoolIdLibrary.toId(poolKey),
                        address(this),
                        lowerTick,
                        upperTick
                    );
                liquidity = info.liquidity;
            }

            if (liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(uint256(liquidity)),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            _clear1155Balances();

            (uint256 currency0Balance, uint256 currency1Balance) = _checkCurrencyBalances();

            uint256 amount0 = FullMath.mulDiv(
                pmCalldata.amount,
                currency0Balance,
                totalSupply
            );
            uint256 amount1 = FullMath.mulDiv(
                pmCalldata.amount,
                currency1Balance,
                totalSupply
            );

            _a0 = amount0;
            _a1 = amount1;

            // mint back the position.
            uint256 newLiquidity = liquidity + FullMath.mulDiv(pmCalldata.amount, liquidity, totalSupply);

            if (newLiquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: SafeCast.toInt256(newLiquidity),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            if (amount0 > 0) {
                _transferFromOrTransferNative(
                    poolKey.currency0,
                    pmCalldata.msgSender,
                    address(poolManager),
                    amount0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (amount1 > 0) {
                _transferFromOrTransferNative(
                    poolKey.currency1,
                    pmCalldata.msgSender,
                    address(poolManager),
                    amount1
                );
                poolManager.settle(poolKey.currency1);
            }
        }
        _mintLeftover();

        if (hedgeRequired0 > 0) {
            hedgeRequired0 += SafeCast.toInt256(FullMath.mulDiv(uint256(hedgeRequired0), pmCalldata.amount, totalSupply));
        }
        if (hedgeRequired1 > 0) {
            hedgeRequired1 += SafeCast.toInt256(FullMath.mulDiv(uint256(hedgeRequired1), pmCalldata.amount, totalSupply));
        }
    }

    // this function gets the supply of LP tokens, the supply of LP tokens to removes,
    // the total amount of tokens owned by the poolManager (liquidity + vault), 
    // and takes remove token amt/total token amt from all controlled tokens.
    function _lockAcquiredBurn(PoolManagerCalldata memory pmCalldata) internal {
        /// burn everything, positions and erc1155
        uint256 totalSupply = totalSupply();

        uint128 liquidity;
        /// if this is first touch in this block, then we need to _resetLiquidity() first
        if (lastBlockOpened != block.number) {
            ( , , liquidity,) = _resetLiquidity(true);
        } else {
            Position.Info memory info = PoolManager(
                payable(address(poolManager))
            ).getPosition(
                    PoolIdLibrary.toId(poolKey),
                    address(this),
                    lowerTick,
                    upperTick
                );
            liquidity = info.liquidity;
        }

        if (liquidity > 0)
            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: -SafeCast.toInt256(uint256(liquidity)),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );

        _clear1155Balances();


        // recreate the position
        // CONOR
        // takes the required % from the pool
        // adds the required amount back into the pool
        // V NICE
        uint256 newLiquidity = liquidity - FullMath.mulDiv(pmCalldata.amount, liquidity, totalSupply);
        if (newLiquidity > 0)
            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(newLiquidity),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );
        
        (uint256 currency0Balance, uint256 currency1Balance) = _checkCurrencyBalances();
                
        uint256 amount0 = FullMath.mulDiv(
            pmCalldata.amount,
            currency0Balance,
            totalSupply
        );
        uint256 amount1 = FullMath.mulDiv(
            pmCalldata.amount,
            currency1Balance,
            totalSupply
        );

        // take amounts and send them to receiver
        if (amount0 > 0) {
            poolManager.take(
                poolKey.currency0,
                pmCalldata.receiver,
                amount0
            );
        }
        if (amount1 > 0) {
            poolManager.take(
                poolKey.currency1,
                pmCalldata.receiver,
                amount1
            );
        }

        _a0 = amount0;
        _a1 = amount1;
        
        _mintLeftover();

        if (hedgeRequired0 > 0) {
            hedgeRequired0 -= SafeCast.toInt256(FullMath.mulDiv(uint256(hedgeRequired0), pmCalldata.amount, totalSupply));
        }
        if (hedgeRequired1 > 0) {
            hedgeRequired1 -= SafeCast.toInt256(FullMath.mulDiv(uint256(hedgeRequired1), pmCalldata.amount, totalSupply));
        }
    }

    function _resetLiquidity(bool isMintOrBurn) internal returns (uint160 sqrtPriceX96, uint160 newSqrtPriceX96, uint128 liquidity, uint128 newLiquidity) {
        (sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        Position.Info memory info = PoolManager(
            payable(address(poolManager))
        ).getPosition(
                PoolIdLibrary.toId(poolKey),
                address(this),
                lowerTick,
                upperTick
            );
        if (lastBlockReset <= lastBlockOpened) {
            if (info.liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(uint256(info.liquidity)),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            _clear1155Balances();

            (newSqrtPriceX96, newLiquidity) = _getResetPriceAndLiquidity(committedSqrtPriceX96, isMintOrBurn);

            if (isMintOrBurn) {
                /// swap 1 wei in zero liquidity to kick the price to committedSqrtPriceX96
                if (sqrtPriceX96 != newSqrtPriceX96){
                    poolManager.swap(
                        poolKey,
                        IPoolManager.SwapParams({
                            zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                            amountSpecified: 1,
                            sqrtPriceLimitX96: newSqrtPriceX96
                        })
                    );
                }
                    

                if (newLiquidity > 0)
                    poolManager.modifyPosition(
                        poolKey,
                        IPoolManager.ModifyPositionParams({
                            liquidityDelta: SafeCast.toInt256(uint256(newLiquidity)),
                            tickLower: lowerTick,
                            tickUpper: upperTick
                        })
                    );

                liquidity = newLiquidity;

                if (hedgeCommitted0 > 0) {
                    poolKey.currency0.transfer(address(poolManager), hedgeCommitted0);
                    poolManager.settle(poolKey.currency0);
                } 
                if (hedgeCommitted1 > 0) {
                    poolKey.currency1.transfer(address(poolManager), hedgeCommitted1);
                    poolManager.settle(poolKey.currency1);
                }

                _mintLeftover();
            } else {
                if (hedgeCommitted0 > 0) {
                    poolKey.currency0.transfer(address(poolManager), hedgeCommitted0);
                    poolManager.settle(poolKey.currency0);
                } 
                if (hedgeCommitted1 > 0) {
                    poolKey.currency1.transfer(address(poolManager), hedgeCommitted1);
                    poolManager.settle(poolKey.currency1);
                } 
            }

            // reset hedger variables
            hedgeRequired0 = 0;
            hedgeRequired1 = 0;
            hedgeCommitted0 = 0;
            hedgeCommitted1 = 0;

            // store reset
            lastBlockReset = block.number;
        } else {
            liquidity = info.liquidity;
            newLiquidity = info.liquidity;
            newSqrtPriceX96 = sqrtPriceX96;
        }
    }
    
    // START HERE. 1 UNIT OF CURRENCY MESSING THINGS UP
    // can we mint and settle at the same time???
    // CONOR
    // Fixed
    function _mintLeftover() internal {
        (uint256 currencyBalance0, uint256 currencyBalance1) = _checkCurrencyBalances();
        // CONOR
        // not sure if it always holds
        // need to check multiple price moves in same direction
        if (currencyBalance0  > 0) {
            poolManager.mint(poolKey.currency0, address(this), currencyBalance0);    
        }
        if (currencyBalance1  > 0) {
            poolManager.mint(poolKey.currency1, address(this), currencyBalance1);    
        }
    }

    function _clear1155Balances() internal {
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

    function _transferFromOrTransferNative(Currency currency, address sender, address target, uint256 amount) internal {
        if (currency.isNative()) {
            _nativeTransfer(target, amount);
        } else {
            ERC20(Currency.unwrap(currency)).safeTransferFrom(
                sender,
                target,
                amount
            );  
        }
    }

    function _nativeTransfer(address to, uint256 amount) internal {
        bool success;
        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        if (!success) revert CurrencyLibrary.NativeTransferFailed();
    }


    function _checkCurrencyBalances() internal view returns (uint256, uint256) {
        int256 currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);        
        if (currency0BalanceRaw > 0) {
            revert("delta currency0 cannot be positive");
        }
        uint256 currency0Balance = SafeCast.toUint256(-currency0BalanceRaw);
        int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
        if (currency1BalanceRaw > 0) {
            revert("delta currency1 cannot be positive");
        }
        uint256 currency1Balance = SafeCast.toUint256(-currency1BalanceRaw);

        return (currency0Balance, currency1Balance);
    }

    function _getResetPriceAndLiquidity(uint160 lastCommittedSqrtPriceX96, bool isMintOrBurn) internal view returns (uint160, uint128) {
        (uint256 totalHoldings0, uint256 totalHoldings1) = _checkCurrencyBalances();
        
        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(upperTick);

        uint160 finalSqrtPriceX96;
        {
            (uint256 maxLiquidity0, uint256 maxLiquidity1) = LiquidityAmounts.getAmountsForLiquidity(
                lastCommittedSqrtPriceX96,
                sqrtPriceX96Lower,
                sqrtPriceX96Upper,
                LiquidityAmounts.getLiquidityForAmounts(
                    lastCommittedSqrtPriceX96,
                    sqrtPriceX96Lower,
                    sqrtPriceX96Upper,
                    totalHoldings0,
                    totalHoldings1
                )
            );

            /// NOTE one of these should be roughly zero but we don't know which one so we just increase both
            // (adding 0 or dust to the other side should cause no issue or major imprecision)
            uint256 extra0 = FullMath.mulDiv(totalHoldings0 - maxLiquidity0, vaultRedepositRate, _PIPS);
            uint256 extra1 = FullMath.mulDiv(totalHoldings1 - maxLiquidity1, vaultRedepositRate, _PIPS);

            /// NOTE this algorithm only works if liquidity position is full range
            uint256 priceX96 = FullMath.mulDiv(maxLiquidity1 + extra1, 1 << 96, maxLiquidity0 + extra0);
            finalSqrtPriceX96 = SafeCast.toUint160(_sqrt(priceX96) * (1 << 48));
        }

        if (finalSqrtPriceX96 >= sqrtPriceX96Upper || finalSqrtPriceX96 <= sqrtPriceX96Lower) revert PriceOutOfBounds();

        // Conor
        // 0/1 ERROR ???

        if (isMintOrBurn) {
            totalHoldings0 -= 1;
            totalHoldings1 -= 1;
        }
        uint128 finalLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            finalSqrtPriceX96,
            sqrtPriceX96Lower,
            sqrtPriceX96Upper,
            totalHoldings0,
            totalHoldings1
        );

        return (finalSqrtPriceX96, finalLiquidity);
    }

    function _getArbSwap(ArbSwapParams memory params) internal pure returns (uint256 swap0, uint256 swap1) {
        /// cannot do arb in zero liquidity
        if (params.liquidity == 0) revert LiquidityZero();

        /// cannot move price to edge of LP positin
        if (params.newSqrtPriceX96 >= params.sqrtPriceX96Upper || params.newSqrtPriceX96 <= params.sqrtPriceX96Lower) revert PriceOutOfBounds();
        
        /// get amount0/1 of current liquidity
        (uint256 current0, uint256 current1) = LiquidityAmounts.getAmountsForLiquidity(
            params.sqrtPriceX96,
            params.sqrtPriceX96Lower,
            params.sqrtPriceX96Upper,
            params.liquidity
        );

        /// get amount0/1 of current liquidity if price was newSqrtPriceX96
        (uint256 new0, uint256 new1) = LiquidityAmounts.getAmountsForLiquidity(
            params.newSqrtPriceX96,
            params.sqrtPriceX96Lower,
            params.sqrtPriceX96Upper,
            params.liquidity
        );

        //Conor
        // Is this error necessary?
        if (new0 == current0 || new1 == current1) revert ArbTooSmall();
        bool zeroForOne = new0 > current0;
        
        /// differential of info.liquidity amount0/1 at those two prices gives X and Y of classic UniV2 swap
        /// to get (1-Beta)*X and (1-Beta)*Y for our swap apply `factor`
        swap0 = FullMath.mulDiv(zeroForOne ? new0 - current0 : current0 - new0, params.betaFactor, _PIPS);
        swap1 = FullMath.mulDiv(zeroForOne ? current1 - new1 : new1 - current1, params.betaFactor, _PIPS);
    }

    function _getBeta(uint256 blockDelta) internal view returns (uint24) {
        /// if blockDelta = 1 then decay is 0; if blockDelta = 2 then decay is decayRate; if blockDelta = 3 then decay is 2*decayRate etc.
        uint256 decayAmt = (blockDelta-1)*decayRate;
        /// decayAmt downcast is safe here because we know baseBeta < 10000
        uint24 subtractAmt = decayAmt >= baseBeta ? 0 : baseBeta - uint24(decayAmt);

        return _PIPS - subtractAmt;
    }

    function _checkLastOpen() internal view returns (uint256) {
        /// compute block delta since last time pool was utilized.
        uint256 blockDelta = block.number - lastBlockOpened;

        /// revert if block delta is 0 (pool is already open, top of block arb already happened)
        if (blockDelta == 0) revert PoolAlreadyOpened();

        return blockDelta;
    }

    function computeDecPriceFromNewSQRTPrice(uint160 price) internal pure returns (uint256 y){
        y=FullMath.mulDiv(uint256(price)**2,1,2**192);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
