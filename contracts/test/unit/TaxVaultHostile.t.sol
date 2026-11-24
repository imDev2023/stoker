// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// Every caller of the Tax Vault's public calls treated as hostile (#245): re-entering from the Distributor,
/// calling from inside an unlock (so inside any trader's swap), calling twice in one block, sandwiching the
/// buy, naming a pool that is not ours, donating claims, sending value.
contract TaxVaultHostileTest is TaxLocalBase {
    StokerHook.PayoutAsset internal constant IN_QUOTE = StokerHook.PayoutAsset.QuoteAsset;

    function _rewardWithTax(bool q0) internal returns (PoolKey memory key) {
        key = _launchReward(q0, 2_500, 2_500, IN_QUOTE);
        for (uint256 i; i < 3; i++) {
            _trade(key, trader, true, true, 40 ether);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        }
    }

    /// A Distributor that re-enters every public call from inside `deposit` meets the guard each time.
    function test_hostile_aReenteringDistributorMeetsTheGuard() public {
        PoolKey memory key = _rewardWithTax(true);
        vm.etch(address(holdersPart), address(new ReenteringDistributor()).code);
        ReenteringDistributor(address(holdersPart)).arm(taxVault, key);
        vm.prank(stranger);
        taxVault.passHoldersPart(key);
        ReenteringDistributor d = ReenteringDistributor(address(holdersPart));
        assertEq(d.attempts(), 4, "it tried all four calls");
        assertEq(d.metTheGuard(), 4, "each met Reentered");
    }

    /// No public call can run inside an unlock, so none can run inside a trader's swap: the PoolManager
    /// refuses the vault's own unlock.
    function test_hostile_noCallRunsInsideAnUnlock() public {
        PoolKey memory key = _rewardWithTax(false);
        UnlockedCaller c = new UnlockedCaller(pm);
        bytes4[3] memory calls =
            [TaxVault.burn.selector, TaxVault.addSupport.selector, TaxVault.passHoldersPart.selector];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
            c.callInsideUnlock(address(taxVault), abi.encodeWithSelector(calls[i], key));
        }
        // The holders' buy, on a Launch whose Payout Asset is the coin.
        PoolKey memory inCoin = _launchReward(true, 0, 0, StokerHook.PayoutAsset.Coin);
        _trade(inCoin, trader, true, true, 40 ether);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        c.callInsideUnlock(address(taxVault), abi.encodeWithSelector(TaxVault.buyForHolders.selector, inCoin));
    }

    /// A trader's swap contains no buy by the Tax Vault: its logs hold exactly one swap, the trader's, and
    /// the vault's books do not move but for the tax the swap itself paid.
    function test_hostile_aTradersSwapContainsNoVaultBuy() public {
        for (uint256 o; o < 2; o++) {
            PoolKey memory key = _rewardWithTax(o == 0);
            TaxVault.Books memory before = taxVault.booksOf(key.toId());
            uint256 claims = _vaultClaims(key);
            uint256 booked = _taxBooked(key);
            _approveRouter(key, trader);
            vm.recordLogs();
            _swapApproved(key, trader, true, true, 10 ether);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 swapSig = IPoolManager.Swap.selector;
            uint256 swaps;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == address(pm) && logs[i].topics[0] == swapSig) {
                    swaps++;
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), address(swapRouter), "the trader's router");
                }
            }
            assertEq(swaps, 1, "one swap: the trader's");
            TaxVault.Books memory afterSwap = taxVault.booksOf(key.toId());
            assertEq(afterSwap.burnSpent, before.burnSpent);
            assertEq(afterSwap.supportSpent, before.supportSpent);
            assertEq(afterSwap.holdersSpent, before.holdersSpent);
            assertEq(_vaultClaims(key) - claims, _taxBooked(key) - booked, "only the swap's own tax arrived");
        }
    }

    /// Two pieces in one block, or one transaction, are refused: the interval holds within a transaction.
    function test_hostile_twoBuysInOneTransaction_refused() public {
        PoolKey memory key = _rewardWithTax(true);
        DoubleCaller c = new DoubleCaller();
        vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
        c.twice(taxVault, key, TaxVault.burn.selector);
        vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
        c.twice(taxVault, key, TaxVault.addSupport.selector);
    }

    /// Sandwiching the burn's buy loses money: the wallet pays the Platform Fee and the tax on both legs,
    /// several times what one capped piece moves the price.
    function test_hostile_sandwichingTheBurnLoses() public {
        for (uint256 o; o < 2; o++) {
            PoolKey memory key = _rewardWithTax(o == 0);
            address attacker = makeAddr("attacker");
            mockQuote.mint(attacker, 10_000 ether);
            uint256[4] memory sizes = [uint256(0.1 ether), 1 ether, 10 ether, 100 ether];
            for (uint256 i; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();
                uint256 q0 = quote.balanceOf(attacker);
                _trade(key, attacker, true, true, sizes[i]);
                vm.prank(attacker);
                (uint256 spent,) = taxVault.burn(key);
                assertGt(spent, 0);
                _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
                assertLt(quote.balanceOf(attacker), q0, "the sandwich lost money");
                vm.revertToState(snap);
            }
        }
    }

    function test_hostile_aPoolThatIsNotOurs_refused() public {
        PoolKey memory key = _rewardWithTax(true);
        PoolKey memory foreign = key;
        foreign.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(TaxVault.NotAStokerPool.selector);
        taxVault.burn(foreign);
        PoolKey memory unregistered = key;
        unregistered.tickSpacing = 60;
        vm.expectRevert(TaxVault.NotAStokerPool.selector);
        taxVault.addSupport(unregistered);
        vm.expectRevert(TaxVault.NotAStokerPool.selector);
        taxVault.pieceCap(unregistered);
    }

    function test_hostile_onlyThePoolManagerCallsBack_orSendsValue() public {
        vm.prank(stranger);
        vm.expectRevert(TaxVault.NotPoolManager.selector);
        taxVault.unlockCallback(abi.encode(uint8(2), abi.encode(Currency.wrap(address(quote)), uint256(1))));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(taxVault).call{value: 1 ether}("");
        assertFalse(ok, "no stray value");
    }

    /// Claims donated to the vault change nothing it can spend: every path reads its own part of its own
    /// coin's booked tax, never the vault's balance.
    function test_hostile_donatedClaimsAreNeverSpent() public {
        PoolKey memory key = _rewardWithTax(true);
        (uint256 b0, uint256 s0, uint256 h0,) = taxVault.waiting(key);
        ClaimsDonor donor = new ClaimsDonor(pm);
        mockQuote.mint(address(donor), 50 ether);
        donor.donate(Currency.wrap(address(quote)), address(taxVault), 50 ether);
        (uint256 b1, uint256 s1, uint256 h1,) = taxVault.waiting(key);
        assertEq(b1, b0);
        assertEq(s1, s0);
        assertEq(h1, h0);
    }
}

