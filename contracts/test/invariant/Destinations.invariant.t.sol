// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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

/// Drives eight Launches on one hook, one Tax Vault and one Distributor (#248): two standard coins and a
/// Stoke Launch whose Creator's earnings burn the coin, two standard coins whose earnings become Support
/// Liquidity, two Reward Launches whose earnings go to the holders beside their Reward Tax, and one coin
/// paying its Creator's wallet; in the mock Stock Token in both currency orders and in the native asset.
/// Random traders trade; a Keeper pays the Destinations their Credits; anyone calls any Destination's work
/// for any coin, the wrong ones among them; strangers fund coins' burns and Support Liquidity with dust and
/// with more; the vault's calls are made; the round key posts rounds from either pot and the Guard cancels
/// some; claims are pushed; time passes; and Quote Asset is sent to the Destinations from outside.
contract DestinationsHandler is Test {
    DestinationsInvariantTest internal immutable t;
    StokerHook internal immutable hook;
    TaxVault internal immutable vault;
    Distributor internal immutable distributor;
    address[3] internal actors;

    struct Round {
        uint256 pool;
        bool earnings;
        address holder;
        uint256 amount;
        bool paid;
        bool cancelled;
    }

    Round[] internal _rounds;

    // Ghosts, per pool unless said otherwise.
    mapping(uint256 pool => uint256) public applied; // what a Destination's work reported applying
    mapping(uint256 pool => uint256) public strangersBurn; // what strangers funded the coin's burn with
    mapping(uint256 pool => uint256) public strangersSupport; // and its Support Liquidity
    mapping(uint256 pool => uint256) public taxDeposited; // the holders' part the vault passed on
    mapping(uint256 pool => uint256) public taxPaid; // what Reward Rounds paid holders
    mapping(uint256 pool => uint256) public earningsPaid; // what rounds of source earnings paid holders
    mapping(address destination => mapping(Currency asset => uint256)) public donated; // sent from outside
    uint256 public swaps;
    uint256 public applies;
    uint256 public wrongCoinApplied; // a Destination's work went through for a coin that does not name it
    uint256 public misapplied; // work that applied other than what the coin had earned and not applied
    uint256 public potMixups; // a claim after which the wrong pot had moved, or the right one by the wrong sum
    uint256 public burnPieces;
    uint256 public supportPieces;
    uint256 public roundsPaid;
    uint256 public earningsRoundsPaid;

    constructor(DestinationsInvariantTest t_, StokerHook hook_, TaxVault vault_, Distributor distributor_) {
        t = t_;
        hook = hook_;
        vault = vault_;
        distributor = distributor_;
        actors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function _pool(uint256 seed) internal view returns (uint256) {
        return seed % t.poolCount();
    }

    // ------------------------------------------------ trading and paying

    function trade(uint256 poolSeed, uint256 actorSeed, bool buy, uint256 amount) external {
        uint256 k = _pool(poolSeed);
        address who = actors[actorSeed % actors.length];
        uint256 coins = t.coinBalance(k, who);
        if (!buy && coins < 1e18) buy = true;
        amount = buy ? bound(amount, t.unitOf(k) / 100, 20 * t.unitOf(k)) : bound(amount, 1e18, coins);
        try t.tradeAs(k, who, buy, amount) {
            swaps++;
        } catch {}
    }

    /// More ways into a trade, so a run of the campaign always trades: every handler function added dilutes
    /// the trades in a run (gotcha 12).
    function buyOnly(uint256 poolSeed, uint256 actorSeed, uint256 amount) external {
        this.trade(poolSeed, actorSeed, true, amount);
    }

    function sellOnly(uint256 poolSeed, uint256 actorSeed, uint256 amount) external {
        this.trade(poolSeed, actorSeed, false, amount);
    }

    function buyThenSell(uint256 poolSeed, uint256 actorSeed, uint256 amount) external {
        this.trade(poolSeed, actorSeed, true, amount);
        this.trade(poolSeed, actorSeed, false, amount);
    }

    /// A Keeper's Payout Call for the three Destinations, the Creator and the Admin, in one asset.
    function keeperPayout(bool native) external {
        t.payoutAll(native);
    }

    // ------------------------------------------------ the Destinations' work

    /// Anyone calls any Destination's work for any coin. It must go through only for a coin that names that
    /// Destination, and apply exactly what that coin has earned and had not applied.
    function applyEarnings(uint256 destinationSeed, uint256 poolSeed, uint256 callerSeed) external {
        uint256 k = _pool(poolSeed);
        EarningsDestination d = t.destinationAt(destinationSeed % 3);
        PoolKey memory key = t.keyOf(k);
        bool own = hook.termsOf(key.toId()).creatorDestination == address(d);
        uint256 waiting = hook.creatorCreditedOf(key.toId()) - d.appliedOf(key.toId());
        vm.prank(actors[callerSeed % actors.length]);
        try d.applyEarnings(key) returns (uint256 amount) {
            applies++;
            if (!own) wrongCoinApplied++;
            // The pull inside the work cannot credit this pool: only a swap does.
            if (amount != waiting) misapplied++;
            applied[k] += amount;
        } catch {}
    }

    /// The same, for the coin's own Destination, so the campaign applies often.
    function applyOwn(uint256 poolSeed) external {
        uint256 k = _pool(poolSeed);
        uint256 index = t.destinationIndexOf(k);
        if (index > 2) return;
        this.applyEarnings(index, k, k);
    }

    /// A stranger funds a coin's burn or its Support Liquidity: dust one time in two, more the other.
    function strangerFunds(uint256 poolSeed, uint256 actorSeed, bool burn, uint256 amount) external {
        uint256 k = _pool(poolSeed);
        address who = actors[actorSeed % actors.length];
        uint256 unit = t.unitOf(k);
        amount = amount % 2 == 0 ? bound(amount, 1, unit / 1e9) : bound(amount, unit / 1e9, unit);
        try t.fundAs(k, who, burn, amount) {
            if (burn) strangersBurn[k] += amount;
            else strangersSupport[k] += amount;
        } catch {}
    }

    /// Quote Asset sent to a Destination from outside its coins' Credits: it belongs to no coin.
    function donate(uint256 destinationSeed, uint256 amount) external {
        EarningsDestination d = t.destinationAt(destinationSeed % 3);
        amount = bound(amount, 1, 1 ether);
        donated[address(d)][t.mockCurrency()] += t.donateMock(address(d), amount);
    }

    // ------------------------------------------------ the vault's calls

    function vaultBurn(uint256 poolSeed, bool letThePriceStand) external {
        uint256 k = _pool(poolSeed);
        if (letThePriceStand) vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(actors[k % actors.length]);
        try vault.burn(t.keyOf(k)) {
            burnPieces++;
        } catch {}
    }

    function vaultSupport(uint256 poolSeed) external {
        uint256 k = _pool(poolSeed);
        vm.prank(actors[k % actors.length]);
        try vault.addSupport(t.keyOf(k)) {
            supportPieces++;
        } catch {}
    }

    function passHoldersPart(uint256 poolSeed) external {
        uint256 k = _pool(poolSeed);
        try vault.passHoldersPart(t.keyOf(k)) returns (Currency, uint256 amount) {
            taxDeposited[k] += amount;
        } catch {}
    }

    // ------------------------------------------------ rounds

    /// The round key posts a round for one holder from one of a coin's two pots, for part of what that pot
    /// holds unreserved.
    function postRound(uint256 poolSeed, bool earnings, uint256 holderSeed, uint256 share) external {
        uint256 k = _pool(poolSeed);
        address coin = t.coinOf(k);
        Currency asset = t.quoteOf(k);
        uint256 available =
            earnings ? distributor.earningsAvailableOf(coin, asset) : distributor.availableOf(coin, asset);
        if (available == 0) return;
        uint256 amount = bound(share, 1, available);
        address holder = t.holderAt(holderSeed);
        uint256 round = distributor.roundCount() + 1;
        // A tree of one leaf: its root is the leaf, and its proof is empty.
        bytes32 root = distributor.leafOf(round, coin, holder, amount);
        vm.prank(t.roundKeyAddr());
        if (earnings) distributor.postEarningsRoot(round, coin, asset, root, amount);
        else distributor.postRoot(round, coin, asset, root, amount);
        _rounds.push(Round(k, earnings, holder, amount, false, false));
    }

    /// A round posted against the wrong pot's figure: more than its own pot holds, though the two together
    /// would cover it. It must be refused.
    function postBeyondItsOwnPot(uint256 poolSeed, bool earnings) external {
        uint256 k = _pool(poolSeed);
        address coin = t.coinOf(k);
        Currency asset = t.quoteOf(k);
        uint256 own = earnings ? distributor.earningsAvailableOf(coin, asset) : distributor.availableOf(coin, asset);
        uint256 other = earnings ? distributor.availableOf(coin, asset) : distributor.earningsAvailableOf(coin, asset);
        if (other == 0) return;
        uint256 round = distributor.roundCount() + 1;
        bytes32 root = distributor.leafOf(round, coin, t.holderAt(0), own + 1);
        vm.prank(t.roundKeyAddr());
        if (earnings) {
            try distributor.postEarningsRoot(round, coin, asset, root, own + 1) {
                potMixups++;
            } catch {}
        } else {
            try distributor.postRoot(round, coin, asset, root, own + 1) {
                potMixups++;
            } catch {}
        }
    }

    function cancel(uint256 roundSeed) external {
        if (_rounds.length == 0) return;
        uint256 i = roundSeed % _rounds.length;
        vm.prank(t.adminAddr());
        try distributor.cancelRoot(i + 1) {
            _rounds[i].cancelled = true;
        } catch {}
    }

    /// A stranger pushes one round's claim. The round's own pot, and no other, falls by what was paid.
    function claim(uint256 roundSeed, bool waitOutTheDelay) external {
        if (_rounds.length == 0) return;
        uint256 i = roundSeed % _rounds.length;
        Round storage r = _rounds[i];
        if (r.paid || r.cancelled) return;
        if (waitOutTheDelay) vm.warp(vm.getBlockTimestamp() + 1 days);
        address coin = t.coinOf(r.pool);
        Currency asset = t.quoteOf(r.pool);
        uint256 taxPot = distributor.potOf(coin, asset);
        uint256 earningsPot = distributor.earningsPotOf(coin, asset);
        uint256 balance = t.balanceIn(asset, r.holder);
        Distributor.Claim[] memory claims = new Distributor.Claim[](1);
        claims[0] = Distributor.Claim(i + 1, r.holder, r.amount, new bytes32[](0));
        vm.prank(actors[i % actors.length]);
        try distributor.claim{gas: 1_000_000}(claims) {}
        catch {
            return; // still inside its Round Delay
        }
        uint256 received = t.balanceIn(asset, r.holder) - balance;
        if (received == 0) return; // refused: it stays owed
        r.paid = true;
        roundsPaid++;
        uint256 taxFell = taxPot - distributor.potOf(coin, asset);
        uint256 earningsFell = earningsPot - distributor.earningsPotOf(coin, asset);
        if (r.earnings) {
            earningsRoundsPaid++;
            earningsPaid[r.pool] += received;
            if (received != r.amount || earningsFell != r.amount || taxFell != 0) potMixups++;
        } else {
            taxPaid[r.pool] += received;
            if (received != r.amount || taxFell != r.amount || earningsFell != 0) potMixups++;
        }
    }

    function wait(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 2 days));
    }
}

