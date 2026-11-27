// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConservationProperties} from "evm-security-standards/properties/Conservation.sol";
import {SolvencyProperties} from "evm-security-standards/properties/Solvency.sol";
import {MonotonicityProperties} from "evm-security-standards/properties/Monotonicity.sol";
import {AccessControlProperties} from "evm-security-standards/properties/AccessControl.sol";
import {RoundingDirectionProperties} from "evm-security-standards/properties/RoundingDirection.sol";

import {WholeSetFixture} from "./WholeSetFixture.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {Distributor} from "../../src/Distributor.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";

/// The one campaign over the whole contract set, deployed as `script/Deploy.s.sol` deploys it (#251). The
/// per-slice campaigns beside this file each prove one slice against a fixture of its own; this one proves the
/// five properties custody rests on of the set together, with every slice's calls in one handler:
///
/// 1. liquidity never leaves;
/// 2. a Creator Tier never falls, and Graduation is recorded on the hour and for good;
/// 3. a round never pays more than its coin's pot;
/// 4. the Credits of a fee sum to the fee;
/// 5. no key of ours moves a Credit, a Creator Lock or a Seed Position.
///
/// Beside them, three of the security standards' properties, bound to the set: conservation (every ledger a
/// contract of ours keeps is backed), solvency (every Credit and every posted round could be paid at once) and
/// monotonicity (what only grows never shrinks).
///
/// A run here is long rather than many: Graduation, a raise, a lock's claim and a paid round each come at the
/// end of a sequence, and every call is followed by every invariant, each a pass over the whole set.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 128
/// forge-config: ci.invariant.runs = 64
/// forge-config: ci.invariant.depth = 256
contract WholeSetInvariantTest is WholeSetFixture, ConservationProperties, SolvencyProperties, MonotonicityProperties {
    // ------------------------------------------------ 1. liquidity never leaves

    /// Every Seed Position holds exactly the liquidity its launch placed, every Support Liquidity position
    /// exactly what the Tax Vault reported adding, and no removal went through, tried by code at the factory's
    /// and the vault's own addresses, the only ones v4 would let lower them.
    function invariant_liquidityNeverLeaves() public view {
        assertEq(handler.liquidityRemoved(), 0, "a removal went through");
        for (uint256 k; k < _keys.length; k++) {
            assertEq(seedNow(k), _seedAtLaunch[k], "a Seed Position is not what its launch placed");
        }
        uint256 spots = handler.spotCount();
        for (uint256 i; i < spots; i++) {
            (uint256 pool, int24 lower, int24 upper, uint128 expected) = handler.spotAt(i);
            assertEq(supportNow(pool, lower, upper), expected, "Support Liquidity is not what was added");
        }
    }

    // ------------------------------------------------ 2. a Creator Tier never falls

    /// A coin's Creator Tier is 1 to 3 and never fell; nobody but the ladder key of the moment raised one, never
    /// the Admin, and never a coin whose Graduation was not recorded; the Creator's share is its tier's, from the
    /// Launch's own terms. Graduation was recorded only an hour after a call first left the price at or above
    /// the target with none leaving it under since, and what was recorded never changed.
    function invariant_aCreatorTierNeverFalls() public view {
        assertEq(handler.tierLowered(), 0, "a tier fell, or a raise did not raise");
        assertEq(handler.wrongRaiser(), 0, "a raise by the wrong caller, or of a coin that had not graduated");
        assertEq(handler.graduatedWrongly(), 0, "Graduation was recorded off its hour");
        assertEq(handler.graduationMoved(), 0, "a recorded Graduation changed");
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            uint8 tier = hook.creatorTierOf(id);
            StokerHook.Terms memory terms = hook.termsOf(id);
            assertEq(tier, handler.seenTier(k), "the tier the campaign last saw");
            assertTrue(tier >= 1 && tier <= 3, "a tier off the ladder");
            if (tier > 1) assertGt(hook.graduationOf(id).graduatedAt, 0, "a raised coin that has not graduated");
            assertEq(
                hook.creatorShareOf(id),
                tier == 1 ? terms.creatorShareBps : tier == 2 ? terms.secondTierShareBps : terms.topTierShareBps,
                "the Creator's share is its tier's"
            );
            assertEq(terms.creatorShareBps, settings.creatorShareBps, "the first tier's share is the settings file's");
            assertEq(terms.topTierShareBps, settings.topTierShareBps);
        }
    }

    // ------------------------------------------------ 3. a round never pays more than its coin's pot

    /// Each pot of each coin (its Reward Tax's and its Creator earnings', in the Quote Asset or the coin) is
    /// exactly what reached it less what its own rounds paid, so no round was paid from another coin's pot or
    /// from the coin's other pot; what a pot's live roots owe is never more than it holds; no round paid past
    /// its total; and no root was taken that owed more than its own pot held.
    function invariant_aRoundNeverPaysMoreThanItsCoinsPot() public view {
        assertEq(handler.potMixups(), 0, "a root or a claim reached past its own pot");
        for (uint256 k; k < _keys.length; k++) {
            address coin = coinOf(k);
            Currency[2] memory assets = [quoteOf(k), Currency.wrap(coin)];
            for (uint256 a; a < 2; a++) {
                uint256 taxIn = handler.deposited(k, false, assets[a]);
                uint256 earningsIn = handler.deposited(k, true, assets[a]);
                assertLe(handler.paid(k, false, assets[a]), taxIn, "a Reward Round paid more than its pot took in");
                assertLe(handler.paid(k, true, assets[a]), earningsIn, "an earnings round paid more than its pot");
                assertEq(distributor.potOf(coin, assets[a]), taxIn - handler.paid(k, false, assets[a]));
                assertEq(distributor.earningsPotOf(coin, assets[a]), earningsIn - handler.paid(k, true, assets[a]));
                assertLe(distributor.reservedOf(coin, assets[a]), distributor.potOf(coin, assets[a]));
                assertLe(distributor.earningsReservedOf(coin, assets[a]), distributor.earningsPotOf(coin, assets[a]));
            }
        }
        uint256 rounds = distributor.roundCount();
        for (uint256 n = 1; n <= rounds; n++) {
            Distributor.Round memory r = distributor.roundOf(n);
            assertLe(r.paid, r.total, "a round paid past its total");
        }
    }

    // ------------------------------------------------ 4. the Credits of a fee sum to the fee

    /// Every fee's two Credits summed to it, the Creator's being its tier's share; every Credit is booked to an
    /// address a fee names, so the Credits of every such address together are all the Credits there are; the
    /// hook's claims back them one for one; and they are exactly every fee an event reported less every payment
    /// one reported.
    function invariant_theCreditsOfAFeeSumToTheFee() public view {
        assertEq(handler.feeSplitBroken(), 0, "a fee's Credits did not sum to it, or its split was not its tier's");
        Currency[2] memory assets = [mockCurrency(), NATIVE];
        for (uint256 a; a < 2; a++) {
            uint256 owed;
            for (uint256 i; i < _owners.length; i++) {
                owed += hook.creditOf(_owners[i], assets[a]);
            }
            uint256 total = hook.totalCredits(assets[a]);
            assertEq(owed, total, "a Credit is booked to an address no fee named");
            assertEq(pm.balanceOf(address(hook), assets[a].toId()), total, "the claims back every Credit");
            assertEq(
                _creditsAtSetUp[assets[a]] + handler.credited(assets[a]) - handler.paidOut(assets[a]),
                total,
                "the Credits are the fees taken less the payments made"
            );
        }
        assertEq(address(hook).balance, 0, "the hook holds no native asset between calls");
        assertEq(quote.balanceOf(address(hook)), 0, "the hook holds no ERC-20");
    }

    // ------------------------------------------------ 5. no key of ours moves a Credit, a Creator Lock or a Seed Position

    /// Around every call the Admin, the round key, the ladder key and the Guard made, nothing no key may move
    /// had moved (every Credit and balance of every owner, every Seed Position and Support Liquidity position,
    /// every lock, every Launch's terms and Graduation, the Tax Vault's books, the Distributor's pots). A Payout
    /// Call, whoever made it, paid each Credit to its owner or left it owed. A Creator Lock paid its Creator
    /// alone, after Graduation, by its schedule. A Destination was handed its own coin's earnings and no other's.
    function invariant_noKeyOfOursMovesACreditALockOrASeed() public view {
        assertEq(handler.keyMovedSomething(), 0, "a key's call moved what no key may move");
        assertEq(handler.payoutMisdirected(), 0, "a Payout Call paid other than a Credit's owner");
        assertEq(handler.lockBreached(), 0, "a Creator Lock paid other than its Creator");
        assertEq(handler.wrongCoinApplied(), 0, "a Destination worked for a coin that names another");
        assertEq(handler.misapplied(), 0, "a Destination applied other than its coin's own earnings");
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            address named = hook.termsOf(id).creatorDestination;
            assertEq(named, _kinds[k] == WALLET ? creator : address(destinationAt(_kinds[k])), "a Destination changed");
            if (_locks[k] == address(0)) continue;
            StokerCreatorLock lock = StokerCreatorLock(_locks[k]);
            assertEq(lock.claimed(), handler.lockClaimed(k), "the lock paid what its Creator claimed");
            assertEq(IERC20(coinOf(k)).balanceOf(address(lock)), lock.amount() - lock.claimed(), "the lock's coins");
            assertLe(lock.claimed(), lock.released(), "nothing ahead of the schedule");
            if (hook.graduationOf(id).graduatedAt == 0) assertEq(lock.claimed(), 0, "nothing before Graduation");
        }
    }

    // ------------------------------------------------ the security standards' properties, bound to the set

    function _pots(Currency asset) internal view returns (uint256 pots) {
        for (uint256 k; k < _keys.length; k++) {
            pots += distributor.potOf(coinOf(k), asset) + distributor.earningsPotOf(coinOf(k), asset);
        }
    }

    /// Every ledger a contract of ours keeps, against what backs it, from one pass over the pools: the Credits
    /// and the hook's claims; what the Tax Vault's books say waits (every coin's tax and Opening Fees less what
    /// each path spent, and what was funded less what was spent of it) and its claims; the Distributor's pots
    /// and what it holds, in the Quote Assets and in each coin; and what each Destination's coins wait (what
    /// each earned and it has not applied) and what it holds and is owed.
    function conservationLedgers() public view override returns (Ledger[] memory l) {
        Currency[2] memory assets = [mockCurrency(), NATIVE];
        uint256[2] memory vaultWaiting;
        uint256[2] memory pots;
        uint256[2][3] memory destinationWaiting;
        l = new Ledger[](12 + _keys.length);
        uint256 n;
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            address coin = coinOf(k);
            uint256 a = quoteOf(k).isAddressZero() ? 1 : 0;
            TaxVault.Books memory b = taxVault.booksOf(id);
            vaultWaiting[a] += hook.taxBooked(id) + hook.openingFeeBooked(id) - b.burnSpent - b.supportSpent
            - b.holdersSpent + (b.burnFunded - b.burnFundedSpent) + (b.supportFunded - b.supportFundedSpent);
            pots[a] += distributor.potOf(coin, assets[a]) + distributor.earningsPotOf(coin, assets[a]);
            if (_kinds[k] != WALLET) {
                destinationWaiting[_kinds[k]][a] += hook.creatorCreditedOf(id) - destinationAt(_kinds[k]).appliedOf(id);
            }
            // A pot paid in the coin itself, where a Reward Launch's Payout Asset is the coin.
            Currency inCoin = Currency.wrap(coin);
            l[n++] = Ledger({
                name: "the Distributor holds a coin's pot in the coin",
                accounted: distributor.potOf(coin, inCoin) + distributor.earningsPotOf(coin, inCoin),
                held: IERC20(coin).balanceOf(address(distributor)),
                exact: true
            });
        }
        string[2] memory names = ["the Stock Token", "the native asset"];
        for (uint256 a; a < 2; a++) {
            l[n++] = Ledger({
                name: string.concat("Credits backed by the hook's claims, ", names[a]),
                accounted: hook.totalCredits(assets[a]),
                held: pm.balanceOf(address(hook), assets[a].toId()),
                exact: true
            });
            l[n++] = Ledger({
                name: string.concat("the Tax Vault's claims are what its books say waits, ", names[a]),
                accounted: vaultWaiting[a],
                held: pm.balanceOf(address(taxVault), assets[a].toId()),
                exact: true
            });
            l[n++] = Ledger({
                name: string.concat("the Distributor holds every pot, ", names[a]),
                accounted: pots[a],
                held: _balance(assets[a], address(distributor)),
                exact: false
            });
            for (uint256 kind; kind < 3; kind++) {
                l[n++] = Ledger({
                    name: string.concat("a Destination holds and is owed what its coins wait, ", names[a]),
                    accounted: destinationWaiting[kind][a],
                    held: _balance(assets[a], address(destinationAt(kind)))
                        + hook.creditOf(address(destinationAt(kind)), assets[a]),
                    exact: true
                });
            }
        }
    }

    /// Solvency in the native asset: every Credit and every posted round's unpaid claim, all at once, against
    /// the hook's claims and the Distributor's pots, read from their own books.
    function actors() public view override returns (address[] memory who) {
        address[3] memory holders = handler.holderList();
        who = new address[](_owners.length + 3);
        for (uint256 i; i < _owners.length; i++) {
            who[i] = _owners[i];
        }
        for (uint256 i; i < 3; i++) {
            who[_owners.length + i] = holders[i];
        }
    }

    function claimableBy(address actor) public view override returns (uint256) {
        return hook.creditOf(actor, NATIVE) + handler.owedInRounds(actor, NATIVE);
    }

    function solvencyCapacity() public view override returns (uint256) {
        return pm.balanceOf(address(hook), NATIVE.toId()) + _pots(NATIVE);
    }

    /// What only ever grows: each coin's Creator Tier, its record of Graduation, its book of Creator Credits,
    /// its tax and its Opening Fees, and the number of rounds. A fixed length, a coin not yet launched reading 0.
    function monotonicSeries() public view override returns (Series[] memory series) {
        series = new Series[](MAX_POOLS * 5 + 1);
        for (uint256 k; k < MAX_POOLS; k++) {
            bool launched = k < _keys.length;
            PoolId id = launched ? _keys[k].toId() : PoolId.wrap(bytes32(0));
            series[k * 5] = Series("a coin's Creator Tier", launched ? hook.creatorTierOf(id) : 0);
            series[k * 5 + 1] = Series("a coin's Graduation", launched ? hook.graduationOf(id).graduatedAt : 0);
            series[k * 5 + 2] = Series("a coin's book of Creator Credits", launched ? hook.creatorCreditedOf(id) : 0);
            series[k * 5 + 3] = Series("a coin's tax booked", launched ? hook.taxBooked(id) : 0);
            series[k * 5 + 4] = Series("a coin's Opening Fees booked", launched ? hook.openingFeeBooked(id) : 0);
        }
        series[MAX_POOLS * 5] = Series("the rounds posted", distributor.roundCount());
    }

    // ------------------------------------------------ the handler, driven by hand

    /// The handler reaches what every invariant is about. A campaign starts from the fixture's seeded market
    /// (trades in every pool, buys inside opening seconds, a referrer, two pots filled, two coins a held hour
    /// past their targets); from there, driven by hand, it trades in all four kinds of swap, launches each
    /// type, makes every call of the Tax Vault and each Destination's work, posts rounds from each pot in the
    /// Quote Asset and in the coin, has the Guard cancel one, pays the rest, is refused Graduation inside the
    /// hour and records it after, raises tiers as the ladder key and is refused as everyone else, claims
    /// Creator Locks as the Creator and is refused as the Admin, writes the registry, rotates keys, hands the
    /// Admin over, and tries to remove a Seed Position and Support Liquidity. Every call here is a transaction
    /// of its own, as each handler call of a campaign is.
    /// forge-config: default.isolate = true
    function test_wholeSet_theHandlerReachesEverySubject() public {
        assertEq(handler.swaps(), 5 + 14 + 1 + 2, "the seeded market's trades all went through");
        assertEq(handler.referredSwaps(), 1);
        assertEq(handler.lifts(), 2);
        assertEq(handler.appliesOfKind(2), 1);
        assertEq(handler.partsPassed(), 1);
        assertGt(hook.openingFeeBooked(idOf(0)), 0, "an Opening Fee from a buy in a Launch's first seconds");
        assertGt(distributor.potOf(coinOf(2), NATIVE), 0, "the Reward Launch's pot");
        assertGt(distributor.earningsPotOf(coinOf(2), NATIVE), 0, "and its earnings pot");
        assertEq(handler.graduatedCount(), 0, "the two lifted coins' Graduation waits for a call to record it");

        uint256 swaps = handler.swaps();
        handler.trade(0, 1, true, true, 5 ether, 1);
        handler.trade(2, 1, true, true, 5 ether, 1);
        handler.buyExactOut(1, 2, 1e28, 1);
        handler.sellOnly(0, 1, 1e24);
        handler.trade(1, 2, false, false, 0, 1);
        assertEq(handler.swaps() - swaps, 5, "a buy and a sell, each exact in and exact out");

        handler.launch(0, 0, 3, true, 1);
        handler.launch(1, 2, 2, false, 0);
        handler.launch(2, 1, 1, false, 2);
        assertEq(handler.launchesOfType(0), 1, "a standard Launch");
        assertEq(handler.launchesOfType(1), 1, "a Reward Launch");
        assertEq(handler.launchesOfType(2), 1, "a Stoke Launch");
        assertEq(poolCount(), MAX_POOLS);
        handler.trade(7, 0, true, true, 5 ether, 1);
        assertGt(hook.openingFeeBooked(idOf(7)), 0, "a buy inside the new Launch's opening seconds");

        handler.wait(6);
        handler.payout(false, 0);
        handler.payout(true, 1);
        assertEq(handler.payouts(), 2);
        for (uint256 k; k < 7; k++) {
            handler.applyOwn(k);
        }
        handler.applyEarnings(0, 0, 0);
        assertEq(handler.appliesOfKind(0), 2, "the burn's Destination, for its two coins");
        assertEq(handler.appliesOfKind(1), 2, "the liquidity's");
        assertEq(handler.appliesOfKind(2), 2, "the holders', again");
        handler.strangerFunds(1, 0, true, 3);
        handler.strangerFunds(6, 1, false, 5);
        assertEq(handler.fundings(), 2);
        for (uint256 k; k < 9; k++) {
            handler.vaultBurn(k, true);
            handler.vaultSupport(k);
            handler.buyForHolders(k, true);
            handler.passHoldersPart(k);
        }
        assertGt(handler.burnPieces(), 2, "Reward Burns and the burn's Destination's");
        assertGt(handler.supportPieces(), 2);
        assertEq(handler.holdersBuys(), 1, "the one coin whose Payout Asset is the coin");
        assertEq(handler.partsPassed(), 3);
        assertEq(handler.graduatedCount(), 1, "the burn's buy recorded a lifted coin's Graduation, an hour held");

        handler.postRound(2, false, false, 0, type(uint256).max);
        handler.postRound(2, true, false, 1, type(uint256).max);
        handler.postRound(3, false, true, 2, type(uint256).max);
        handler.postBeyondThePot(2, false);
        handler.postBeyondThePot(2, true);
        assertEq(handler.roundsPosted(), 3);
        handler.cancel(0, 3);
        assertEq(handler.roundsCancelled(), 0, "only the Guard cancels");
        handler.cancel(0, 0);
        assertEq(handler.roundsCancelled(), 1);
        handler.postRound(2, false, false, 0, type(uint256).max);
        assertEq(handler.roundsPosted(), 4, "the cancelled round's pot was free for a root posted again");
        handler.claim(1, false);
        assertEq(handler.roundsPaid(), 0, "nothing pays inside the Round Delay");
        handler.claim(1, true);
        handler.claim(2, false);
        handler.claim(3, false);
        handler.claim(0, false);
        assertEq(handler.roundsPaid(), 3, "the cancelled round never pays");
        assertEq(handler.earningsRoundsPaid(), 1);
        assertEq(handler.coinRoundsPaid(), 1);

        handler.recordGraduation(6, false);
        assertEq(handler.graduations(), 1, "the other lifted coin, by the call anyone can make");
        handler.raise(1, 2, 0);
        assertEq(handler.raises(), 0, "no raise before Graduation");
        handler.lift(1, 0);
        handler.lift(4, 2);
        assertEq(handler.lifts(), 4);
        handler.recordGraduation(1, false);
        assertEq(handler.graduations(), 1, "no Graduation inside the hour");
        handler.recordGraduation(1, true);
        handler.recordGraduation(4, false);
        assertEq(handler.graduations(), 3);
        assertEq(handler.graduatedCount(), 4);

        handler.raise(1, 2, 3);
        handler.raise(1, 2, 15);
        assertEq(handler.raises(), 0, "neither the Admin nor a stranger raises");
        handler.raise(1, 2, 0);
        handler.raise(1, 1, 0);
        handler.raise(6, 3, 0);
        handler.raise(6, 2, 0);
        assertEq(handler.raises(), 2, "the ladder key raised twice and was refused a lowering twice");
        assertEq(hook.creatorTierOf(idOf(1)), 2);
        assertEq(hook.creatorTierOf(idOf(6)), 3);
        handler.trade(1, 0, true, true, 1 ether, 1);
        handler.trade(6, 1, true, true, 1 ether, 1);

        handler.claimLock(6, 3, true);
        assertEq(handler.lockClaims(), 0, "the Admin claims no lock");
        handler.claimLock(6, 0, false);
        handler.claimLock(3, 0, false);
        handler.claimLock(0, 0, false);
        assertEq(handler.lockClaims(), 2, "the Creator claims the locks of the coins that graduated, and no other");

        handler.adminWritesTheRegistry(0, 0, 3);
        handler.adminWritesTheRegistry(1, 1, -2);
        handler.adminWritesTheRegistry(3, 0, 0);
        assertEq(handler.adminWrites(), 3);
        handler.adminRotatesAKey(0, 0, false);
        handler.adminRotatesAKey(1, 1, true);
        assertEq(handler.keyRotations(), 2);
        handler.adminHandsOver();
        assertEq(handler.adminHandovers(), 1);
        assertEq(keys.admin(), adminTwo);
        handler.trade(0, 0, true, true, 1 ether, 1);
        assertGt(hook.creditOf(adminTwo, mockCurrency()), 0, "the platform's later share follows the Admin");
        handler.raise(4, 2, 0);
        assertEq(handler.raises(), 3, "the ladder key of the moment raises");
        handler.trade(2, 1, true, true, 1 ether, 1);
        handler.passHoldersPart(2);
        handler.postRound(2, false, false, 0, type(uint256).max);
        assertEq(handler.roundsPosted(), 5, "the round key of the moment posts");

        handler.removeSeed(0, 1);
        handler.removeSeed(2, 0);
        handler.removeSupport(0, 1);
        handler.removeSupport(1, 0);
        assertEq(handler.removalsTried(), 4);
        assertEq(handler.liquidityRemoved(), 0);

        invariant_liquidityNeverLeaves();
        invariant_aCreatorTierNeverFalls();
        invariant_aRoundNeverPaysMoreThanItsCoinsPot();
        invariant_theCreditsOfAFeeSumToTheFee();
        invariant_noKeyOfOursMovesACreditALockOrASeed();
        invariant_conservation();
        invariant_solvency();
        invariant_monotonicity();
        handler.trade(5, 2, true, true, 1 ether, 1);
        invariant_monotonicity();
    }

    /// The fifth invariant's detector is live: a Credit rewritten in the hook's storage inside the window of a
    /// key's call is seen. No guard in the contracts can be removed to show this, since no function of theirs
    /// lets a key move a Credit at all; the canary stands in for one.
    function test_wholeSet_theKeyCheckSeesAMovedCredit() public {
        handler.trade(0, 0, true, true, 5 ether, 1);
        bytes32 before = this.fingerprint(bytes32(0));
        // `_credits` is the hook's mapping of owner to asset to amount; find the Creator's slot by its value.
        uint256 owed = hook.creditOf(creator, mockCurrency());
        assertGt(owed, 0);
        bool rewritten;
        for (uint256 slot; slot < 40 && !rewritten; slot++) {
            bytes32 inner = keccak256(abi.encode(mockCurrency(), keccak256(abi.encode(creator, slot))));
            if (uint256(vm.load(address(hook), inner)) == owed) {
                vm.store(address(hook), inner, bytes32(owed - 1));
                rewritten = true;
            }
        }
        assertTrue(rewritten, "the Creator's Credit was found in the hook's storage");
        assertTrue(this.fingerprint(bytes32(0)) != before, "the fingerprint sees a moved Credit");
    }
}

