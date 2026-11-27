// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {Distributor} from "../../src/Distributor.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";
import {WholeSetFixture} from "./WholeSetFixture.sol";

/// Drives the whole deployed set (#251). Traders trade in every pool, in all four kinds of swap, some naming
/// a referrer, some inside a Launch's opening seconds; coins of all three types are launched mid-campaign;
/// prices are lifted across Graduation Targets and dropped back, an hour is waited and Graduation recorded;
/// the ladder key raises, and everyone else tries to; a Keeper pays Credits, makes the Tax Vault's calls and
/// the Destinations' work; strangers fund coins; the round key posts rounds from either pot, in the Quote Asset
/// or the coin, the Guard cancels some, and claims are pushed; Creators claim their locks, and others try to;
/// the Admin writes the registry, rotates and revokes the server keys and hands itself over; the issuer blocks
/// and unblocks addresses; code at the factory's and the vault's own addresses tries to remove liquidity; and
/// time passes, by seconds, by the Graduation Hold's hour, by the Round Delay's day and by a lock's week.
///
/// What it sees it writes down: every event of a fee, so the Credits of every fee are summed from outside; what
/// stood in every pot; where every price was left, so Graduation is judged against a model kept here; and,
/// around every call a key of ours makes, a hash of everything no key may move.
contract WholeSetHandler is Test {
    WholeSetFixture internal immutable t;
    StokerHook internal immutable hook;
    TaxVault internal immutable vault;
    Distributor internal immutable distributor;
    StokerKeys internal immutable keys;
    QuoteRegistry internal immutable registry;
    address internal immutable factory;
    Currency internal constant NATIVE = Currency.wrap(address(0));

    address[4] internal actors;
    address[3] internal holders;
    /// The addresses a server key is rotated among.
    address[4] internal spares;

    struct Round {
        uint256 pool;
        bool earnings;
        Currency asset;
        address holder;
        uint256 amount;
        bool paid;
        bool cancelled;
    }

    struct Spot {
        uint256 pool;
        int24 lower;
        int24 upper;
    }

    Round[] internal _rounds;
    Spot[] internal _spots;
    uint256[] internal _graduated;
    mapping(bytes32 spot => uint128) public supportExpected;
    mapping(bytes32 spot => bool) internal _spotKnown;

    // What the campaign did, so a green run can be read.
    uint256 public swaps;
    uint256 public referredSwaps;
    uint256[3] public launchesOfType;
    uint256 public lifts;
    uint256 public graduations;
    uint256 public raises;
    uint256[3] public appliesOfKind;
    uint256 public burnPieces;
    uint256 public supportPieces;
    uint256 public holdersBuys;
    uint256 public partsPassed;
    uint256 public fundings;
    uint256 public payouts;
    uint256 public roundsPosted;
    uint256 public roundsCancelled;
    uint256 public roundsPaid;
    uint256 public earningsRoundsPaid;
    uint256 public coinRoundsPaid;
    uint256 public lockClaims;
    uint256 public adminWrites;
    uint256 public keyRotations;
    uint256 public adminHandovers;
    uint256 public removalsTried;

    // What must never happen: each is asserted zero by an invariant.
    uint256 public feeSplitBroken; // a fee whose two Credits did not sum to it, or whose split was not its tier's
    uint256 public tierLowered; // a raise that did not raise
    uint256 public wrongRaiser; // a raise by anyone but the ladder key of the moment, or of an ungraduated coin
    uint256 public graduatedWrongly; // Graduation recorded off the hour of a price that stood
    uint256 public graduationMoved; // a recorded Graduation that changed
    uint256 public keyMovedSomething; // a key's call after which something no key may move had moved
    uint256 public payoutMisdirected; // a Payout Call that paid anyone but a Credit's owner, or another sum
    uint256 public lockBreached; // a Creator Lock claimed by anyone but its Creator
    uint256 public liquidityRemoved; // a removal that went through
    uint256 public wrongCoinApplied; // a Destination's work for a coin that names another
    uint256 public misapplied; // work that applied other than what the coin had earned and not applied
    uint256 public potMixups; // a root that reached past its own pot, or a claim that moved another pot

    // Models kept from outside.
    mapping(uint256 pool => uint256) public aboveSince; // when a call first left the price at or above the target
    mapping(uint256 pool => uint256) public seenGraduatedAt;
    mapping(uint256 pool => uint8) public seenTier;
    mapping(uint256 pool => mapping(bool earnings => mapping(Currency asset => uint256))) public deposited;
    mapping(uint256 pool => mapping(bool earnings => mapping(Currency asset => uint256))) public paid;
    mapping(Currency asset => uint256) public credited; // every fee and Referrer Fee an event reported
    mapping(Currency asset => uint256) public paidOut; // every Credit an event reported paid
    mapping(uint256 pool => uint256) public lockClaimed;
    mapping(uint256 pool => uint256) public applied;
    mapping(uint256 pool => uint256) public strangersBurn;
    mapping(uint256 pool => uint256) public strangersSupport;

    constructor(WholeSetFixture t_) {
        t = t_;
        (address hook_, address vault_, address distributor_, address keys_, address registry_, address factory_) =
            t_.contracts();
        hook = StokerHook(payable(hook_));
        vault = TaxVault(payable(vault_));
        distributor = Distributor(distributor_);
        keys = StokerKeys(keys_);
        registry = QuoteRegistry(registry_);
        factory = factory_;
        actors = [makeAddr("w0"), makeAddr("w1"), makeAddr("w2"), makeAddr("w3")];
        holders = [makeAddr("wh0"), makeAddr("wh1"), makeAddr("wh2")];
        spares = [makeAddr("spare0"), makeAddr("spare1"), makeAddr("spare2"), makeAddr("spare3")];
        for (uint256 k; k < t_.poolCount(); k++) {
            seenTier[k] = 1;
        }
    }

    function actorList() external view returns (address[4] memory) {
        return actors;
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function spotCount() external view returns (uint256) {
        return _spots.length;
    }

    function spotAt(uint256 i) external view returns (uint256 pool, int24 lower, int24 upper, uint128 expected) {
        Spot memory s = _spots[i];
        return (s.pool, s.lower, s.upper, supportExpected[_spotId(s.pool, s.lower, s.upper)]);
    }

    function graduatedCount() external view returns (uint256) {
        return _graduated.length;
    }

    function graduatedPool(uint256 i) external view returns (uint256) {
        return _graduated[i];
    }

    function holderList() external view returns (address[3] memory) {
        return holders;
    }

    /// What `holder` is still owed in `asset` by the rounds posted, neither paid nor cancelled.
    function owedInRounds(address holder, Currency asset) external view returns (uint256 owed) {
        for (uint256 i; i < _rounds.length; i++) {
            Round storage r = _rounds[i];
            if (r.holder == holder && !r.paid && !r.cancelled && Currency.unwrap(r.asset) == Currency.unwrap(asset)) {
                owed += r.amount;
            }
        }
    }

    function _pool(uint256 seed) internal view returns (uint256) {
        return seed % t.poolCount();
    }

    /// A seed of a billion or more, which is what the fuzzer mostly gives, prefers a pool the call can do
    /// something with; a smaller one names its pool exactly, as a test driving the handler by hand does.
    function _prefers(uint256 seed) internal pure returns (bool) {
        return seed >= 1e9;
    }

    /// The first pool from the seed's on that stands as asked against its Graduation Target and has not
    /// graduated; the seed's own when none does.
    function _poolStanding(uint256 seed, bool above) internal view returns (uint256) {
        uint256 n = t.poolCount();
        if (!_prefers(seed)) return seed % n;
        for (uint256 i; i < n; i++) {
            uint256 k = (seed % n + i) % n;
            if (seenGraduatedAt[k] == 0 && (aboveSince[k] != 0) == above) return k;
        }
        return seed % n;
    }

    /// The first pool from the seed's on that is a Reward Launch's (paid in the coin, when asked).
    function _rewardPool(uint256 seed, bool mustPayInTheCoin) internal view returns (uint256) {
        uint256 n = t.poolCount();
        if (!_prefers(seed)) return seed % n;
        for (uint256 i; i < n; i++) {
            uint256 k = (seed % n + i) % n;
            (bool reward, bool inTheCoin) = t.rewardOf(k);
            if (reward && (inTheCoin || !mustPayInTheCoin)) return k;
        }
        return seed % n;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _spotId(uint256 pool, int24 lower, int24 upper) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, lower, upper));
    }

    /// A hash of every Support Liquidity position the campaign has seen added, for the fingerprint.
    function _supportDigest() internal view returns (bytes32 h) {
        for (uint256 i; i < _spots.length; i++) {
            Spot memory s = _spots[i];
            h = keccak256(abi.encode(h, t.supportNow(s.pool, s.lower, s.upper)));
        }
    }

    function _fingerprint() internal view returns (bytes32) {
        return t.fingerprint(_supportDigest());
    }

    // ------------------------------------------------ reading what happened from its events

    function _begin() internal {
        vm.recordLogs();
    }

    /// Discards what a call that reverted logged: its events are recorded all the same (gotcha 17).
    function _discard() internal {
        vm.getRecordedLogs();
    }

    /// Reads every event of the call that just went through, then looks at where it left every pool.
    function _end() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            bytes32 sig = l.topics.length == 0 ? bytes32(0) : l.topics[0];
            if (l.emitter == address(hook)) _readHook(l, sig);
            else if (l.emitter == address(vault)) _readVault(l, sig);
            else if (l.emitter == address(distributor)) _readDistributor(l, sig);
        }
        _observe();
    }

    function _readHook(Vm.Log memory l, bytes32 sig) internal {
        if (sig == StokerHook.FeeCredited.selector) {
            (uint256 fee, uint256 creatorCredit, uint256 platformCredit) =
                abi.decode(l.data, (uint256, uint256, uint256));
            // The two Credits of a fee sum to it, and the Creator's is its tier's share, rounded down.
            if (creatorCredit + platformCredit != fee) feeSplitBroken++;
            if (creatorCredit != fee * hook.creatorShareOf(PoolId.wrap(l.topics[1])) / 10_000) feeSplitBroken++;
            credited[_currency(l.topics[2])] += fee;
        } else if (sig == StokerHook.ReferrerFeeCredited.selector) {
            credited[_currency(l.topics[2])] += abi.decode(l.data, (uint256));
        } else if (sig == StokerHook.CreditPaid.selector) {
            paidOut[_currency(l.topics[2])] += abi.decode(l.data, (uint256));
        }
    }

    function _readVault(Vm.Log memory l, bytes32 sig) internal {
        if (sig == TaxVault.SupportAdded.selector) {
            uint256 k = t.indexOf(PoolId.wrap(l.topics[1]));
            (int24 lower, int24 upper, uint128 liquidity,) = abi.decode(l.data, (int24, int24, uint128, uint256));
            bytes32 id = _spotId(k, lower, upper);
            if (!_spotKnown[id]) {
                _spotKnown[id] = true;
                _spots.push(Spot(k, lower, upper));
            }
            supportExpected[id] += liquidity;
        } else if (sig == TaxVault.HoldersPartPassed.selector) {
            uint256 k = t.indexOf(PoolId.wrap(l.topics[1]));
            (Currency asset, uint256 amount) = abi.decode(l.data, (Currency, uint256));
            deposited[k][false][asset] += amount;
        }
    }

    function _readDistributor(Vm.Log memory l, bytes32 sig) internal {
        if (sig == Distributor.EarningsDeposited.selector) {
            uint256 k = t.indexOfCoin(address(uint160(uint256(l.topics[1]))));
            deposited[k][true][_currency(l.topics[2])] += abi.decode(l.data, (uint256));
        }
    }

    function _currency(bytes32 topic) internal pure returns (Currency) {
        return Currency.wrap(address(uint160(uint256(topic))));
    }

    /// Where the call left every pool's price, against its Graduation Target: the model of the Graduation Hold
    /// kept from outside. A coin may be recorded graduated only an hour after a call first left its price at
    /// or above the target with no call leaving it under since, and what was recorded never changes. The
    /// record is judged before the price this call left is noted: a hold that ran its hour graduates the coin
    /// whatever the recording call then did to the price. A coin's Creator Tier, read here after every call,
    /// never falls.
    function _observe() internal {
        uint256 n = t.poolCount();
        uint256 nowIs = vm.getBlockTimestamp();
        for (uint256 k; k < n; k++) {
            (bool above, uint256 at, uint8 tier) = t.observe(k);
            if (seenGraduatedAt[k] != 0) {
                if (at != seenGraduatedAt[k]) graduationMoved++;
            } else if (at != 0) {
                seenGraduatedAt[k] = at;
                _graduated.push(k);
                if (aboveSince[k] == 0 || at != aboveSince[k] + 1 hours || nowIs < at) graduatedWrongly++;
            }
            if (!above) aboveSince[k] = 0;
            else if (aboveSince[k] == 0) aboveSince[k] = nowIs;

            if (tier < seenTier[k]) tierLowered++;
            seenTier[k] = tier;
        }
    }

    // ------------------------------------------------ trading

    /// A trade of any of the four kinds, one time in four naming a referrer at up to the Listing's cap.
    function trade(uint256 poolSeed, uint256 actorSeed, bool buy, bool exactIn, uint256 amount, uint256 referrerSeed)
        public
    {
        uint256 k = _pool(poolSeed);
        address who = _actor(actorSeed);
        uint256 coins = IERC20(t.coinOf(k)).balanceOf(who);
        if (!buy && coins < 1e18) buy = true;
        uint256 unit = t.unitOf(k);
        if (buy) amount = exactIn ? bound(amount, unit / 100, 20 * unit) : bound(amount, 1e18, 1e28);
        else amount = exactIn ? bound(amount, 1e18, coins) : bound(amount, unit / 1_000, unit);
        bytes memory hookData;
        if (referrerSeed % 4 == 0) {
            hookData = abi.encode(_actor(referrerSeed / 4), bound(referrerSeed / 16, 1, 100));
        }
        _begin();
        try t.tradeAs(k, who, buy, exactIn, amount, hookData) {
            swaps++;
            if (hookData.length != 0) referredSwaps++;
            _end();
        } catch {
            _discard();
        }
    }

    /// More ways into a trade, so a run of the campaign always trades: every function here dilutes the trades
    /// of a run (gotcha 12).
    function buyOnly(uint256 poolSeed, uint256 actorSeed, uint256 amount, uint256 referrerSeed) external {
        trade(poolSeed, actorSeed, true, true, amount, referrerSeed);
    }

    function sellOnly(uint256 poolSeed, uint256 actorSeed, uint256 amount) external {
        trade(poolSeed, actorSeed, false, true, amount, 1);
    }

    function buyThenSell(uint256 poolSeed, uint256 actorSeed, uint256 amount) external {
        trade(poolSeed, actorSeed, true, true, amount, 1);
        trade(poolSeed, actorSeed, false, true, type(uint256).max, 1);
    }

    function buyExactOut(uint256 poolSeed, uint256 actorSeed, uint256 amount, uint256 referrerSeed) external {
        trade(poolSeed, actorSeed, true, false, amount, referrerSeed);
    }

    // ------------------------------------------------ launching

    function launch(uint256 typeSeed, uint256 kindSeed, uint256 destinationSeed, bool withLock, uint256 firstBuySeed)
        external
    {
        if (t.poolCount() >= t.maxPools()) return;
        _begin();
        try t.launchNew(typeSeed, kindSeed, destinationSeed, withLock, firstBuySeed) returns (uint256 k) {
            launchesOfType[typeSeed % 3]++;
            seenTier[k] = 1;
            _end();
        } catch {
            _discard();
        }
    }

    // ------------------------------------------------ Graduation

    /// A buy that leaves a coin's price past its Graduation Target.
    function lift(uint256 poolSeed, uint256 actorSeed) external {
        uint256 k = _poolStanding(poolSeed, false);
        uint256 amount = t.toCross(k);
        if (amount == 0) return;
        _begin();
        try t.tradeAs(k, _actor(actorSeed), true, true, amount, "") {
            swaps++;
            if (t.atOrAboveTarget(k)) lifts++;
            _end();
        } catch {
            _discard();
        }
    }

    /// Waits out the hour, or not, and makes the call anyone can make. A coin whose price a call left above its
    /// target an hour ago graduates; any other is refused.
    function recordGraduation(uint256 poolSeed, bool waitTheHour) external {
        uint256 k = _poolStanding(poolSeed, true);
        if (waitTheHour) vm.warp(vm.getBlockTimestamp() + 1 hours);
        _begin();
        try hook.graduate(t.idOf(k)) {
            graduations++;
            _end();
        } catch {
            _discard();
            _observe();
        }
    }

    // ------------------------------------------------ the Creator Ladder's key

    /// A raise: three times in four by the ladder key of the moment, otherwise by the Admin, the Keeper, the
    /// round key or a stranger. A seed of a billion or more prefers a coin that has graduated.
    function raise(uint256 poolSeed, uint256 tierSeed, uint256 callerSeed) external {
        uint256 k =
            poolSeed >= 1e9 && _graduated.length != 0 ? _graduated[poolSeed % _graduated.length] : _pool(poolSeed);
        PoolId id = t.idOf(k);
        uint8 tier = uint8(bound(tierSeed, 0, 4));
        address ladder = keys.holderOf(StokerKeys.Role.LadderKey);
        address caller = callerSeed % 4 != 3
            ? ladder
            : [
                keys.admin(),
                keys.holderOf(StokerKeys.Role.Keeper),
                keys.holderOf(StokerKeys.Role.RoundKey),
                t.strangerAddr()
            ][(callerSeed / 4) % 4];
        uint8 held = hook.creatorTierOf(id);
        bool wasGraduated = hook.graduationOf(id).graduatedAt != 0;
        bytes32 before = _fingerprint();
        _begin();
        vm.prank(caller);
        try hook.raiseTier(id, tier) {
            raises++;
            if (caller != ladder || ladder == address(0) || caller == keys.admin() || !wasGraduated) wrongRaiser++;
            if (tier <= held || tier > 3 || hook.creatorTierOf(id) != tier) tierLowered++;
            if (_fingerprint() != before) keyMovedSomething++;
            _end();
        } catch {
            _discard();
        }
    }

    // ------------------------------------------------ the Tax Vault's calls and the Destinations' work

    function vaultBurn(uint256 poolSeed, bool letThePriceStand) external {
        uint256 k = _pool(poolSeed);
        if (letThePriceStand) vm.warp(vm.getBlockTimestamp() + 30 days);
        _begin();
        vm.prank(keys.holderOf(StokerKeys.Role.Keeper));
        try vault.burn(t.keyOf(k)) {
            burnPieces++;
            _end();
        } catch {
            _discard();
            _observe();
        }
    }

    function vaultSupport(uint256 poolSeed) external {
        uint256 k = _pool(poolSeed);
        _begin();
        vm.prank(_actor(poolSeed));
        try vault.addSupport(t.keyOf(k)) {
            supportPieces++;
            _end();
        } catch {
            _discard();
        }
    }

    function buyForHolders(uint256 poolSeed, bool letThePriceStand) external {
        uint256 k = _rewardPool(poolSeed, true);
        if (letThePriceStand) vm.warp(vm.getBlockTimestamp() + 30 days);
        _begin();
        try vault.buyForHolders(t.keyOf(k)) {
            holdersBuys++;
            _end();
        } catch {
            _discard();
            _observe();
        }
    }

    function passHoldersPart(uint256 poolSeed) external {
        uint256 k = _rewardPool(poolSeed, false);
        _begin();
        try vault.passHoldersPart(t.keyOf(k)) {
            partsPassed++;
            _end();
        } catch {
            _discard();
        }
    }

    /// A stranger funds a coin's burn or its Support Liquidity: dust one time in two, more the other.
    function strangerFunds(uint256 poolSeed, uint256 actorSeed, bool burn, uint256 amount) external {
        uint256 k = _pool(poolSeed);
        uint256 unit = t.unitOf(k);
        amount = amount % 2 == 0 ? bound(amount, 1, unit / 1e9) : bound(amount, unit / 1e9, unit);
        _begin();
        try t.fundAs(k, _actor(actorSeed), burn, amount) {
            fundings++;
            if (burn) strangersBurn[k] += amount;
            else strangersSupport[k] += amount;
            _end();
        } catch {
            _discard();
        }
    }

    /// Anyone calls any Destination's work for any coin. It must go through only for a coin that names that
    /// Destination, and apply exactly what that coin has earned and had not applied.
    function applyEarnings(uint256 destinationSeed, uint256 poolSeed, uint256 callerSeed) public {
        uint256 k = _pool(poolSeed);
        EarningsDestination d = t.destinationAt(destinationSeed % 3);
        PoolKey memory key = t.keyOf(k);
        bool own = hook.termsOf(key.toId()).creatorDestination == address(d);
        uint256 waiting = hook.creatorCreditedOf(key.toId()) - d.appliedOf(key.toId());
        _begin();
        vm.prank(_actor(callerSeed));
        try d.applyEarnings(key) returns (uint256 amount) {
            appliesOfKind[destinationSeed % 3]++;
            if (!own) wrongCoinApplied++;
            if (amount != waiting) misapplied++;
            applied[k] += amount;
            _end();
        } catch {
            _discard();
        }
    }

    /// The same for the coin's own Destination, so the campaign applies often.
    function applyOwn(uint256 poolSeed) external {
        uint256 k = _pool(poolSeed);
        uint256 kind = t.kindOf(k);
        if (kind > 2) return;
        applyEarnings(kind, k, k);
    }

    // ------------------------------------------------ Payout Calls

    /// A Payout Call for every address a Credit can be booked to, by the Keeper or by a stranger. What each
    /// owner is owed and holds together must not change: a Credit is paid to its owner or stays owed to it.
    function payout(bool native, uint256 callerSeed) external {
        Currency asset = native ? NATIVE : t.mockCurrency();
        uint256 n = t.ownerCount();
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; i++) {
            address owner = t.ownerAt(i);
            before[i] = hook.creditOf(owner, asset) + t.balanceIn(asset, owner);
        }
        address caller = callerSeed % 2 == 0 ? keys.holderOf(StokerKeys.Role.Keeper) : t.strangerAddr();
        _begin();
        try t.payoutAll(asset, caller) {
            payouts++;
            for (uint256 i; i < n; i++) {
                address owner = t.ownerAt(i);
                if (hook.creditOf(owner, asset) + t.balanceIn(asset, owner) != before[i]) payoutMisdirected++;
            }
            _end();
        } catch {
            _discard();
        }
    }

    /// The issuer of the mock Stock Token blocks or unblocks an address a Credit can be booked to.
    function issuerBlocks(uint256 ownerSeed, bool blocked) external {
        t.setBlocked(t.ownerAt(ownerSeed % t.ownerCount()), blocked);
    }

    // ------------------------------------------------ rounds

    /// The round key of the moment posts a round for one holder from one of a coin's pots: its Reward Tax's or
    /// its Creator earnings', in the Quote Asset or, where the Payout Asset is the coin, in the coin.
    function postRound(uint256 poolSeed, bool earnings, bool inTheCoin, uint256 holderSeed, uint256 share) external {
        uint256 k = _pool(poolSeed);
        address coin;
        Currency asset;
        uint256 available;
        // The pot asked for, or, for a seed that prefers, the first pot from there on that holds something.
        uint256 tries = _prefers(poolSeed) ? 4 * t.poolCount() : 1;
        for (uint256 i; i < tries; i++) {
            coin = t.coinOf(k);
            asset = inTheCoin ? Currency.wrap(coin) : t.quoteOf(k);
            available = earnings ? distributor.earningsAvailableOf(coin, asset) : distributor.availableOf(coin, asset);
            if (available != 0) break;
            if (i % 4 == 0) earnings = !earnings;
            else if (i % 4 == 1) inTheCoin = !inTheCoin;
            else if (i % 4 == 2) earnings = !earnings;
            else (inTheCoin, k) = (!inTheCoin, (k + 1) % t.poolCount());
        }
        if (available == 0) return;
        uint256 amount = bound(share, 1, available);
        address holder = holders[holderSeed % holders.length];
        uint256 number = distributor.roundCount() + 1;
        // A tree of one leaf: its root is the leaf, and its proof is empty.
        bytes32 root = distributor.leafOf(number, coin, holder, amount);
        bytes32 before = _fingerprint();
        _begin();
        vm.prank(keys.holderOf(StokerKeys.Role.RoundKey));
        if (earnings) {
            try distributor.postEarningsRoot(number, coin, asset, root, amount) {
                _posted(k, earnings, asset, holder, amount, before);
            } catch {
                _discard();
            }
        } else {
            try distributor.postRoot(number, coin, asset, root, amount) {
                _posted(k, earnings, asset, holder, amount, before);
            } catch {
                _discard();
            }
        }
    }

    function _posted(uint256 k, bool earnings, Currency asset, address holder, uint256 amount, bytes32 before)
        internal
    {
        roundsPosted++;
        _rounds.push(Round(k, earnings, asset, holder, amount, false, false));
        if (_fingerprint() != before) keyMovedSomething++;
        _end();
    }

    /// A root that owes one unit more than its own pot holds unreserved, whatever the coin's other pot or
    /// another coin's holds. It must be refused.
    function postBeyondThePot(uint256 poolSeed, bool earnings) external {
        uint256 k = _pool(poolSeed);
        address coin = t.coinOf(k);
        Currency asset = t.quoteOf(k);
        uint256 own = earnings ? distributor.earningsAvailableOf(coin, asset) : distributor.availableOf(coin, asset);
        uint256 number = distributor.roundCount() + 1;
        bytes32 root = distributor.leafOf(number, coin, holders[0], own + 1);
        vm.prank(keys.holderOf(StokerKeys.Role.RoundKey));
        if (earnings) {
            try distributor.postEarningsRoot(number, coin, asset, root, own + 1) {
                potMixups++;
            } catch {}
        } else {
            try distributor.postRoot(number, coin, asset, root, own + 1) {
                potMixups++;
            } catch {}
        }
    }

    /// The Guard cancels a round; one time in four somebody else tries.
    function cancel(uint256 roundSeed, uint256 callerSeed) external {
        if (_rounds.length == 0) return;
        uint256 i = roundSeed % _rounds.length;
        address guard = keys.admin();
        address caller = callerSeed % 4 != 3 ? guard : keys.holderOf(StokerKeys.Role.RoundKey);
        bytes32 before = _fingerprint();
        vm.prank(caller);
        try distributor.cancelRoot(i + 1) {
            roundsCancelled++;
            _rounds[i].cancelled = true;
            if (caller != guard) keyMovedSomething++;
            if (_fingerprint() != before) keyMovedSomething++;
        } catch {}
    }

    /// A stranger pushes a round's claim. A seed of a billion or more prefers a round that may pay now. The
    /// round's own pot, and no other, falls by exactly what its holder received.
    function claim(uint256 roundSeed, bool waitOutTheDelay) external {
        if (_rounds.length == 0) return;
        uint256 i = roundSeed % _rounds.length;
        if (roundSeed >= 1e9) {
            for (uint256 j; j < _rounds.length; j++) {
                uint256 c = (i + j) % _rounds.length;
                if (!_rounds[c].paid && !_rounds[c].cancelled) {
                    i = c;
                    break;
                }
            }
        }
        Round storage r = _rounds[i];
        if (r.paid || r.cancelled) return;
        if (waitOutTheDelay) vm.warp(vm.getBlockTimestamp() + 1 days);
        address coin = t.coinOf(r.pool);
        uint256 taxPot = distributor.potOf(coin, r.asset);
        uint256 earningsPot = distributor.earningsPotOf(coin, r.asset);
        uint256 held = t.balanceIn(r.asset, r.holder);
        Distributor.Claim[] memory claims = new Distributor.Claim[](1);
        claims[0] = Distributor.Claim(i + 1, r.holder, r.amount, new bytes32[](0));
        vm.prank(_actor(i));
        try distributor.claim{gas: 1_000_000}(claims) {}
        catch {
            _observe();
            return; // still inside its Round Delay
        }
        uint256 received = t.balanceIn(r.asset, r.holder) - held;
        if (received == 0) return; // refused: it stays owed
        r.paid = true;
        roundsPaid++;
        if (r.earnings) earningsRoundsPaid++;
        if (Currency.unwrap(r.asset) == coin) coinRoundsPaid++;
        paid[r.pool][r.earnings][r.asset] += received;
        uint256 taxFell = taxPot - distributor.potOf(coin, r.asset);
        uint256 earningsFell = earningsPot - distributor.earningsPotOf(coin, r.asset);
        if (received != r.amount) potMixups++;
        if (r.earnings ? (earningsFell != r.amount || taxFell != 0) : (taxFell != r.amount || earningsFell != 0)) {
            potMixups++;
        }
        _observe();
    }

    // ------------------------------------------------ the Creator Lock

    /// The Creator claims a lock; one time in four the Admin, a server key or a stranger tries. A seed of a
    /// billion or more prefers a coin that has graduated, and may wait out a week first.
    function claimLock(uint256 poolSeed, uint256 callerSeed, bool waitAWeek) external {
        uint256 k =
            poolSeed >= 1e9 && _graduated.length != 0 ? _graduated[poolSeed % _graduated.length] : _pool(poolSeed);
        address lock = t.lockOf(k);
        if (lock == address(0)) return;
        if (waitAWeek) vm.warp(vm.getBlockTimestamp() + 7 days);
        address creator = t.creatorAddr();
        address caller = callerSeed % 4 != 3
            ? creator
            : [
                keys.admin(),
                keys.holderOf(StokerKeys.Role.Keeper),
                keys.holderOf(StokerKeys.Role.LadderKey),
                t.strangerAddr()
            ][(callerSeed / 4) % 4];
        IERC20 coin = IERC20(t.coinOf(k));
        uint256 held = coin.balanceOf(creator);
        bool wasGraduated = hook.graduationOf(t.idOf(k)).graduatedAt != 0;
        vm.prank(caller);
        try StokerCreatorLock(lock).claim() returns (uint256 amount) {
            lockClaims++;
            lockClaimed[k] += amount;
            if (caller != creator || !wasGraduated || coin.balanceOf(creator) != held + amount) lockBreached++;
        } catch {}
        _observe();
    }

    // ------------------------------------------------ the Admin's calls and the server keys

    /// A write of the Quote Registry by the Admin of the moment: a routine start price, a scheduled change, a
    /// withdrawal or a delisting, of the asset no coin is paired with and of the two that coins are. Nothing no
    /// key may move moves, and no launched coin's terms change.
    function adminWritesTheRegistry(uint256 which, uint256 assetSeed, int256 tickSeed) external {
        address asset = [t.otherQuoteAddr(), address(0), Currency.unwrap(t.mockCurrency())][assetSeed % 3];
        int24 current = registry.listingOf(asset).startTick;
        int24 tick = current + int24(bound(tickSeed, -10, 10)) * 200;
        bytes32 before = _fingerprint();
        vm.startPrank(keys.admin());
        which = which % 4;
        if (which == 0) {
            try registry.writeStartPrice(asset, tick) {
                adminWrites++;
            } catch {}
        } else if (which == 1) {
            try registry.scheduleChange(asset, tick, uint16(bound(assetSeed, 2, 40)), uint16(assetSeed % 501)) {
                adminWrites++;
            } catch {}
        } else if (which == 2) {
            try registry.withdrawChange(asset) {
                adminWrites++;
            } catch {}
        } else if (asset == t.otherQuoteAddr()) {
            // Only the asset no coin is paired with is delisted: the campaign goes on launching in the others.
            try registry.delist(asset) {
                adminWrites++;
            } catch {}
        }
        vm.stopPrank();
        if (_fingerprint() != before) keyMovedSomething++;
    }

    /// The Admin replaces a server key by its two steps, or revokes one at once and appoints another.
    function adminRotatesAKey(uint256 roleSeed, uint256 spareSeed, bool revokeFirst) external {
        StokerKeys.Role role = StokerKeys.Role(roleSeed % 3);
        address next = spares[spareSeed % spares.length];
        // No address holds two roles: the deployment's gate refuses it, and the campaign keeps to it.
        for (uint256 r; r < 3; r++) {
            if (keys.holderOf(StokerKeys.Role(r)) == next) return;
        }
        bytes32 before = _fingerprint();
        vm.startPrank(keys.admin());
        if (revokeFirst) keys.revokeKey(role);
        keys.proposeKey(role, next);
        vm.stopPrank();
        vm.prank(next);
        keys.acceptKey(role);
        keyRotations++;
        if (_fingerprint() != before) keyMovedSomething++;
    }

    /// The Admin hands itself over, by its two steps, between its two addresses. The platform's share of every
    /// later fee is booked to the new one; what the old one was owed stays owed to it.
    function adminHandsOver() external {
        address current = keys.admin();
        address next = current == t.adminTwoAddr() ? t.ownerAt(1) : t.adminTwoAddr();
        bytes32 before = _fingerprint();
        vm.prank(current);
        keys.proposeAdmin(next);
        vm.prank(next);
        keys.acceptAdmin();
        adminHandovers++;
        if (_fingerprint() != before) keyMovedSomething++;
    }

    // ------------------------------------------------ removing liquidity

    /// Code at the factory's own address tries to remove part of a Seed Position, or to poke it with nothing,
    /// which v4 counts as a removal too.
    function removeSeed(uint256 poolSeed, uint256 liquiditySeed) external {
        uint256 k = _pool(poolSeed);
        (int24 lower, int24 upper) = t.seedRangeOf(k);
        uint256 liquidity = liquiditySeed % 3 == 0 ? 0 : bound(liquiditySeed, 1, t.seedNow(k));
        removalsTried++;
        if (t.removeAs(factory, k, lower, upper, liquidity)) liquidityRemoved++;
    }

    /// The same at the Tax Vault's address, for a Support Liquidity position it holds.
    function removeSupport(uint256 spotSeed, uint256 liquiditySeed) external {
        if (_spots.length == 0) return;
        Spot memory s = _spots[spotSeed % _spots.length];
        uint128 has = t.supportNow(s.pool, s.lower, s.upper);
        uint256 liquidity = liquiditySeed % 3 == 0 ? 0 : bound(liquiditySeed, 1, has);
        removalsTried++;
        if (t.removeAs(address(vault), s.pool, s.lower, s.upper, liquidity)) liquidityRemoved++;
    }

    // ------------------------------------------------ time

    /// Seconds, most often; sometimes the Graduation Hold's hour, the Round Delay's day or a lock's week.
    function wait(uint256 seed) external {
        uint256 kind = seed % 8;
        uint256 span = kind < 5 ? bound(seed / 8, 1, 600) : kind == 5 ? 1 hours : kind == 6 ? 1 days : 8 days;
        vm.warp(vm.getBlockTimestamp() + span);
    }
}