/// Invariants of the Creator Earnings Destinations (#248): each coin is handed exactly its own earnings and
/// nothing of another's; a Destination contract holds and is owed exactly what its coins have earned and it
/// has not applied; a coin's earnings and its Reward Tax never mix in a pot, in the Distributor or in the Tax
/// Vault; and the vault's claims are exactly the tax and the funding it has not spent.
contract DestinationsInvariantTest is DestinationsLocalBase {
    DestinationsHandler internal handler;
    PoolKey[] internal _keys;
    /// Each pool's Destination: 0 the burn, 1 the liquidity, 2 the holders, 3 the Creator's own wallet.
    uint256[] internal _kindOf;
    address[3] internal _holderPool = [makeAddr("h0"), makeAddr("h1"), makeAddr("h2")];

    function setUp() public override {
        super.setUp();
        _add(_launchTo(QUOTE_FIRST, address(burnDestination)), 0);
        _add(_launchTo(COIN_FIRST, address(burnDestination)), 0);
        _add(_launchRewardTo(QUOTE_FIRST, address(holdersDestination), 2_500, 2_500), 2);
        _add(_launchTo(NATIVE_PAIR, address(liquidityDestination)), 1);
        _add(_launchRewardTo(NATIVE_PAIR, address(holdersDestination), 0, 0), 2);
        _add(
            _launchTypedTo(
                NATIVE_PAIR,
                address(burnDestination),
                StokerHook.LaunchType.Liquidity,
                TAX_BPS,
                0,
                0,
                StokerHook.PayoutAsset.QuoteAsset
            ),
            0
        );
        _add(_launchTo(COIN_FIRST, address(liquidityDestination)), 1);
        _add(_launchTo(QUOTE_FIRST, address(0)), 3);
        handler = new DestinationsHandler(this, hook, taxVault, distributor);
        targetContract(address(handler));
    }

    function _add(PoolKey memory key, uint256 kind) internal {
        _keys.push(key);
        _kindOf.push(kind);
    }

    // ------------------------------------------------ the handler's window onto the fixture

    function poolCount() external view returns (uint256) {
        return _keys.length;
    }

    function keyOf(uint256 k) public view returns (PoolKey memory) {
        return _keys[k];
    }

    function quoteOf(uint256 k) public view returns (Currency) {
        return _quoteOfKey(_keys[k]);
    }

    function coinOf(uint256 k) public view returns (address) {
        return address(_coinOfKey(_keys[k]));
    }

    function unitOf(uint256 k) external view returns (uint256) {
        return _unit(_keys[k]);
    }

    function coinBalance(uint256 k, address who) external view returns (uint256) {
        return _coinOfKey(_keys[k]).balanceOf(who);
    }

    function destinationIndexOf(uint256 k) external view returns (uint256) {
        return _kindOf[k];
    }

    function destinationAt(uint256 i) public view returns (EarningsDestination) {
        if (i == 0) return EarningsDestination(payable(address(burnDestination)));
        if (i == 1) return EarningsDestination(payable(address(liquidityDestination)));
        return EarningsDestination(payable(address(holdersDestination)));
    }

    function holderAt(uint256 seed) external view returns (address) {
        return _holderPool[seed % 3];
    }

    function roundKeyAddr() external view returns (address) {
        return roundKey;
    }

    function adminAddr() external view returns (address) {
        return platform;
    }

    function mockCurrency() public view returns (Currency) {
        return Currency.wrap(address(quote));
    }

    function balanceIn(Currency asset, address who) public view returns (uint256) {
        return _balance(asset, who);
    }

    function tradeAs(uint256 k, address who, bool buy, uint256 amount) external {
        _top(who);
        _trade(_keys[k], who, buy, true, amount);
    }

    function fundAs(uint256 k, address who, bool burn, uint256 amount) external {
        _top(who);
        PoolKey memory key = _keys[k];
        bool isNative = _native(key);
        vm.startPrank(who);
        if (!isNative) quote.approve(address(taxVault), amount);
        if (burn) taxVault.fundBurn{value: isNative ? amount : 0}(key, amount);
        else taxVault.fundSupport{value: isNative ? amount : 0}(key, amount);
        vm.stopPrank();
    }

    function donateMock(address to, uint256 amount) external returns (uint256) {
        mockQuote.mint(to, amount);
        return amount;
    }

    function payoutAll(bool native) external {
        address[] memory owners = new address[](5);
        (owners[0], owners[1], owners[2]) =
        (address(burnDestination), address(liquidityDestination), address(holdersDestination));
        (owners[3], owners[4]) = (creator, platform);
        vm.prank(stranger);
        hook.payout{gas: 1_000_000}(native ? NATIVE : mockCurrency(), owners);
    }

    function _top(address who) internal {
        if (quote.balanceOf(who) < 1_000 ether) mockQuote.mint(who, 100_000 ether);
        if (who.balance < 100 ether) vm.deal(who, 10_000 ether);
    }

    // ------------------------------------------------ the invariants

    /// Each coin is handed exactly its own earnings: what its Destination applied for it is what the work
    /// reported, never more than its swaps credited, and it is what the contract that does the work counts
    /// for that coin, beside what strangers funded. No work went through for a coin that names another
    /// Destination, and none applied a sum other than the coin's own.
    function invariant_eachCoinIsHandedExactlyItsOwnEarnings() public view {
        assertEq(handler.wrongCoinApplied(), 0, "work went through for the wrong coin");
        assertEq(handler.misapplied(), 0, "work applied other than the coin's own earnings");
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            uint256 kind = _kindOf[k];
            TaxVault.Books memory b = taxVault.booksOf(id);
            uint256 applied = handler.applied(k);
            for (uint256 i; i < 3; i++) {
                assertEq(destinationAt(i).appliedOf(id), i == kind ? applied : 0, "applied by its own alone");
            }
            assertLe(applied, hook.creatorCreditedOf(id), "never more than the coin earned");
            assertEq(b.burnFunded, handler.strangersBurn(k) + (kind == 0 ? applied : 0), "the burn's funding");
            assertEq(
                b.supportFunded, handler.strangersSupport(k) + (kind == 1 ? applied : 0), "the liquidity's funding"
            );
            assertEq(
                distributor.earningsPotOf(coinOf(k), quoteOf(k)) + handler.earningsPaid(k),
                kind == 2 ? applied : 0,
                "the holders' earnings pot"
            );
        }
    }

    /// What a Destination contract holds and is owed in an asset is exactly what its coins have earned in it
    /// and it has not applied, beside what was sent to it from outside, which no coin can ever be handed.
    function invariant_aDestinationHoldsWhatItsCoinsWait() public view {
        Currency[2] memory assets = [mockCurrency(), NATIVE];
        for (uint256 i; i < 3; i++) {
            EarningsDestination d = destinationAt(i);
            for (uint256 a; a < 2; a++) {
                uint256 waiting;
                for (uint256 k; k < _keys.length; k++) {
                    if (_kindOf[k] != i || Currency.unwrap(quoteOf(k)) != Currency.unwrap(assets[a])) continue;
                    waiting += hook.creatorCreditedOf(_keys[k].toId()) - d.appliedOf(_keys[k].toId());
                }
                assertEq(
                    _balance(assets[a], address(d)) + hook.creditOf(address(d), assets[a]),
                    waiting + handler.donated(address(d), assets[a]),
                    "held and owed is what its coins wait"
                );
            }
        }
    }

    /// Earnings and tax never mix in a pot of the Distributor's: each of a coin's two pots is exactly what
    /// reached it by its own way less what its own rounds paid, no claim moved the other pot, no root was
    /// taken that only the other pot could cover, and what the Distributor holds is the pots together.
    function invariant_earningsAndTaxNeverMixInAPot() public view {
        assertEq(handler.potMixups(), 0, "a round reached into the other pot");
        uint256 mockPots;
        uint256 nativePots;
        for (uint256 k; k < _keys.length; k++) {
            address coin = coinOf(k);
            Currency asset = quoteOf(k);
            uint256 taxPot = distributor.potOf(coin, asset);
            uint256 earningsPot = distributor.earningsPotOf(coin, asset);
            assertEq(taxPot, handler.taxDeposited(k) - handler.taxPaid(k), "the Reward Tax's pot");
            assertEq(
                earningsPot, (_kindOf[k] == 2 ? handler.applied(k) : 0) - handler.earningsPaid(k), "the earnings pot"
            );
            assertLe(distributor.reservedOf(coin, asset), taxPot);
            assertLe(distributor.earningsReservedOf(coin, asset), earningsPot);
            if (asset.isAddressZero()) nativePots += taxPot + earningsPot;
            else mockPots += taxPot + earningsPot;
        }
        assertEq(quote.balanceOf(address(distributor)), mockPots, "it holds the pots, in the Stock Token");
        assertEq(address(distributor).balance, nativePots, "and in the native asset");
    }

    /// Nor in the Tax Vault: its claims in an asset are exactly the tax and the funding it has not spent,
    /// each path spent no more of the tax than its share whatever was funded beside it, and no more of the
    /// funding than was funded.
    function invariant_theVaultsClaimsAreTheUnspentTaxAndFunding() public view {
        uint256 mockWaiting;
        uint256 nativeWaiting;
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            StokerHook.Terms memory terms = hook.termsOf(id);
            TaxVault.Books memory b = taxVault.booksOf(id);
            uint256 booked = hook.taxBooked(id);
            assertLe(b.burnSpent, booked * terms.burnShareBps / 10_000, "the burn's share of the tax");
            assertLe(b.supportSpent, booked * terms.liquidityShareBps / 10_000, "the liquidity's share");
            assertLe(b.burnFundedSpent, b.burnFunded, "never more than was funded");
            assertLe(b.supportFundedSpent, b.supportFunded);
            uint256 waiting = booked - b.burnSpent - b.supportSpent - b.holdersSpent
                + (b.burnFunded - b.burnFundedSpent) + (b.supportFunded - b.supportFundedSpent);
            if (quoteOf(k).isAddressZero()) nativeWaiting += waiting;
            else mockWaiting += waiting;
        }
        assertEq(pm.balanceOf(address(taxVault), mockCurrency().toId()), mockWaiting, "the Stock Token");
        assertEq(pm.balanceOf(address(taxVault), NATIVE.toId()), nativeWaiting, "the native asset");
    }

    function invariant_theClaimsBackEveryCredit() public view {
        assertEq(pm.balanceOf(address(hook), mockCurrency().toId()), hook.totalCredits(mockCurrency()));
        assertEq(pm.balanceOf(address(hook), NATIVE.toId()), hook.totalCredits(NATIVE));
        assertEq(address(hook).balance, 0, "the hook holds no native asset between calls");
    }

    function afterInvariant() external view {
        assertGt(handler.swaps(), 0, "no swap went through");
    }

    /// The handler reaches what the invariants are about: driven by hand it applies each kind of Destination's
    /// earnings, refuses the wrong coins, funds, burns, places Support Liquidity, posts a round from each pot
    /// and pays both, and every invariant holds after it.
    function test_destinationsCampaign_theHandlerReachesEveryPath() public {
        for (uint256 k; k < _keys.length; k++) {
            handler.trade(k, k, true, 10 ether);
            handler.trade(k, k, false, 1e9 ether);
        }
        handler.keeperPayout(false);
        for (uint256 i; i < 3; i++) {
            for (uint256 k; k < _keys.length; k++) {
                handler.applyEarnings(i, k, k);
            }
        }
        assertEq(handler.applies(), 7, "each coin's own Destination, once");
        handler.strangerFunds(0, 0, true, 1);
        handler.strangerFunds(6, 1, false, 3);
        for (uint256 k; k < _keys.length; k++) {
            handler.vaultBurn(k, true);
            handler.vaultSupport(k);
            handler.passHoldersPart(k);
        }
        assertGt(handler.burnPieces(), 0);
        assertGt(handler.supportPieces(), 0);
        handler.postRound(2, true, 0, 1 ether);
        handler.postRound(2, false, 1, 1 ether);
        handler.postRound(4, true, 2, 1 ether);
        handler.postBeyondItsOwnPot(2, true);
        handler.postBeyondItsOwnPot(2, false);
        assertEq(handler.roundCount(), 3);
        for (uint256 r; r < 3; r++) {
            handler.claim(r, true);
        }
        assertEq(handler.roundsPaid(), 3);
        assertEq(handler.earningsRoundsPaid(), 2);
        handler.donate(0, 5);
        invariant_eachCoinIsHandedExactlyItsOwnEarnings();
        invariant_aDestinationHoldsWhatItsCoinsWait();
        invariant_earningsAndTaxNeverMixInAPot();
        invariant_theVaultsClaimsAreTheUnspentTaxAndFunding();
        invariant_theClaimsBackEveryCredit();
    }
}