/// Re-enters every public call of the vault from inside `deposit`, records what each met, then takes the
/// deposit as the interface says so the outer call completes.
contract ReenteringDistributor {
    TaxVault internal vault;
    PoolKey internal key;
    uint256 public attempts;
    uint256 public metTheGuard;

    function arm(TaxVault vault_, PoolKey calldata key_) external {
        vault = vault_;
        key = key_;
    }

    function deposit(address, Currency asset, uint256 amount) external payable {
        bytes4[4] memory calls = [
            TaxVault.burn.selector,
            TaxVault.addSupport.selector,
            TaxVault.passHoldersPart.selector,
            TaxVault.buyForHolders.selector
        ];
        for (uint256 i; i < 4; i++) {
            attempts++;
            (bool ok, bytes memory err) = address(vault).call(abi.encodeWithSelector(calls[i], key));
            if (!ok && err.length == 4 && bytes4(err) == TaxVault.Reentered.selector) metTheGuard++;
        }
        if (!asset.isAddressZero()) IERC20(Currency.unwrap(asset)).transferFrom(msg.sender, address(this), amount);
    }
}

/// Makes a call from inside an unlock of its own, as a router does around a trader's swap.
contract UnlockedCaller is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function callInsideUnlock(address target, bytes calldata data) external {
        pm.unlock(abi.encode(target, data));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (address target, bytes memory data) = abi.decode(raw, (address, bytes));
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 32), mload(err))
            }
        }
        return "";
    }
}

/// Makes the same public call twice in one transaction.
contract DoubleCaller {
    function twice(TaxVault vault, PoolKey calldata key, bytes4 selector) external {
        for (uint256 i; i < 2; i++) {
            (bool ok, bytes memory err) = address(vault).call(abi.encodeWithSelector(selector, key));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(err, 32), mload(err))
                }
            }
        }
    }
}

/// Mints ERC-6909 claims to any address by settling the asset, as anyone can.
contract ClaimsDonor is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function donate(Currency currency, address to, uint256 amount) external {
        pm.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(raw, (Currency, address, uint256));
        pm.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(pm), amount);
        pm.settle();
        pm.mint(to, currency.toId(), amount);
        return "";
    }
}
