// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StokerHook} from "../../src/StokerHook.sol";

/// Credit owners that misbehave when the native asset is paid to them (#242). Each is a contract a
/// Creator could name as their Creator Earnings Destination.

/// Refuses every payment.
contract RevertingRecipient {
    receive() external payable {
        revert("no thanks");
    }
}

/// Burns every unit of gas it is given.
contract GasBurningRecipient {
    receive() external payable {
        while (true) {}
    }
}

/// Refuses with a megabyte-scale revert reason, so a payer that copied the reason would pay for it.
contract ReturnBombRecipient {
    receive() external payable {
        assembly {
            revert(0, 100000)
        }
    }
}

/// Re-enters the Payout Call to be paid twice. Strict, it refuses the payment when that fails; lenient,
/// it records the error its re-entry met and accepts.
contract ReentrantPayoutRecipient {
    StokerHook internal immutable hook;
    bool internal immutable lenient;
    bytes4 public met;

    constructor(StokerHook hook_, bool lenient_) {
        hook = hook_;
        lenient = lenient_;
    }

    receive() external payable {
        address[] memory me = new address[](1);
        me[0] = address(this);
        if (!lenient) {
            hook.payout(Currency.wrap(address(0)), me);
            return;
        }
        try hook.payout(Currency.wrap(address(0)), me) {
            met = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            met = bytes4(reason);
        }
    }
}

/// Calls the PoolManager directly from inside its payment, as a recipient paid inside an unlock could:
/// it tries to swap and to take. Strict, it refuses the payment when either fails; lenient, it records
/// the errors both met and accepts.
contract ReentrantSwapRecipient {
    IPoolManager internal immutable pm;
    bool internal immutable lenient;
    PoolKey internal key;
    bytes4 public swapMet;
    bytes4 public takeMet;

    constructor(IPoolManager pm_, PoolKey memory key_, bool lenient_) {
        pm = pm_;
        key = key_;
        lenient = lenient_;
    }

    receive() external payable {
        if (!lenient) {
            pm.swap(key, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), "");
            pm.take(Currency.wrap(address(0)), address(this), 1);
            return;
        }
        bytes4 s = 0xffffffff;
        bytes4 t = 0xffffffff;
        try pm.swap(key, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), "") {}
        catch (bytes memory reason) {
            s = bytes4(reason);
        }
        try pm.take(Currency.wrap(address(0)), address(this), 1) {}
        catch (bytes memory reason) {
            t = bytes4(reason);
        }
        (swapMet, takeMet) = (s, t);
    }
}

/// Accepts its payment and leaves the PoolManager synced to an ERC-20, which would make a later native
/// `settle` in the same transaction revert unless the payer syncs the native asset first.
contract SyncingRecipient {
    IPoolManager internal immutable pm;
    Currency internal immutable token;

    constructor(IPoolManager pm_, Currency token_) {
        pm = pm_;
        token = token_;
    }

    receive() external payable {
        pm.sync(token);
    }
}

/// A wallet whose receive needs more gas than a payment to someone else is given (a heavy smart wallet).
/// It is paid when it pulls its own Credit.
contract HeavyRecipient {
    uint256 internal constant NEEDS = 200_000;

    receive() external payable {
        if (gasleft() < NEEDS) revert("too little gas");
    }

    function pull(StokerHook hook) external {
        address[] memory me = new address[](1);
        me[0] = address(this);
        hook.payout(Currency.wrap(address(0)), me);
    }
}

/// Buys a coin from inside its own payment, through a router: the PoolManager is locked again by then, so
/// the router opens an unlock of its own and the trade is an ordinary one, booking its fee while the
/// Payout Call is still under way. It pulls its own Credit, which is the only way to be given the gas a
/// trade needs.
contract TradingRecipient {
    StokerHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    uint256 public constant SPEND = 0.2 ether;
    bool public traded;

    constructor(StokerHook hook_, PoolSwapTest router_, PoolKey memory key_) {
        hook = hook_;
        router = router_;
        key = key_;
    }

    function pull(address[] calldata owners) external {
        hook.payout(Currency.wrap(address(0)), owners);
    }

    receive() external payable {
        // Anything but the hook's payment (the router's refund of unspent value) is only accepted.
        if (msg.sender != address(hook)) return;
        router.swap{value: SPEND}(
            key,
            SwapParams(true, -int256(SPEND), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        traded = true;
    }
}

/// Accepts its payment only when it arrives with the whole allowance a payment to someone else carries
/// (the cap and the stipend a value transfer adds, less its own first opcodes), and refuses otherwise:
/// it shows whether a caller's gas budget ever starved a payment.
contract ExactingRecipient {
    uint256 internal immutable needs;

    constructor(uint256 needs_) {
        needs = needs_;
    }

    receive() external payable {
        if (gasleft() < needs) revert("starved");
    }
}

/// Accepts everything and counts what reached it, so a test can say no swap ever paid it.
contract CountingRecipient {
    uint256 public received;
    uint256 public payments;

    receive() external payable {
        received += msg.value;
        payments++;
    }
}