/// The two properties of the security standards that probe the set after every call: no unauthorised caller
/// reaches a privileged function, and a round trip through a pool never returns more than it cost. Each probe
/// runs in a snapshot that is rolled back, which is slow, so this contract's campaigns run fewer times than the
/// one above; the handler and the fixture are the same.
/// forge-config: default.invariant.runs = 32
/// forge-config: ci.invariant.runs = 32
contract WholeSetProbesInvariantTest is WholeSetFixture, AccessControlProperties, RoundingDirectionProperties {
    address internal roundTripper = makeAddr("roundTripper");

    /// Every privileged function of the set, each with callers that must be refused whatever the state: a
    /// stranger, and the holders of the other roles, read at the moment since the campaign rotates them.
    function privilegedCalls() public view override returns (PrivilegedCall[] memory c) {
        address admin = keys.admin();
        address round = keys.holderOf(StokerKeys.Role.RoundKey);
        address ladder = keys.holderOf(StokerKeys.Role.LadderKey);
        address keeperNow = keys.holderOf(StokerKeys.Role.Keeper);
        // A coin that has graduated where there is one, so only the caller stands between the call and a raise.
        uint256 k = handler.graduatedCount() != 0 ? handler.graduatedPool(0) : 0;
        PoolId id = _keys[k].toId();
        uint8 next = hook.creatorTierOf(id) < 3 ? hook.creatorTierOf(id) + 1 : 3;
        address coin = coinOf(2);
        uint256 number = distributor.roundCount() + 1;
        bytes32 root = keccak256("root");

        c = new PrivilegedCall[](22);
        uint256 n;
        bytes memory raise = abi.encodeCall(StokerHook.raiseTier, (id, next));
        c[n++] = PrivilegedCall("raiseTier, by the Admin", address(hook), raise, admin);
        c[n++] = PrivilegedCall("raiseTier, by the round key", address(hook), raise, round);
        c[n++] = PrivilegedCall("raiseTier, by the Keeper", address(hook), raise, keeperNow);
        c[n++] = PrivilegedCall("raiseTier, by a stranger", address(hook), raise, stranger);
        bytes memory register = abi.encodeCall(StokerHook.registerLaunch, (_keys[0], hook.termsOf(_keys[0].toId())));
        c[n++] = PrivilegedCall("registerLaunch, by the Admin", address(hook), register, admin);
        c[n++] = PrivilegedCall("registerLaunch, by the ladder key", address(hook), register, ladder);

        bytes memory post = abi.encodeCall(Distributor.postRoot, (number, coin, NATIVE, root, 1));
        c[n++] = PrivilegedCall("postRoot, by the Guard", address(distributor), post, admin);
        c[n++] = PrivilegedCall("postRoot, by the ladder key", address(distributor), post, ladder);
        c[n++] = PrivilegedCall("postRoot, by a stranger", address(distributor), post, stranger);
        bytes memory postEarnings = abi.encodeCall(Distributor.postEarningsRoot, (number, coin, NATIVE, root, 1));
        c[n++] = PrivilegedCall("postEarningsRoot, by the Keeper", address(distributor), postEarnings, keeperNow);
        bytes memory cancel = abi.encodeCall(Distributor.cancelRoots, (1, type(uint256).max));
        c[n++] = PrivilegedCall("cancelRoots, by the round key", address(distributor), cancel, round);
        c[n++] = PrivilegedCall("cancelRoots, by a stranger", address(distributor), cancel, stranger);
        bytes memory deposit = abi.encodeCall(Distributor.deposit, (coin, mockCurrency(), 0));
        c[n++] = PrivilegedCall("deposit, by the Admin", address(distributor), deposit, admin);
        bytes memory earnings = abi.encodeCall(Distributor.depositEarnings, (_keys[2], 0));
        c[n++] = PrivilegedCall("depositEarnings, by a stranger", address(distributor), earnings, stranger);

        bytes memory list = abi.encodeCall(QuoteRegistry.list, (address(0xBEEF), START_TICK, 20, 100));
        c[n++] = PrivilegedCall("list, by the round key", address(registry), list, round);
        c[n++] = PrivilegedCall("list, by a stranger", address(registry), list, stranger);
        bytes memory delist = abi.encodeCall(QuoteRegistry.delist, (address(0)));
        c[n++] = PrivilegedCall("delist, by the ladder key", address(registry), delist, ladder);
        bytes memory propose = abi.encodeCall(StokerKeys.proposeKey, (StokerKeys.Role.RoundKey, stranger));
        c[n++] = PrivilegedCall("proposeKey, by the Keeper", address(keys), propose, keeperNow);
        bytes memory revoke = abi.encodeCall(StokerKeys.revokeKey, (StokerKeys.Role.LadderKey));
        c[n++] = PrivilegedCall("revokeKey, by the round key", address(keys), revoke, round);
        bytes memory handover = abi.encodeCall(StokerKeys.proposeAdmin, (stranger));
        c[n++] = PrivilegedCall("proposeAdmin, by a stranger", address(keys), handover, stranger);

        bytes memory claim = abi.encodeCall(StokerCreatorLock.claim, ());
        c[n++] = PrivilegedCall("a Creator Lock's claim, by the Admin", _locks[0], claim, admin);
        bytes memory callback = abi.encodeCall(StokerFactory.unlockCallback, (""));
        c[n++] = PrivilegedCall("the factory's unlock callback, by a stranger", address(factory), callback, stranger);
    }

    function actors() public view override returns (address[] memory who) {
        who = new address[](1);
        who[0] = roundTripper;
    }

    /// Awkward amounts for an asset of 18 decimals, small and near a whole unit.
    function roundTripProbeAmounts() public pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](4);
        amounts[0] = 1e9 + 1;
        amounts[1] = 1e13 + 7;
        amounts[2] = uint256(3e17) / 7;
        amounts[3] = 1e18 + 1;
    }

    /// Buys a coin with `amount` of its Quote Asset and sells everything it bought straight back, in a pool the
    /// state chooses: what comes back is never more than what was paid, whatever the fees, the tax and the
    /// rounding of each.
    function roundTrip(address actor, uint256 amount) public override returns (uint256 returned) {
        uint256 k = uint256(keccak256(abi.encode(amount, vm.getBlockTimestamp(), handler.swaps()))) % _keys.length;
        Currency asset = quoteOf(k);
        _top(actor);
        IERC20 coin = IERC20(coinOf(k));
        uint256 coins = coin.balanceOf(actor);
        this.tradeAs(k, actor, true, true, amount, "");
        uint256 afterBuy = _balance(asset, actor);
        this.tradeAs(k, actor, false, true, coin.balanceOf(actor) - coins, "");
        returned = _balance(asset, actor) - afterBuy;
    }
}
