// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ForkBase} from "./Base.t.sol";

interface IStock {
    function uiMultiplier() external view returns (uint256);
    function balanceOfUI(address) external view returns (uint256);
}

interface IRegistry {
    function paused() external view returns (bool);
}

/// @notice The chain facts the spike stands on, read at the pinned block.
contract ChainTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    address internal constant PROTOCOL_FEE_CONTROLLER = 0x6d0009504D129CF5002Dba61D9Ae8575AA79314c;

    function test_chain_uniswapContractsArePresent() public view {
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager");
        assertGt(UNIVERSAL_ROUTER.code.length, 0, "Universal Router");
        assertGt(V4_QUOTER.code.length, 0, "V4 Quoter");
        assertGt(PERMIT2.code.length, 0, "Permit2");
    }

    /// NVDA is a beacon proxy whose beacon is the shared registry; it has ERC-2612, the registry is
    /// not paused, and its multiplier is not 1, which does not touch raw balances.
    function test_chain_nvdaIsAStockTokenWithPermit() public view {
        assertEq(address(uint160(uint256(vm.load(address(NVDA), BEACON_SLOT)))), STOCK_REGISTRY, "shared beacon");
        assertFalse(IRegistry(STOCK_REGISTRY).paused());
        assertTrue(IERC20Permit(address(NVDA)).DOMAIN_SEPARATOR() != bytes32(0));
        uint256 m = IStock(address(NVDA)).uiMultiplier();
        assertGt(m, 1e18, "a dividend has moved the multiplier");
        uint256 raw = NVDA.balanceOf(address(POOL_MANAGER));
        // What other pools leave in the PoolManager, which a hook's mid-swap payout draws on.
        assertEq(raw, 22_484.711401091522869304 ether, "PoolManager's NVDA at the pinned block");
        assertEq(IStock(address(NVDA)).balanceOfUI(address(POOL_MANAGER)), raw * m / 1e18, "display only");
    }

    /// The pool's LP fee is ours to fix at zero, but the protocol fee is not: the PoolManager has a
    /// protocol fee controller at this block, and it can switch a fee on in any pool, ours included.
    function test_chain_protocolFeeCanBeSwitchedOnByUniswap() public {
        assertEq(IProtocolFees(address(POOL_MANAGER)).protocolFeeController(), PROTOCOL_FEE_CONTROLLER);
        (, PoolKey memory key) = _launch(_params(true));

        uint256 snap = vm.snapshotState();
        _swap(key, trader, true, true, 10 ether, "");
        uint256 withoutFee = _coin(key).balanceOf(trader);
        vm.revertToState(snap);

        vm.prank(PROTOCOL_FEE_CONTROLLER);
        IProtocolFees(address(POOL_MANAGER)).setProtocolFee(key, 1000 | (1000 << 12)); // 0.1% each way
        (,, uint24 protocolFee,) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(protocolFee, 0);
        _swap(key, trader, true, true, 10 ether, "");
        assertLt(_coin(key).balanceOf(trader), withoutFee, "the trader now pays Uniswap's fee too");
    }
}
