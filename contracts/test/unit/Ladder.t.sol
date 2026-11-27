// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// The Creator Ladder's key (#248, ADR 0027): a coin's Creator is credited the first Creator Tier's share
/// with no key involved; the ladder key raises one graduated coin's tier to the second or the top, which
/// changes the Creator's part of every Platform Fee credited from then on and nothing else; and it can never
/// lower a tier, raise past the top, raise a coin that has not graduated, or touch any other state. A raise
/// needs Graduation, and the hold judges the price each transaction leaves, so the contracts over this base
/// run with every top-level call a transaction of its own.
abstract contract LadderTestBase is DestinationsLocalBase {
    using StateLibrary for IPoolManager;

    /// One swap, measured from outside.
    struct Measured {
        int256 traderQuote; // what the trader's Quote Asset moved by
        int256 traderCoins; // what the trader's coins moved by
        uint256 taken; // what the hook's claims grew by: the fee
        uint256 creatorCredit;
        uint256 platformCredit;
    }

    /// The four swap types: 0 a buy exact in, 1 a buy exact out, 2 a sell exact in, 3 a sell exact out.
    function _measured(PoolKey memory key, uint256 swapType) internal returns (Measured memory m) {
        uint256 unit = _unit(key);
        address destination = _destinationOf(key);
        uint256 q0 = _quoteBalanceOf(key, trader);
        uint256 c0 = _coinOfKey(key).balanceOf(trader);
        uint256 claims0 = _hookClaimsOf(key);
        uint256 creator0 = _creditIn(key, destination);
        uint256 platform0 = _creditIn(key, keys.admin());
        if (swapType == 0) _trade(key, trader, true, true, 5 * unit);
        else if (swapType == 1) _trade(key, trader, true, false, 1e9 ether);
        else if (swapType == 2) _trade(key, trader, false, true, 1e9 ether);
        else _trade(key, trader, false, false, unit / 20);
        // forge-lint: disable-start(unsafe-typecast)
        m.traderQuote = int256(_quoteBalanceOf(key, trader)) - int256(q0);
        m.traderCoins = int256(_coinOfKey(key).balanceOf(trader)) - int256(c0);
        // forge-lint: disable-end(unsafe-typecast)
        m.taken = _hookClaimsOf(key) - claims0;
        m.creatorCredit = _creditIn(key, destination) - creator0;
        m.platformCredit = _creditIn(key, keys.admin()) - platform0;
    }

    /// A standard Launch in the pool kind, the Creator's wallet as its Destination, with the trader holding
    /// coins to sell, and graduated, so the ladder key may raise it.
    function _coin(uint256 kind) internal returns (PoolKey memory key) {
        key = _newCoin(kind);
        _graduate(key);
    }

    /// The same coin before its Graduation.
    function _newCoin(uint256 kind) internal returns (PoolKey memory key) {
        key = _launchTo(kind, address(0));
        _trade(key, trader, true, true, 20 * _unit(key));
    }

    function _everythingButTheTier(PoolKey memory key) internal view returns (bytes32) {
        PoolId id = key.toId();
        (uint160 sqrtPrice, int24 tick,,) = pm.getSlot0(id);
        Currency q = _quoteOfKey(key);
        return keccak256(
            abi.encode(
                sqrtPrice,
                tick,
                pm.getLiquidity(id),
                _seedLiquidity(key),
                hook.termsOf(id),
                hook.creatorCreditedOf(id),
                hook.creditOf(creator, q),
                hook.creditOf(platform, q),
                hook.totalCredits(q),
                _hookClaimsOf(key),
                hook.taxBooked(id),
                hook.graduationOf(id),
                hook.openingFeeBooked(id)
            )
        );
    }
}

