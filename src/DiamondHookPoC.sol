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
    error InsufficientLiquidity();
    error MintZero();
    error BurnZero();
    error BurnOverflow();

    uint16 internal constant _BPS = 10000;

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
    uint256 public sqrtPriceCommitment;
    PoolKey public poolKey;
    bool public initialized;

    struct PoolManagerCalldata {
        uint256 amount; /// mintAmount | burnAmount | newSqrtPriceX96 (inferred from actionType)
        address msgSender;
        address receiver;
        uint8 actionType; /// 0 = mint | 1 = burn | 2 = arbSwap
    }

    struct ComputeArbParams {
        uint160 sqrtPriceX96;
        uint160 newSqrtPriceX96;
        uint160 sqrtPriceX96A;
        uint160 sqrtPriceX96B;
        uint128 liquidity;
        uint16 betaFactor;
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
        require(_baseBeta < _BPS && _decayRate <= _baseBeta);
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
        /// can only initialize one pool once.
        if (initialized) revert AlreadyInitialized();

        /// validate tick bounds on pool initialization
        if (
            lowerTick % poolKey_.tickSpacing != 0 || 
            upperTick % poolKey_.tickSpacing != 0 || 
            lowerTick < poolKey_.tickSpacing.minUsableTick() || 
            upperTick > poolKey_.tickSpacing.maxUsableTick()
        ) revert InvalidTickBounds();

        /// initialize state variable
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
        /// disallow normal swaps at top of block
        if (lastBlockTouch != block.number) revert InvalidTopOfBlockSwap();
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta)
        external
        pure
        override
        returns (bytes4)
    {
        /// TODO check hedger invariant after all swaps
        return BaseHook.afterSwap.selector;
    }

    function beforeModifyPosition(address, PoolKey calldata, IPoolManager.ModifyPositionParams calldata)
        external
        view
        override
        returns (bytes4)
    {
        /// force LPs to provide liquidity through hook
        if (!_modifyViaHook) revert OnlyModifyViaHook();
        return BaseHook.beforeModifyPosition.selector;
    }

    /// method called back on PoolManager.lock()
    function lockAcquired(
        uint256,
        /* id */ bytes calldata data_
    ) external poolManagerOnly returns (bytes memory) {
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
    function topOfBlockSwap(
        uint256 newSqrtPriceX96_,
        address receiver_
    ) external payable nonReentrant {
        /// encode calldata to pass through lock()
        bytes memory data = abi.encode(
            PoolManagerCalldata({
                amount: newSqrtPriceX96_,
                msgSender: msg.sender,
                receiver: receiver_,
                actionType: 2 /// arbSwap action
            })
        );

        /// begin pool actions (passing data through lock() into _lockAcquiredArb())
        poolManager.lock(data);

        /// handle eth refunds
        if (poolKey.currency0.isNative()) {
            uint256 bal = address(this).balance;
            if (bal > 0) _nativeTransfer(msg.sender, bal);
        }
        if (poolKey.currency1.isNative()) {
            uint256 bal = address(this).balance;
            if (bal > 0) _nativeTransfer(msg.sender, bal);
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
            uint256 bal = address(this).balance;
            if (bal > 0) _nativeTransfer(msg.sender, bal);
        }
        if (poolKey.currency1.isNative()) {
            uint256 bal = address(this).balance;
            if (bal > 0) _nativeTransfer(msg.sender, bal);
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
        if (totalSupply() < burnAmount_) revert BurnOverflow();

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
        uint256 blockDelta = _requireTopOfBlock();

        (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        uint160 newSqrtPriceX96 = SafeCast.toUint160(pmCalldata.amount);

        /// if prices match, nothing to do
        if (sqrtPriceX96 == newSqrtPriceX96) return;

        Position.Info memory info = PoolManager(
            payable(address(poolManager))
        ).getPosition(
                PoolIdLibrary.toId(poolKey),
                address(this),
                lowerTick,
                upperTick
            );

        /// compute swap amounts, swap direction, and amount of liquidity to mint
        (uint256 swap0, uint256 swap1, int256 newLiquidity, bool zeroForOne) = 
            _getArbSwap(sqrtPriceX96, newSqrtPriceX96, info.liquidity, blockDelta);

        /// allow modifyPosition
        _modifyViaHook = true;

        /// burn all liquidity
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

        /// update lastBlockTouch to current block
        /// must do now or else swap in next line would revert in preswap hook
        lastBlockTouch = block.number;

        /// swap 1 wei in zero liquidity to kick the price to newSqrtPriceX96
        poolManager.swap(
            poolKey, 
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 1,
                sqrtPriceLimitX96: newSqrtPriceX96
            })
        );

        /// mint new liquidity around newSqrtPriceX96
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                liquidityDelta: newLiquidity,
                tickLower: lowerTick,
                tickUpper: upperTick
            })
        );
        
        _modifyViaHook = false;

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
            poolManager.settle(poolKey.currency1);
            /// transfer swapOutAmt to arber
            poolManager.take(
                poolKey.currency0,
                pmCalldata.receiver,
                swap0
            );
        }

        /// if any positive balances remain in PoolManager after all operations (e.g. sidelined vault tokens), mint erc1155 shares (or else tokens will be lost)
        _mintIfLeftOver();
    }

    function _lockAcquiredMint(PoolManagerCalldata memory pmCalldata) internal {
        uint256 totalSupply = totalSupply();
        _modifyViaHook = true;

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
                SafeCast.toUint128(pmCalldata.amount)
            );

            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(pmCalldata.amount),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );
            
            _modifyViaHook = false;

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

            _mintIfLeftOver();
        } else {
            /// burn everything positions and erc1155 (includes sidelined vault tokens)
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

            // updated total balances.
            currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
            if (currency0BalanceRaw < 0) {
                revert("delta currency0 cannot be negative");
            }
            currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
            if (currency1BalanceRaw < 0) {
                revert("delta currency1 cannot be negative");
            }
            currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            // mint back the position.

            uint256 liquidity = FullMath.mulDiv(pmCalldata.amount, info.liquidity, totalSupply);

            if (liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: SafeCast.toInt256(liquidity),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            _modifyViaHook = false;

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

            _mintIfLeftOver();
        }
    }

    function _lockAcquiredBurn(PoolManagerCalldata memory pmCalldata) internal {
        _modifyViaHook = true;

        /// burn everything, positions and erc1155 (includes sidelined vault tokens)

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
            revert("delta currency0 cannot be positive");
        }
        uint256 currency0Balance = SafeCast.toUint256(-currency0BalanceRaw);
        int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
        if (currency1BalanceRaw > 0) {
            revert("delta currency1 cannot be positive");
        }
        uint256 currency1Balance = SafeCast.toUint256(-currency1BalanceRaw);

        {
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
            uint256 liquidity = uint256(info.liquidity) - FullMath.mulDiv(pmCalldata.amount, info.liquidity, totalSupply);

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

        _modifyViaHook = false;

        _mintIfLeftOver();
    }

    function _mintIfLeftOver() internal {
        int256 currency0BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency0);
        if (currency0BalanceRaw > 0) {
            revert("delta currency0 cannot be positive");
        }
        uint256 leftOver0 = SafeCast.toUint256(-currency0BalanceRaw);
        int256 currency1BalanceRaw = poolManager.currencyDelta(address(this), poolKey.currency1);
        if (currency1BalanceRaw > 0) {
            revert("delta currency1 cannot be positive");
        }
        uint256 leftOver1 = SafeCast.toUint256(-currency1BalanceRaw);

        if (leftOver0 > 0) {
            poolManager.mint(poolKey.currency0, address(this), leftOver0);
        }

        if (leftOver1 > 0) {
            poolManager.mint(poolKey.currency1, address(this), leftOver1);
        }
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

    function _getArbSwap(
        uint160 sqrtPriceX96,
        uint160 newSqrtPriceX96,
        uint128 liquidity,
        uint256 blockDelta
    ) internal view returns (uint256, uint256, int256, bool) {
        return _computeArbSwap(
            ComputeArbParams({
                sqrtPriceX96: sqrtPriceX96,
                newSqrtPriceX96: newSqrtPriceX96,
                sqrtPriceX96A: TickMath.getSqrtRatioAtTick(lowerTick),
                sqrtPriceX96B: TickMath.getSqrtRatioAtTick(upperTick),
                liquidity: liquidity,
                betaFactor: _getBeta(blockDelta)
            })
        );
    }

    function _computeArbSwap(ComputeArbParams memory params) internal pure returns (uint256 swap0, uint256 swap1, int256 newLiquidity, bool zeroForOne) {
        /// get amount0/1 of current liquidity
        (uint256 current0, uint256 current1) = LiquidityAmounts.getAmountsForLiquidity(
            params.sqrtPriceX96,
            params.sqrtPriceX96A,
            params.sqrtPriceX96B,
            params.liquidity
        );
        

        /// get amount0/1 of current liquidity if price was newSqrtPriceX96
        (uint256 new0, uint256 new1) = LiquidityAmounts.getAmountsForLiquidity(
            params.newSqrtPriceX96,
            params.sqrtPriceX96A,
            params.sqrtPriceX96B,
            params.liquidity
        );
    
        if (new0 == 0 || new1 == 0 || current0 == 0 || current1 == 0 || new0 == current0 || new1 == current1) revert InsufficientLiquidity();
        zeroForOne = new0 > current0;
        
        /// differential of info.liquidity amount0/1 at those two prices gives X and Y of classic UniV2 swap
        /// to get (1-Beta)*X and (1-Beta)*Y for our swap apply `factor`
        swap0 = FullMath.mulDiv(zeroForOne ? new0 - current0 : current0 - new0, params.betaFactor, _BPS);
        swap1 = FullMath.mulDiv(zeroForOne ? current1 - new1 : new1 - current1, params.betaFactor, _BPS);


        /// here we apply the swap amounts to the current liquidity
        /// to get amounts available to use as liquidity after the arb swap operation
        uint256 finalLiq0 = zeroForOne ? current0 + swap0 : current0 - swap0;
        uint256 finalLiq1 = zeroForOne ? current1 - swap1 : current1 + swap1;

        /// here we compute the newLiquidity we can mint after the arb swap operation
        /// this should be less than previous info.liquidity by `C`, leaving some leftover in one token
        newLiquidity = SafeCast.toInt256(uint256(LiquidityAmounts.getLiquidityForAmounts(
            params.newSqrtPriceX96,
            params.sqrtPriceX96A,
            params.sqrtPriceX96B,
            finalLiq0,
            finalLiq1
        )));

        /// here we force arber to always input 1 extra wei into the swap, which is used to kick the price
        if (zeroForOne) {
            swap0 += 1;
        } else {
            swap1 += 1;
        }
    }

    function _getBeta(uint256 blockDelta) internal view returns (uint16) {
        /// if blockDelta = 1 then decay is 0; if blockDelta = 2 then decay is decayRate; if blockDelta = 3 then decay is 2*decayRate etc.
        uint256 decayAmt = (blockDelta-1)*decayRate;
        /// decayAmt downcast is safe here because we know baseBeta < 10000
        uint16 subtractAmt = decayAmt >= baseBeta ? 0 : baseBeta - uint16(decayAmt);

        return _BPS - subtractAmt;
    }

    function _requireTopOfBlock() internal view returns (uint256) {
        /// compute block delta since last time pool was utilized.
        uint256 blockDelta = block.number - lastBlockTouch;

        /// revert if block delta is 0 (pool is already open, top of block arb already happened)
        if (blockDelta == 0) revert NotTopOfBlock();

        return blockDelta;
    }
}
