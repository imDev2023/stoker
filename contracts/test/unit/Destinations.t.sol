// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {Distributor} from "../../src/Distributor.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";
import {
    CharityDestination,
    ReenteringDestination,
    ApplyingRecipient,
    ShortHandOverDestination
} from "../utils/TestDestinations.sol";
import {RevertingRecipient, GasBurningRecipient, ReentrantPayoutRecipient} from "../utils/Recipients.sol";
import {UnlockedCaller} from "./TaxVaultHostile.t.sol";

/// The three Creator Earnings Destinations other than the wallet (#248, ADR 0011's rules on an EVM chain):
/// the holders, the burn and the liquidity. Each is the owner of its coins' Creator Credits, paid by the
/// Payout Call like any owner, and applies each coin's own earnings to that coin by a call anyone can make.
contract DestinationsTest is DestinationsLocalBase {
    /// The gas a Keeper sends with one call in these tests.
    uint256 internal constant KEEPER_GAS = 1_000_000;

    function _apply(EarningsDestination d, PoolKey memory key) internal returns (uint256) {
        vm.prank(stranger);
        return d.applyEarnings(key);
    }

    function _kinds() internal view returns (EarningsDestination[3] memory) {
        return [
            EarningsDestination(payable(address(burnDestination))),
            EarningsDestination(payable(address(liquidityDestination))),
            EarningsDestination(payable(address(holdersDestination)))
        ];
    }

    /// What the contract a Destination hands a coin's earnings to counts for that coin: the vault's funded
    /// burn, its funded Support Liquidity, or the Distributor's earnings pot.
    function _handedOver(EarningsDestination d, PoolKey memory key) internal view returns (uint256) {
        TaxVault.Books memory b = taxVault.booksOf(key.toId());
        if (address(d) == address(burnDestination)) return b.burnFunded;
        if (address(d) == address(liquidityDestination)) return b.supportFunded;
        return distributor.earningsPotOf(address(_coinOfKey(key)), _quoteOfKey(key));
    }

    function _payoutByKeeper(PoolKey memory key, address owner) internal {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (owner, platform);
        vm.prank(stranger);
        hook.payout{gas: KEEPER_GAS}(_quoteOfKey(key), owners);
    }

    // ---------------------------------------------------------------- the burn

    /// A coin whose Creator's earnings burn it: the earnings reach the Tax Vault's burn for that coin, its
    /// capped buys burn what they buy, and the supply falls. The buy pays the Platform Fee, so the rule
    /// compounds: part of each piece is the Creator's again.
    function test_burn_theEarningsBuyTheCoinAndBurnIt() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(burnDestination));
            IERC20 coin = _coinOfKey(key);
            _churn(key, 3);
            uint256 credited = _credited(key);
            assertGt(credited, 0);
            assertEq(burnDestination.waitingOf(key), credited);

            vm.expectEmit(true, true, false, true, address(burnDestination));
            emit EarningsDestination.EarningsApplied(key.toId(), _quoteOfKey(key), credited);
            uint256 applied = _apply(burnDestination, key);
            assertEq(applied, credited, "exactly what the coin's swaps credited its Destination");
            assertEq(burnDestination.appliedOf(key.toId()), credited);
            assertEq(burnDestination.waitingOf(key), 0);
            (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(key);
            assertEq(burnFunded, credited, "all of it waits in the coin's burn");
            assertEq(supportFunded, 0);
            assertEq(_creditIn(key, address(burnDestination)), 0, "its Credit was paid to it");

            // The price the trading left must have stood before the vault buys at it (#271).
            _letThePriceStand();
            uint256 supply = coin.totalSupply();
            uint256 burnedInAll;
            for (uint256 i; i < 50; i++) {
                (burnFunded,) = taxVault.fundedWaiting(key);
                if (burnFunded == 0) break;
                uint256 cap = taxVault.pieceCap(key);
                vm.prank(stranger);
                (uint256 spent, uint256 burned) = taxVault.burn(key);
                assertLe(spent, cap, "a capped piece");
                burnedInAll += burned;
                _letThePriceStand();
            }
            assertGt(burnedInAll, 0);
            assertEq(supply - coin.totalSupply(), burnedInAll, "the supply fell by exactly what was bought");
            assertEq(coin.balanceOf(address(taxVault)), 0);
            assertEq(coin.balanceOf(address(burnDestination)), 0);
            // The vault's buys paid the Platform Fee, the Creator's part of which is this coin's again.
            assertEq(burnDestination.waitingOf(key), _credited(key) - credited);
            assertGt(burnDestination.waitingOf(key), 0, "the rule compounds");
        }
    }

    // ---------------------------------------------------------------- the liquidity

    /// A coin whose Creator's earnings deepen its market: they become Support Liquidity in the coin's own
    /// pool, Quote Asset alone, with no coin bought and the price unmoved.
    function test_liquidity_theEarningsBecomeSupportLiquidity_noCoinBought() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(liquidityDestination));
            IERC20 coin = _coinOfKey(key);
            _churn(key, 3);
            uint256 credited = _credited(key);

            uint256 applied = _apply(liquidityDestination, key);
            assertEq(applied, credited);
            (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(key);
            assertEq(supportFunded, credited, "all of it waits for the coin's Support Liquidity");
            assertEq(burnFunded, 0);

            uint160 price = _sqrtPrice(key);
            uint256 supply = coin.totalSupply();
            uint256 inPool = coin.balanceOf(address(pm));
            uint256 addedInAll;
            uint256 pieces;
            for (uint256 i; i < 50; i++) {
                (, supportFunded) = taxVault.fundedWaiting(key);
                if (supportFunded <= 2) break;
                vm.recordLogs();
                (Support memory s, uint256 added) = _addSupport(key);
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 l; l < logs.length; l++) {
                    assertTrue(logs[l].topics[0] != IPoolManager.Swap.selector, "no swap: no coin bought");
                }
                assertGt(_supportLiquidity(key, s), 0, "the vault holds the position");
                (, uint256 coinsHeld) = _supportHoldings(key, s);
                assertEq(coinsHeld, 0, "Quote Asset alone");
                addedInAll += added;
                pieces++;
                skip(PIECE_INTERVAL);
            }
            assertGt(pieces, 0);
            assertGe(addedInAll + 2 * pieces, credited, "all of the earnings but each piece's rounding");
            assertLe(addedInAll, credited);
            assertEq(_sqrtPrice(key), price, "the price did not move");
            assertEq(coin.totalSupply(), supply, "nothing was burned");
            assertEq(coin.balanceOf(address(pm)), inPool, "no coin left the pool");
            assertEq(coin.balanceOf(address(taxVault)), 0);
            assertEq(_credited(key), credited, "no buy, so no fee: nothing compounds here");
        }
    }

    // ---------------------------------------------------------------- the holders

    /// A coin whose Creator's earnings go to its holders: they join the coin's earnings pot in the
    /// Distributor, and a Round Root of their own pays them as Holder Dividends after the Round Delay.
    function test_holders_theEarningsArePaidByARoundRootOfTheirOwn() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(holdersDestination));
            address coin = address(_coinOfKey(key));
            Currency asset = _quoteOfKey(key);
            _churn(key, 3);
            uint256 credited = _credited(key);

            uint256 applied = _apply(holdersDestination, key);
            assertEq(applied, credited);
            assertEq(distributor.earningsPotOf(coin, asset), credited, "the coin's earnings pot");
            assertEq(distributor.earningsAvailableOf(coin, asset), credited, "all of it a root may reserve");
            assertEq(distributor.potOf(coin, asset), 0, "nothing in the Reward Tax's pot");

            address alice = makeAddr(string.concat("alice", vm.toString(kind)));
            address bob = makeAddr(string.concat("bob", vm.toString(kind)));
            (address[] memory holders, uint256[] memory amounts) = _pair(alice, credited / 3, bob, credited / 2);
            Built memory round = _build(coin, asset, holders, amounts);
            vm.prank(roundKey);
            distributor.postEarningsRoot(round.round, coin, asset, round.root, round.total);
            _warpPastDelay(round.round);
            vm.prank(stranger);
            distributor.claim{gas: KEEPER_GAS}(_claims(round));
            assertEq(_balance(asset, alice), credited / 3, "her Holder Dividend");
            assertEq(_balance(asset, bob), credited / 2);
            assertEq(distributor.earningsPotOf(coin, asset), credited - credited / 3 - credited / 2);
        }
    }

    /// A Reward Launch that also names the holders: its Reward Tax and its Creator's earnings reach the
    /// Distributor by their own ways, into pots of their own.
    function test_holders_onARewardLaunch_theTaxAndTheEarningsStayApart() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchRewardTo(kind, address(holdersDestination), 0, 0);
            address coin = address(_coinOfKey(key));
            Currency asset = _quoteOfKey(key);
            _churn(key, 3);
            uint256 credited = _credited(key);
            uint256 tax = _taxBooked(key);

            uint256 held = _balance(asset, address(distributor));
            _apply(holdersDestination, key);
            vm.prank(stranger);
            taxVault.passHoldersPart(key);
            assertEq(distributor.earningsPotOf(coin, asset), credited, "the Creator's earnings");
            assertEq(distributor.potOf(coin, asset), tax, "the Reward Tax's holders' part");
            assertEq(_balance(asset, address(distributor)) - held, credited + tax, "and it holds both");
        }
    }

    // ---------------------------------------------------------------- two coins never mix

    /// One contract serves every coin that names it, and its Credits are all of theirs together. Whatever
    /// the order of the calls, each coin is given exactly what its own swaps credited, and what stays with
    /// the contract is exactly the other's.
    function test_destinations_twoCoinsEarningsNeverMix() public {
        for (uint256 kind; kind < 3; kind++) {
            EarningsDestination[3] memory d = _kinds();
            for (uint256 i; i < d.length; i++) {
                PoolKey memory a = _launchTo(kind, address(d[i]));
                PoolKey memory b = _launchTo(kind, address(d[i]));
                Currency asset = _quoteOfKey(a);
                _churn(a, 3);
                _churn(b, 1);
                uint256 creditedA = _credited(a);
                uint256 creditedB = _credited(b);
                assertGt(creditedA, creditedB);
                uint256 heldBefore = _balance(asset, address(d[i]));
                uint256 owedBefore = _creditIn(a, address(d[i]));

                // A Keeper's Payout Call pays the contract every coin's earnings at once.
                _payoutByKeeper(a, address(d[i]));
                assertEq(_creditIn(a, address(d[i])), 0);
                assertEq(_balance(asset, address(d[i])) - heldBefore, owedBefore, "paid like any Credit owner");

                // The smaller coin first: exactly its own, and the larger coin's stays behind untouched.
                assertEq(_apply(d[i], b), creditedB, "coin B: exactly its own");
                assertEq(_handedOver(d[i], b), creditedB);
                assertEq(_handedOver(d[i], a), 0, "nothing of it went to coin A");
                assertEq(d[i].waitingOf(a), creditedA, "coin A's still waits, whole");
                assertGe(_balance(asset, address(d[i])), creditedA, "and is still held");

                assertEq(_apply(d[i], a), creditedA, "coin A: exactly its own");
                assertEq(_handedOver(d[i], a), creditedA);
                assertEq(_handedOver(d[i], b), creditedB, "coin B's figure did not move");
                assertEq(d[i].appliedOf(a.toId()), creditedA);
                assertEq(d[i].appliedOf(b.toId()), creditedB);
            }
        }
    }

    /// What a Destination contract holds and is owed is exactly what its coins have earned and it has not
    /// applied: nothing is lost between the Payout Call and the hand-over, and nothing is left over.
    function test_destinations_whatItHoldsIsWhatItsCoinsAreOwed() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory a = _launchTo(kind, address(holdersDestination));
            PoolKey memory b = _launchTo(kind, address(holdersDestination));
            Currency asset = _quoteOfKey(a);
            uint256 heldAtStart = _balance(asset, address(holdersDestination));
            uint256 owedAtStart = _creditIn(a, address(holdersDestination));
            _churn(a, 2);
            _churn(b, 2);
            _payoutByKeeper(a, address(holdersDestination));
            _churn(a, 1);
            uint256 waiting = holdersDestination.waitingOf(a) + holdersDestination.waitingOf(b);
            assertEq(
                _balance(asset, address(holdersDestination)) + _creditIn(a, address(holdersDestination)) - heldAtStart
                    - owedAtStart,
                waiting,
                "held and owed is what waits"
            );
            _apply(holdersDestination, a);
            _apply(holdersDestination, b);
            assertEq(_balance(asset, address(holdersDestination)), heldAtStart + owedAtStart);
            assertEq(_creditIn(a, address(holdersDestination)), 0);
        }
    }

    // ---------------------------------------------------------------- hostile callers

    /// A public call made for the wrong coin: one that names the Creator's wallet, one that names another
    /// Destination, and a pool that is not ours. None moves anything.
    function test_destinations_aCallForTheWrongCoinIsRefused() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory walletCoin = _launchTo(kind, address(0));
            PoolKey memory burnCoin = _launchTo(kind, address(burnDestination));
            PoolKey memory liquidityCoin = _launchTo(kind, address(liquidityDestination));
            _churn(walletCoin, 1);
            _churn(burnCoin, 1);
            _churn(liquidityCoin, 1);
            PoolKey memory notOurs = _onAnotherSpacing(burnCoin);

            EarningsDestination[3] memory d = _kinds();
            for (uint256 i; i < d.length; i++) {
                PoolKey[4] memory wrong = [walletCoin, i == 0 ? liquidityCoin : burnCoin, notOurs, notOurs];
                for (uint256 w; w < 3; w++) {
                    vm.prank(stranger);
                    vm.expectRevert(EarningsDestination.NotThisCoinsDestination.selector);
                    d[i].applyEarnings(wrong[w]);
                    assertEq(d[i].waitingOf(wrong[w]), 0);
                }
            }
            // The coins' own earnings are where they were.
            assertEq(_handedOver(burnDestination, burnCoin), 0);
            assertGt(_credited(burnCoin), 0);
            assertEq(burnDestination.waitingOf(burnCoin), _credited(burnCoin));
            assertEq(liquidityDestination.waitingOf(liquidityCoin), _credited(liquidityCoin));
        }
    }

    function test_destinations_nothingToApply() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(burnDestination));
        vm.expectRevert(EarningsDestination.NothingToApply.selector);
        burnDestination.applyEarnings(key);
        _churn(key, 1);
        _apply(burnDestination, key);
        vm.expectRevert(EarningsDestination.NothingToApply.selector);
        burnDestination.applyEarnings(key);
    }

    /// The native asset reaches a Destination from the hook's Payout Call alone, within the gas a Keeper's
    /// call gives a recipient; nobody else can send it any.
    function test_destinations_theNativeAssetArrivesFromThePayoutCallAlone_withinItsGas() public {
        EarningsDestination[3] memory d = _kinds();
        for (uint256 i; i < d.length; i++) {
            PoolKey memory key = _launchTo(NATIVE_PAIR, address(d[i]));
            _churn(key, 2);
            uint256 owed = _nativeCredit(address(d[i]));
            assertGt(owed, 0);

            vm.expectEmit(true, true, false, true, address(hook));
            emit StokerHook.CreditPaid(address(d[i]), NATIVE, owed);
            _payoutByKeeper(key, address(d[i]));
            assertEq(address(d[i]).balance, owed, "paid, not refused, under a Keeper's gas");
            assertEq(_nativeCredit(address(d[i])), 0);

            vm.deal(stranger, 1 ether);
            vm.prank(stranger);
            (bool ok, bytes memory err) = address(d[i]).call{value: 1}("");
            assertFalse(ok, "a stranger's native asset is refused");
            assertEq(bytes4(err), EarningsDestination.NotHook.selector);

            assertEq(_apply(d[i], key), owed);
            assertEq(address(d[i]).balance, 0);
        }
    }

    /// A Destination the Stock Token's issuer blocks stays owed like any Credit owner and stops nobody: the
    /// swaps go on, the others are paid, and its coins' earnings are applied once it is unblocked.
    function test_destinations_aBlockedDestinationStaysOwed_andStopsNobody() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(burnDestination));
        _churn(key, 2);
        mockQuote.setBlocked(address(burnDestination), true);
        _churn(key, 1);
        uint256 owed = _credit(address(burnDestination));
        uint256 platformOwed = _credit(platform);

        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.CreditRefused(address(burnDestination), _quoteCurrency(), owed);
        _payoutByKeeper(key, address(burnDestination));
        assertEq(_credit(address(burnDestination)), owed, "it stays owed");
        assertEq(quote.balanceOf(platform), platformOwed, "the platform was paid beside it");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EarningsDestination.CreditNotReceived.selector, owed));
        burnDestination.applyEarnings(key);
        assertEq(burnDestination.appliedOf(key.toId()), 0, "nothing was applied on a Credit that did not arrive");

        mockQuote.setBlocked(address(burnDestination), false);
        assertEq(_apply(burnDestination, key), _credited(key));
    }

    /// The burn's and the liquidity's work opens unlocks of the hook and the vault, and the holders' the
    /// hook's, so none can run inside another unlock: not inside a trader's swap.
    function test_destinations_noWorkInsideAnUnlock() public {
        UnlockedCaller c = new UnlockedCaller(pm);
        EarningsDestination[3] memory d = _kinds();
        for (uint256 i; i < d.length; i++) {
            PoolKey memory key = _launchTo(QUOTE_FIRST, address(d[i]));
            _churn(key, 1);
            vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
            c.callInsideUnlock(address(d[i]), abi.encodeCall(EarningsDestination.applyEarnings, (key)));
        }
    }

    /// A Credit owner that calls a Destination's work from inside its own native payment meets the Payout
    /// Call's guard, so the work never runs on Credits a call has half paid; the Destination is then paid in
    /// the same call and works afterwards.
    function test_destinations_noWorkInsideAPayoutCall() public {
        PoolKey memory burnCoin = _launchTo(NATIVE_PAIR, address(burnDestination));
        ApplyingRecipient recipient = new ApplyingRecipient();
        PoolKey memory itsCoin = _launchTo(NATIVE_PAIR, address(recipient));
        recipient.aim(burnDestination, burnCoin);
        _churn(burnCoin, 1);
        _churn(itsCoin, 1);
        uint256 burnOwed = _nativeCredit(address(burnDestination));

        // It pulls its own, so it has all the gas it wants for the attempt.
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (address(recipient), address(burnDestination));
        vm.prank(address(recipient));
        hook.payout(NATIVE, owners);
        assertEq(recipient.attempts(), 1);
        assertEq(recipient.met(), StokerHook.PayoutReentered.selector, "the work met the Payout Call's guard");
        assertEq(burnDestination.appliedOf(burnCoin.toId()), 0);
        assertEq(address(burnDestination).balance, burnOwed, "the Destination was paid beside it");
        assertEq(_apply(burnDestination, burnCoin), _credited(burnCoin));
    }

    function test_destinations_workThatReentersMeetsTheGuard() public {
        ReenteringDestination d = new ReenteringDestination(hook);
        PoolKey memory a = _launchTo(QUOTE_FIRST, address(d));
        PoolKey memory b = _launchTo(QUOTE_FIRST, address(d));
        _churn(a, 1);
        _churn(b, 1);
        d.aim(b);
        vm.prank(stranger);
        d.applyEarnings(a);
        assertTrue(d.tried());
        assertEq(d.met(), EarningsDestination.Reentered.selector);
        assertEq(d.appliedOf(b.toId()), 0, "the call inside applied nothing");
        assertEq(d.appliedOf(a.toId()), _credited(a));
    }

    /// A hand-over that does not leave the Destination whole is refused, and nothing is counted as applied.
    function test_destinations_aHandOverTakenShortIsRefused() public {
        ShortHandOverDestination d = new ShortHandOverDestination(hook);
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(d));
        _churn(key, 1);
        vm.prank(stranger);
        vm.expectRevert(EarningsDestination.HandOverShort.selector);
        d.applyEarnings(key);
        assertEq(d.appliedOf(key.toId()), 0);
        assertEq(d.waitingOf(key), _credited(key));
    }

    // ---------------------------------------------------------------- a fourth kind

    /// The launch core knows nothing about Destination kinds: a fourth, written in the tests alone and
    /// deployed after the factory and the hook, is named by Launches and works, each coin's earnings kept
    /// apart by the hook's own book.
    function test_destinations_aFourthKind_withNoChangeToTheFactoryOrTheHook() public {
        address charity = makeAddr("charity");
        bytes32 factoryCode = keccak256(address(factory).code);
        bytes32 hookCode = keccak256(address(hook).code);
        CharityDestination fourth = new CharityDestination(hook, charity);
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory a = _launchTo(kind, address(fourth));
            PoolKey memory b = _launchTo(kind, address(fourth));
            Currency asset = _quoteOfKey(a);
            assertEq(_destinationOf(a), address(fourth), "the Launch's terms name it like any address");
            _churn(a, 2);
            _churn(b, 1);
            uint256 creditedA = _credited(a);
            uint256 creditedB = _credited(b);
            uint256 before = _balance(asset, charity);

            assertEq(_apply(fourth, b), creditedB);
            assertEq(fourth.givenOf(b.toId()), creditedB);
            assertEq(fourth.givenOf(a.toId()), 0);
            assertEq(_balance(asset, charity) - before, creditedB);
            assertEq(_apply(fourth, a), creditedA);
            assertEq(fourth.givenOf(a.toId()), creditedA);
            assertEq(_balance(asset, charity) - before, creditedA + creditedB);
        }
        assertEq(keccak256(address(factory).code), factoryCode, "the same factory");
        assertEq(keccak256(address(hook).code), hookCode, "the same hook");
    }

    // ---------------------------------------------------------------- a Creator's own contract

    /// A Creator may name a contract of their own. One that reverts, burns its gas or re-enters stays owed
    /// and stops nobody, under a Keeper's gas: the coin trades on, and the platform and an ordinary
    /// Creator are paid in the same call.
    function test_destinations_aCreatorsOwnHostileContractStaysOwed_andStopsNobody() public {
        address[3] memory hostile = [
            address(new RevertingRecipient()),
            address(new GasBurningRecipient()),
            address(new ReentrantPayoutRecipient(hook, false))
        ];
        PoolKey memory ordinary = _launchTo(NATIVE_PAIR, makeAddr("ordinaryCreator"));
        _churn(ordinary, 1);
        address[] memory owners = new address[](5);
        uint256[3] memory owed;
        for (uint256 i; i < hostile.length; i++) {
            PoolKey memory key = _launchTo(NATIVE_PAIR, hostile[i]);
            _churn(key, 2);
            owed[i] = _nativeCredit(hostile[i]);
            assertGt(owed[i], 0, "its Credits are booked like anyone's");
            owners[i] = hostile[i];
        }
        owners[3] = makeAddr("ordinaryCreator");
        owners[4] = platform;
        uint256 ordinaryOwed = _nativeCredit(owners[3]);
        uint256 platformOwed = _nativeCredit(platform);

        vm.prank(stranger);
        hook.payout{gas: KEEPER_GAS}(NATIVE, owners);
        for (uint256 i; i < hostile.length; i++) {
            assertEq(_nativeCredit(hostile[i]), owed[i], "it stays owed, to itself");
            assertEq(hostile[i].balance, 0);
        }
        assertEq(owners[3].balance, ordinaryOwed, "the ordinary Creator was paid");
        assertEq(platform.balance, platformOwed, "the platform was paid");
        assertEq(_nativeClaims(), hook.totalCredits(NATIVE), "the claims back every Credit");
    }
}