/// forge-config: default.isolate = true
contract LadderTest is LadderTestBase {
    // ---------------------------------------------------------------- the first tier, with no key

    function test_ladder_aNewCoinHoldsTheFirstTier_andItsTermsCarryAllThree() public {
        for (uint256 kind; kind < 3; kind++) {
            vm.recordLogs();
            PoolKey memory key = _launchTo(kind, address(0));
            StokerHook.Terms memory t = hook.termsOf(key.toId());
            assertEq(t.creatorShareBps, CREATOR_SHARE_BPS, "the first tier's share");
            assertEq(t.secondTierShareBps, SECOND_TIER_SHARE_BPS, "the second tier's share");
            assertEq(t.topTierShareBps, TOP_TIER_SHARE_BPS, "the top tier's share");
            assertEq(hook.creatorTierOf(key.toId()), 1, "a coin starts on the first tier");
            assertEq(hook.creatorShareOf(key.toId()), CREATOR_SHARE_BPS);

            // The Indexer reads the three shares from the launch's own event.
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].topics[0] != StokerHook.CreatorLadderRegistered.selector) continue;
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                (uint16 first, uint16 second, uint16 top) = abi.decode(logs[i].data, (uint16, uint16, uint16));
                assertEq(first, CREATOR_SHARE_BPS);
                assertEq(second, SECOND_TIER_SHARE_BPS);
                assertEq(top, TOP_TIER_SHARE_BPS);
                found = true;
            }
            assertTrue(found, "CreatorLadderRegistered");
        }
    }

    /// The acceptance criterion: a coin launched with no key present earns its Creator the first tier's share
    /// for life.
    function test_ladder_noKeyPresent_theFirstTierForLife() public {
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.LadderKey);
        assertEq(keys.holderOf(StokerKeys.Role.LadderKey), address(0), "nobody holds the ladder key");

        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _coin(kind);
            // Years of trading, every swap type, and nobody can raise it: not its old holder, not the Admin,
            // not the Creator.
            for (uint256 year; year < 3; year++) {
                skip(365 days);
                for (uint256 swapType; swapType < 4; swapType++) {
                    Measured memory m = _measured(key, swapType);
                    assertGt(m.taken, 0);
                    assertEq(m.creatorCredit, m.taken * CREATOR_SHARE_BPS / 10_000, "the first tier's share");
                    assertEq(m.platformCredit, m.taken - m.creatorCredit, "the platform has the rest");
                }
                address[4] memory callers = [ladderKey, platform, creator, stranger];
                for (uint256 c; c < callers.length; c++) {
                    vm.prank(callers[c]);
                    vm.expectRevert(StokerHook.NotLadderKey.selector);
                    hook.raiseTier(key.toId(), 2);
                }
            }
            assertEq(hook.creatorTierOf(key.toId()), 1);
        }
    }

    // ---------------------------------------------------------------- a raise

    /// After a raise the next swap credits the Creator the new tier's share and the platform the rest, and
    /// the trader pays and receives exactly what the same swap would have without the raise.
    function test_ladder_aRaiseChangesTheSplitOfTheNextSwap_andNothingTheTraderPays() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _coin(kind);
            for (uint256 swapType; swapType < 4; swapType++) {
                uint256 snap = vm.snapshotState();
                Measured memory first = _measured(key, swapType);
                vm.revertToState(snap);

                _raise(key, 2);
                Measured memory second = _measured(key, swapType);
                vm.revertToState(snap);

                _raise(key, 3);
                Measured memory top = _measured(key, swapType);
                vm.revertToState(snap);

                assertGt(first.taken, 0);
                assertEq(first.creatorCredit, first.taken * CREATOR_SHARE_BPS / 10_000, "first tier");
                assertEq(second.creatorCredit, second.taken * SECOND_TIER_SHARE_BPS / 10_000, "second tier");
                assertEq(top.creatorCredit, top.taken * TOP_TIER_SHARE_BPS / 10_000, "top tier");
                assertEq(first.platformCredit, first.taken - first.creatorCredit);
                assertEq(second.platformCredit, second.taken - second.creatorCredit, "the platform has the rest");
                assertEq(top.platformCredit, top.taken - top.creatorCredit, "the platform has the rest");
                assertGt(second.creatorCredit, first.creatorCredit, "a raise raises the Creator's part");
                assertGt(top.creatorCredit, second.creatorCredit);

                // The fee and the trader's own figures are those of the same swap on the first tier.
                assertEq(second.taken, first.taken, "the fee is unchanged");
                assertEq(top.taken, first.taken, "the fee is unchanged");
                assertEq(second.traderQuote, first.traderQuote, "the trader pays the same");
                assertEq(second.traderCoins, first.traderCoins, "the trader receives the same");
                assertEq(top.traderQuote, first.traderQuote, "the trader pays the same");
                assertEq(top.traderCoins, first.traderCoins, "the trader receives the same");
            }
        }
    }

    function test_ladder_aRaiseStepByStep_theTierAndItsShareReadFromOutside() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.CreatorTierRaised(key.toId(), 1, 2, SECOND_TIER_SHARE_BPS);
        _raise(key, 2);
        assertEq(hook.creatorTierOf(key.toId()), 2);
        assertEq(hook.creatorShareOf(key.toId()), SECOND_TIER_SHARE_BPS);

        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.CreatorTierRaised(key.toId(), 2, 3, TOP_TIER_SHARE_BPS);
        _raise(key, 3);
        assertEq(hook.creatorTierOf(key.toId()), 3);
        assertEq(hook.creatorShareOf(key.toId()), TOP_TIER_SHARE_BPS);
    }

    function test_ladder_aRaiseStraightToTheTop() public {
        PoolKey memory key = _coin(COIN_FIRST);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.CreatorTierRaised(key.toId(), 1, 3, TOP_TIER_SHARE_BPS);
        _raise(key, 3);
        assertEq(hook.creatorTierOf(key.toId()), 3);
    }

    /// A referred trade: the Platform Fee is split by the tier, and the Referrer Fee on top is untouched.
    function test_ladder_aReferredTradeSplitsThePlatformFeeByTheTier() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        _raise(key, 3);
        address referrer = makeAddr("referrer");
        uint256 creator0 = _credit(creator);
        uint256 platform0 = _credit(platform);
        _approveRouter(key, trader);
        uint160 limit = _isQuote0(key) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _swapWithData(key, trader, true, true, 10 ether, limit, _referral(referrer, 75));
        uint256 fee = _feeOnGross(10 ether);
        assertEq(_credit(referrer), _feeOnGrossAt(10 ether, 75), "the Referrer Fee, on top");
        assertEq(_credit(creator) - creator0, fee * TOP_TIER_SHARE_BPS / 10_000, "the top tier's share of the fee");
        assertEq(_credit(platform) - platform0, fee - fee * TOP_TIER_SHARE_BPS / 10_000);
    }

    // ---------------------------------------------------------------- only a graduated coin

    /// No raise before Graduation (the review of PR #278): Active Days are counted from Graduation, so a coin
    /// that has not graduated cannot have reached a tier. A new coin, a coin trading above its target whose
    /// hour has not run, and a coin whose hour has run but whose Graduation nobody has recorded are all
    /// refused by name; once Graduation is recorded the same raise goes through.
    function test_ladder_noRaiseBeforeGraduation() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _newCoin(kind);
            PoolId id = key.toId();
            for (uint8 tier = 2; tier <= 3; tier++) {
                vm.prank(ladderKey);
                vm.expectRevert(StokerHook.NotGraduated.selector);
                hook.raiseTier(id, tier);
            }

            // Above its Graduation Target, the hold running and short of the hour.
            address buyer = makeAddr("buyer");
            uint256 crossing = _native(key) ? 7 ether : 100 ether;
            if (_native(key)) vm.deal(buyer, crossing);
            else deal(address(quote), buyer, crossing);
            _trade(key, buyer, true, true, crossing);
            vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
            vm.prank(ladderKey);
            vm.expectRevert(StokerHook.NotGraduated.selector);
            hook.raiseTier(id, 2);

            // The hour has run, and no swap or call has recorded Graduation yet: still refused.
            vm.warp(vm.getBlockTimestamp() + 1);
            assertEq(hook.graduationOf(id).graduatedAt, 0, "not recorded yet");
            vm.prank(ladderKey);
            vm.expectRevert(StokerHook.NotGraduated.selector);
            hook.raiseTier(id, 2);
            assertEq(hook.creatorTierOf(id), 1);

            // Recorded by the call anyone can make, and the raise goes through.
            vm.prank(stranger);
            hook.graduate(id);
            _raise(key, 2);
            assertEq(hook.creatorTierOf(id), 2);
            Measured memory m = _measured(key, 0);
            assertEq(m.creatorCredit, m.taken * SECOND_TIER_SHARE_BPS / 10_000);
        }
    }

    // ---------------------------------------------------------------- what the key cannot do

    function test_ladder_neverLowers_neverPastTheTop_neverTheSameTier() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        PoolId id = key.toId();
        uint8[4] memory fromFirst = [0, 1, 4, 255];
        for (uint256 i; i < fromFirst.length; i++) {
            vm.prank(ladderKey);
            vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(1), fromFirst[i]));
            hook.raiseTier(id, fromFirst[i]);
        }
        _raise(key, 2);
        uint8[5] memory fromSecond = [0, 1, 2, 4, 255];
        for (uint256 i; i < fromSecond.length; i++) {
            vm.prank(ladderKey);
            vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(2), fromSecond[i]));
            hook.raiseTier(id, fromSecond[i]);
        }
        _raise(key, 3);
        for (uint256 tier; tier < 256; tier++) {
            vm.prank(ladderKey);
            // forge-lint: disable-next-line(unsafe-typecast)
            vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(3), uint8(tier)));
            // forge-lint: disable-next-line(unsafe-typecast)
            hook.raiseTier(id, uint8(tier));
        }
        assertEq(hook.creatorTierOf(id), 3, "the top tier stays");
    }

    /// The Admin appoints the ladder key and never raises itself (the review of PR #278): an Admin that
    /// proposed itself for the role and accepted is refused by name, as the Distributor refuses the Guard as
    /// the round key, and a key it then appoints raises as usual.
    function test_ladder_theAdminCannotRaise_evenAfterNamingItselfTheLadderKey() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        _setKey(StokerKeys.Role.LadderKey, platform);
        assertEq(keys.holderOf(StokerKeys.Role.LadderKey), platform, "the Admin holds the ladder key");
        for (uint8 tier = 2; tier <= 3; tier++) {
            vm.prank(platform);
            vm.expectRevert(StokerHook.AdminCannotRaise.selector);
            hook.raiseTier(key.toId(), tier);
        }
        assertEq(hook.creatorTierOf(key.toId()), 1, "the Admin raised nothing");
        _setKey(StokerKeys.Role.LadderKey, ladderKey);
        _raise(key, 2);
        assertEq(hook.creatorTierOf(key.toId()), 2);
    }

    function test_ladder_onlyTheLadderKey() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        address keeper = makeAddr("keeper");
        _setKey(StokerKeys.Role.Keeper, keeper);
        // The Admin, the round key, the Keeper, the Creator, the hook's own factory and a stranger.
        address[6] memory others = [platform, roundKey, keeper, creator, address(factory), stranger];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(StokerHook.NotLadderKey.selector);
            hook.raiseTier(key.toId(), 2);
        }
        assertEq(hook.creatorTierOf(key.toId()), 1);
    }

    /// The key is read at the moment of the call: a revoke stops it at once, and what it raised stays.
    function test_ladder_aRevokedKeyStopsAtOnce_andWhatItRaisedStays() public {
        PoolKey memory a = _coin(QUOTE_FIRST);
        PoolKey memory b = _coin(COIN_FIRST);
        _raise(a, 2);

        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.LadderKey);

        vm.startPrank(ladderKey);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(a.toId(), 3);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(b.toId(), 2);
        vm.stopPrank();

        assertEq(hook.creatorTierOf(a.toId()), 2, "a raise is never undone, by a revoke either");
        assertEq(hook.creatorTierOf(b.toId()), 1);
        Measured memory m = _measured(a, 0);
        assertEq(m.creatorCredit, m.taken * SECOND_TIER_SHARE_BPS / 10_000);
    }

    function test_ladder_aReplacedKey_theOldStopsWhenTheNewAccepts() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        address next = makeAddr("nextLadderKey");
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.LadderKey, next);

        // Proposed and not yet accepted: the old holder still raises, the new one cannot.
        vm.prank(next);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(key.toId(), 2);
        _raise(key, 2);

        vm.prank(next);
        keys.acceptKey(StokerKeys.Role.LadderKey);
        vm.prank(ladderKey);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(key.toId(), 3);
        vm.prank(next);
        hook.raiseTier(key.toId(), 3);
        assertEq(hook.creatorTierOf(key.toId()), 3);
    }

    function test_ladder_aPoolThatIsNotOurs() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        // The same key on another spacing, and a pool id nobody opened.
        key.tickSpacing = 60;
        vm.prank(ladderKey);
        vm.expectRevert(StokerHook.NotRegistered.selector);
        hook.raiseTier(key.toId(), 2);
        vm.prank(ladderKey);
        vm.expectRevert(StokerHook.NotRegistered.selector);
        hook.raiseTier(PoolId.wrap(keccak256("no pool")), 2);
    }

    /// The whole of the key's power: a raise moves the coin's tier and nothing else, of that coin or another.
    function test_ladder_aRaiseTouchesNothingElse() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _coin(kind);
            PoolKey memory other = _coin(kind);
            _churn(key, 2);
            _churn(other, 2);
            bytes32 before = _everythingButTheTier(key);
            bytes32 otherBefore = _everythingButTheTier(other);
            uint256 creatorBalance = _quoteBalanceOf(key, creator);

            _raise(key, 2);
            assertEq(_everythingButTheTier(key), before, "second tier: the pool, the terms, the Credits");
            _raise(key, 3);
            assertEq(_everythingButTheTier(key), before, "top tier: the pool, the terms, the Credits");
            assertEq(_everythingButTheTier(other), otherBefore, "another coin");
            assertEq(hook.creatorTierOf(other.toId()), 1, "another coin's tier");
            assertEq(_quoteBalanceOf(key, creator), creatorBalance, "nothing is paid by a raise");
        }
    }

    /// What was credited on an earlier tier is not recomputed by a raise.
    function test_ladder_aRaiseReachesOnlyLaterFees() public {
        PoolKey memory key = _coin(QUOTE_FIRST);
        _churn(key, 3);
        uint256 creatorBefore = _credit(creator);
        uint256 platformBefore = _credit(platform);
        _raise(key, 3);
        assertEq(_credit(creator), creatorBefore);
        assertEq(_credit(platform), platformBefore);
        Measured memory m = _measured(key, 2);
        assertEq(_credit(creator), creatorBefore + m.taken * TOP_TIER_SHARE_BPS / 10_000);
    }

    // ---------------------------------------------------------------- at every tier, the books

    function testFuzz_ladder_theCreditsSumToTheFeeAtEveryTier(uint256 kind, uint8 tier, uint256 swapType, uint256 x)
        public
    {
        kind = bound(kind, 0, 2);
        tier = uint8(bound(tier, 1, 3));
        swapType = bound(swapType, 0, 3);
        PoolKey memory key = _coin(kind);
        if (tier > 1) _raise(key, tier);
        uint256 unit = _unit(key);
        address destination = _destinationOf(key);
        uint256 claims0 = _hookClaimsOf(key);
        uint256 creator0 = _creditIn(key, destination);
        uint256 platform0 = _creditIn(key, platform);
        uint256 q0 = _quoteBalanceOf(key, trader);
        if (swapType == 0) _trade(key, trader, true, true, bound(x, 1e9, 50 * unit));
        else if (swapType == 1) _trade(key, trader, true, false, bound(x, 1e18, 1e10 ether));
        else if (swapType == 2) _trade(key, trader, false, true, bound(x, 1e18, _coinOfKey(key).balanceOf(trader)));
        else _trade(key, trader, false, false, bound(x, 1e6, unit));
        uint256 q1 = _quoteBalanceOf(key, trader);
        uint256 taken = _hookClaimsOf(key) - claims0;
        uint256 share = tier == 1 ? CREATOR_SHARE_BPS : tier == 2 ? SECOND_TIER_SHARE_BPS : TOP_TIER_SHARE_BPS;

        // The fee is 1.00% of the Quote Asset's side, whatever the tier.
        uint256 fee;
        if (swapType == 0) fee = _feeOnGross(q0 - q1);
        else if (swapType == 1) fee = _feeOnNet(q0 - q1 - taken);
        else if (swapType == 2) fee = _feeOnGross(q1 - q0 + taken);
        else fee = _feeOnNet(q1 - q0);
        assertEq(taken, fee, "the fee does not change with the tier");
        assertEq(_creditIn(key, destination) - creator0, fee * share / 10_000, "the tier's share, rounded down");
        assertEq(_creditIn(key, platform) - platform0, fee - fee * share / 10_000, "the rest");
        assertEq(hook.totalCredits(_quoteOfKey(key)), _hookClaimsOf(key), "the claims back every Credit");
    }

    // ---------------------------------------------------------------- the factory's bounds

    /// A ladder that falls, or a share over the whole fee, is refused at deployment. Each factory is made
    /// through a fresh deployer for a Tax Vault of its own, so its ladder alone decides, and through an
    /// external call, so every case runs (a `new` in the test's own frame ends the test at the first expected
    /// revert). The last, with a ladder that stays level, gets past the settings and fails only on the
    /// hook's address.
    function test_ladder_theFactoryRefusesALadderThatFalls() public {
        uint16[3][4] memory bad = [
            [uint16(5_000), 4_999, 7_000], // the second below the first
            [uint16(5_000), 6_000, 5_999], // the top below the second
            [uint16(5_000), 6_000, 10_001], // over the whole fee
            [uint16(6_000), 5_000, 5_000] // falling all the way
        ];
        uint256 refused;
        for (uint256 i; i < bad.length; i++) {
            (LadderDeployer d, TaxVault vault) = _deployerWithAVault();
            vm.expectRevert(StokerFactory.InvalidSettings.selector);
            d.create(_factoryCode(bad[i][0], bad[i][1], bad[i][2], vault));
            refused++;
        }
        assertEq(refused, 4, "every case ran");
        // A ladder that stays level never lowers a share: its settings are taken, and the deployment fails
        // later, on a hook address that carries no permission bits.
        (LadderDeployer last, TaxVault good) = _deployerWithAVault();
        try last.create(_factoryCode(5_000, 5_000, 10_000, good)) {
            revert("a hook at an unmined address");
        } catch (bytes memory reason) {
            assertTrue(bytes4(reason) != StokerFactory.InvalidSettings.selector, "the settings were taken");
        }
    }

    /// A fresh deployer and a Tax Vault it made (its first deployment) for the factory it makes next.
    function _deployerWithAVault() internal returns (LadderDeployer d, TaxVault vault) {
        d = new LadderDeployer();
        address next = vm.computeCreateAddress(address(d), 2);
        vault = TaxVault(
            payable(d.create(
                    abi.encodePacked(
                        type(TaxVault).creationCode,
                        abi.encode(
                            pm,
                            next,
                            distributor,
                            PIECE_BPS,
                            PIECE_INTERVAL,
                            SUPPORT_WIDTH_SPACINGS,
                            REFERENCE_RISE,
                            REFERENCE_FALL,
                            BUY_BAND
                        )
                    )
                ))
        );
        assertEq(vault.factory(), next);
    }

    function _factoryCode(uint16 first, uint16 second, uint16 top, TaxVault vault)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(StokerFactory).creationCode,
            abi.encode(
                pm,
                registry,
                PLATFORM_FEE_BPS,
                first,
                second,
                top,
                bytes32(0),
                vault,
                OPENING_FEE_START_BPS,
                OPENING_FEE_DURATION
            )
        );
    }
}

/// Deploys through an external call, so an expected revert of a deployment does not end the test.
contract LadderDeployer {
    function create(bytes memory initCode) external returns (address made) {
        assembly ("memory-safe") {
            made := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(made) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}

/// The shares are a Launch's terms, written from the factory's settings, never constants of the hook: a
/// deployment with another ladder credits by its own.
/// forge-config: default.isolate = true
contract LadderOtherSharesTest is LadderTestBase {
    function _ladder() internal pure override returns (uint16, uint16, uint16) {
        return (4_000, 5_500, 10_000);
    }

    function test_ladder_theHookReadsEveryShareFromTheLaunchsTerms() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _coin(kind);
            StokerHook.Terms memory t = hook.termsOf(key.toId());
            assertEq(t.creatorShareBps, 4_000);
            assertEq(t.secondTierShareBps, 5_500);
            assertEq(t.topTierShareBps, 10_000);

            Measured memory m = _measured(key, 0);
            assertEq(m.creatorCredit, m.taken * 4_000 / 10_000, "the first tier");
            _raise(key, 2);
            m = _measured(key, 2);
            assertEq(m.creatorCredit, m.taken * 5_500 / 10_000, "the second tier");
            assertEq(hook.creatorShareOf(key.toId()), 5_500);
            _raise(key, 3);
            m = _measured(key, 3);
            assertEq(m.creatorCredit, m.taken, "the top tier: the whole fee");
            assertEq(m.platformCredit, 0);
        }
    }
}
