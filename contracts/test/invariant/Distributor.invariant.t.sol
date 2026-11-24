// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor} from "../../src/Distributor.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {GasBurningRecipient} from "../utils/Recipients.sol";
import {Merkle} from "../utils/Merkle.sol";

/// A holder that refuses the native asset while its switch is off.
contract ToggleHolder {
    bool public refusing;

    function set(bool refusing_) external {
        refusing = refusing_;
    }

    receive() external payable {
        if (refusing) revert("refusing");
    }
}

/// Drives the Distributor at random (#247): deposits into two coins' pots in a mock Stock Token and the
/// native asset, rounds posted by the round key for random holders at random amounts, the Guard's cancels
/// inside and after the delay, posts tried by the Guard and a stranger, time passing, batches of claims by
/// a stranger with duplicates and rounds still inside their delay, holders claiming their own, a holder
/// blocked and unblocked by the Stock Token, a native holder refusing at random and one that always burns
/// its gas. It records every `Claimed` event and checks it against the round, the clock and the holder's
/// balance.
contract DistributorHandler is Test {
    Distributor public immutable d;
    /// The depositor the Distributor was deployed with, in the Tax Vault's place: this campaign runs
    /// without a PoolManager, so it hands each deposit over as `TaxVault._deposit` does, from that address.
    address internal immutable vault;
    StokerKeys internal immutable keys;
    MockQuote public immutable mock;
    address internal immutable roundKey;
    address internal immutable guard;
    address internal immutable stranger = makeAddr("claimer");

    address[2] public coins;
    Currency[2] public assets;
    address[] public holders;
    ToggleHolder internal toggle;

    struct GhostRound {
        uint256 id;
        address coin;
        Currency asset;
        address[] holders;
        uint256[] amounts;
        bytes32[][] proofs;
        uint256 leafSum;
    }

    GhostRound[] internal _rounds;
    mapping(address coin => mapping(Currency asset => uint256)) public deposited;
    mapping(address coin => mapping(Currency asset => uint256)) public paidOut;
    mapping(uint256 round => mapping(address holder => uint256)) public paidTo;
    mapping(uint256 round => uint256) public paidByRound;
    mapping(address holder => mapping(Currency asset => uint256)) public received;

    bool public paidTwice;
    bool public paidInsideDelay;
    bool public paidCancelled;
    bool public paidPastLeaf;
    bool public postedByOther;
    bool public cancelledAfterDelay;
    bool public balanceMismatch;
    bool public rangeMiscount;
    uint256 public claimsPaid;
    /// What the campaign reached beside payments (from the review of PR #270): refusals, cancels by either
    /// call, false roots posted and false roots that stopped a claim at their total.
    uint256 public refusals;
    uint256 public cancels;
    uint256 public falseRounds;
    uint256 public falseRoundsCapped;
    mapping(uint256 round => bool) public isFalseRound;

    constructor(Distributor d_, address vault_, StokerKeys keys_, MockQuote mock_, address roundKey_, address guard_) {
        d = d_;
        vault = vault_;
        keys = keys_;
        mock = mock_;
        roundKey = roundKey_;
        guard = guard_;
        coins = [makeAddr("coinA"), makeAddr("coinB")];
        assets = [Currency.wrap(address(mock_)), Currency.wrap(address(0))];
        toggle = new ToggleHolder();
        holders.push(makeAddr("h0"));
        holders.push(makeAddr("h1"));
        holders.push(makeAddr("h2"));
        holders.push(makeAddr("blockable"));
        holders.push(address(toggle));
        holders.push(address(new GasBurningRecipient()));
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 coinSeed, uint256 assetSeed, uint256 amount) external {
        address coin = coins[coinSeed % 2];
        Currency asset = assets[assetSeed % 2];
        amount = bound(amount, 1, 1e21);
        vm.startPrank(vault);
        if (asset.isAddressZero()) {
            vm.deal(vault, vault.balance + amount);
            d.deposit{value: amount}(coin, asset, amount);
        } else {
            mock.mint(vault, amount);
            mock.approve(address(d), amount);
            d.deposit(coin, asset, amount);
        }
        vm.stopPrank();
        deposited[coin][asset] += amount;
    }

    function postRound(uint256 coinSeed, uint256 assetSeed, uint256 mask, uint256 amountSeed) external {
        _postRound(coinSeed, assetSeed, mask, amountSeed, false);
    }

    /// The round key posts a false root: its tree owes twice the total it is posted with. Claims must stop
    /// at the total, and the coin's other rounds keep their reservations.
    function postFalseRound(uint256 coinSeed, uint256 assetSeed, uint256 mask, uint256 amountSeed) external {
        _postRound(coinSeed, assetSeed, mask, amountSeed, true);
    }

    function _postRound(uint256 coinSeed, uint256 assetSeed, uint256 mask, uint256 amountSeed, bool falseRoot)
        internal
    {
        address coin = coins[coinSeed % 2];
        Currency asset = assets[assetSeed % 2];
        uint256 available = d.availableOf(coin, asset);
        if (available == 0) return;
        mask = bound(mask, 1, (1 << holders.length) - 1);
        uint256 n;
        for (uint256 i; i < holders.length; i++) {
            if (mask & (1 << i) != 0) n++;
        }
        GhostRound storage g = _rounds.push();
        g.id = d.roundCount() + 1;
        g.coin = coin;
        g.asset = asset;
        bytes32[] memory leaves = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < holders.length; i++) {
            if (mask & (1 << i) == 0) continue;
            uint256 amount = uint256(keccak256(abi.encode(amountSeed, i))) % (available / n + 1);
            g.holders.push(holders[i]);
            g.amounts.push(amount);
            g.leafSum += amount;
            leaves[k++] = keccak256(
                bytes.concat(keccak256(abi.encode(block.chainid, address(d), coin, g.id, holders[i], amount)))
            );
        }
        uint256 total = falseRoot ? g.leafSum / 2 : g.leafSum;
        if (total == 0) {
            _rounds.pop();
            return;
        }
        Merkle.Tree memory tree = Merkle.build(leaves);
        for (uint256 i; i < n; i++) {
            g.proofs.push(Merkle.proof(tree, i));
        }
        vm.prank(roundKey);
        d.postRoot(g.id, coin, asset, Merkle.root(tree), total);
        if (falseRoot) {
            isFalseRound[g.id] = true;
            falseRounds++;
        }
    }

    /// Claims one holder of a false round at a time, so a claim past its total reverts alone and the round
    /// fills up to its total.
    function claimFalseOne(uint256 seed) external {
        uint256[] memory pick = _pickable(false);
        for (uint256 p; p < pick.length; p++) {
            GhostRound storage g = _rounds[pick[(p + seed % pick.length) % pick.length]];
            if (!isFalseRound[g.id]) continue;
            uint256 j = seed % g.holders.length;
            Distributor.Claim[] memory c = new Distributor.Claim[](1);
            c[0] = Distributor.Claim({round: g.id, holder: g.holders[j], amount: g.amounts[j], proof: g.proofs[j]});
            _claim(stranger, c);
            Distributor.Round memory r = d.roundOf(g.id);
            if (r.paid + g.amounts[j] > r.total && !d.isClaimed(g.id, g.holders[j])) falseRoundsCapped++;
            return;
        }
    }

    /// The Guard cancels a random round, inside its delay or not; only inside may it succeed.
    function cancel(uint256 roundSeed) external {
        if (_rounds.length == 0) return;
        uint256 id = _rounds[roundSeed % _rounds.length].id;
        bool inside = block.timestamp < d.roundOf(id).postedAt + d.ROUND_DELAY();
        vm.prank(guard);
        try d.cancelRoot(id) {
            if (!inside) cancelledAfterDelay = true;
            cancels++;
        } catch {}
    }

    /// The Guard cancels a random range of rounds in one call: every round in it still inside its delay is
    /// cancelled, and every other is passed over untouched.
    function cancelRange(uint256 firstSeed, uint256 lenSeed) external {
        uint256 count = d.roundCount();
        if (count == 0) return;
        uint256 first = bound(firstSeed, 1, count);
        uint256 last = first + bound(lenSeed, 0, count + 2);
        uint256 top = last < count ? last : count;
        bool[] memory wasCancelled = new bool[](top + 1);
        bool[] memory inside = new bool[](top + 1);
        uint256 expected;
        for (uint256 r = first; r <= top; r++) {
            Distributor.Round memory dr = d.roundOf(r);
            wasCancelled[r] = dr.cancelled;
            inside[r] = block.timestamp < dr.postedAt + d.ROUND_DELAY();
            if (!dr.cancelled && inside[r]) expected++;
        }
        vm.prank(guard);
        uint256 done = d.cancelRoots(first, last);
        if (done != expected) rangeMiscount = true;
        for (uint256 r = first; r <= top; r++) {
            bool now_ = d.roundOf(r).cancelled;
            if (!wasCancelled[r] && !inside[r] && now_) cancelledAfterDelay = true;
            if (!wasCancelled[r] && inside[r] && !now_) rangeMiscount = true;
        }
        cancels += done;
    }

    /// The Guard, a stranger or the vault tries to post a root against an open pot; it must never succeed.
    function postAsOther(uint256 whoSeed, uint256 coinSeed) external {
        address[3] memory others = [guard, stranger, vault];
        address coin = coins[coinSeed % 2];
        uint256 next = d.roundCount() + 1;
        vm.prank(others[whoSeed % 3]);
        try d.postRoot(next, coin, assets[0], keccak256("false root"), 1) {
            postedByOther = true;
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function setBlocked(bool blocked) external {
        mock.setBlocked(holders[3], blocked);
    }

    function setRefusing(bool refusing) external {
        toggle.set(refusing);
    }

    /// A stranger submits a batch of random claims, duplicates among them. One batch in eight may name any
    /// round, a cancelled one or one inside its delay among them, which reverts the whole call; the others
    /// name rounds that may pay now.
    function claimBatch(uint256 seed, uint256 size) external {
        uint256[] memory pick = _pickable(seed % 8 == 0);
        if (pick.length == 0) return;
        size = bound(size, 1, 12);
        Distributor.Claim[] memory c = new Distributor.Claim[](size);
        for (uint256 i; i < size; i++) {
            GhostRound storage g = _rounds[pick[uint256(keccak256(abi.encode(seed, i))) % pick.length]];
            uint256 j = uint256(keccak256(abi.encode(seed, i, "holder"))) % g.holders.length;
            c[i] = Distributor.Claim({round: g.id, holder: g.holders[j], amount: g.amounts[j], proof: g.proofs[j]});
        }
        _claim(stranger, c);
    }

    /// A holder claims every round it is in that may pay now, together (one call in eight, every round it
    /// is in).
    function claimOwn(uint256 holderSeed) external {
        address holder = holders[holderSeed % holders.length];
        uint256[] memory pick = _pickable(holderSeed % 8 == 0);
        Distributor.Claim[] memory c = new Distributor.Claim[](pick.length);
        uint256 k;
        for (uint256 p; p < pick.length; p++) {
            GhostRound storage g = _rounds[pick[p]];
            for (uint256 j; j < g.holders.length; j++) {
                if (g.holders[j] == holder) {
                    c[k++] = Distributor.Claim({round: g.id, holder: holder, amount: g.amounts[j], proof: g.proofs[j]});
                }
            }
        }
        if (k == 0) return;
        assembly ("memory-safe") {
            mstore(c, k)
        }
        _claim(holder, c);
    }

    /// The ghost rounds a claim may name: every one when `any`, otherwise those that may pay now.
    function _pickable(bool any) internal view returns (uint256[] memory pick) {
        pick = new uint256[](_rounds.length);
        uint256 n;
        for (uint256 r; r < _rounds.length; r++) {
            Distributor.Round memory dr = d.roundOf(_rounds[r].id);
            if (any || (!dr.cancelled && block.timestamp >= dr.postedAt + d.ROUND_DELAY())) pick[n++] = r;
        }
        assembly ("memory-safe") {
            mstore(pick, n)
        }
    }

    function _claim(address caller, Distributor.Claim[] memory c) internal {
        uint256[] memory before = new uint256[](holders.length * 2);
        for (uint256 i; i < holders.length; i++) {
            before[2 * i] = mock.balanceOf(holders[i]);
            before[2 * i + 1] = holders[i].balance;
        }
        vm.recordLogs();
        vm.prank(caller);
        // Foundry records the logs of a call that reverted too, so only a call that went through is read.
        bool ok;
        try d.claim{gas: 3_000_000}(c) {
            ok = true;
        } catch {}
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) {
            _readClaims(logs);
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == address(d) && logs[i].topics[0] == Distributor.ClaimRefused.selector) {
                    refusals++;
                }
            }
        }
        for (uint256 i; i < holders.length; i++) {
            address h = holders[i];
            if (mock.balanceOf(h) - before[2 * i] != _takeSeen(h, assets[0])) balanceMismatch = true;
            if (h.balance - before[2 * i + 1] != _takeSeen(h, assets[1])) balanceMismatch = true;
        }
    }

    /// What this call's `Claimed` events said each holder was paid, cleared for the next call.
    mapping(address holder => mapping(Currency asset => uint256)) internal _seenInCall;

    function _takeSeen(address holder, Currency asset) internal returns (uint256 seen) {
        seen = _seenInCall[holder][asset];
        _seenInCall[holder][asset] = 0;
    }

    function _readClaims(Vm.Log[] memory logs) internal {
        bytes32 sig = Distributor.Claimed.selector;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(d) || logs[i].topics[0] != sig) continue;
            uint256 id = uint256(logs[i].topics[1]);
            address holder = address(uint160(uint256(logs[i].topics[2])));
            (Currency asset, uint256 amount) = abi.decode(logs[i].data, (Currency, uint256));
            Distributor.Round memory r = d.roundOf(id);
            if (block.timestamp < r.postedAt + d.ROUND_DELAY()) paidInsideDelay = true;
            if (r.cancelled) paidCancelled = true;
            if (paidTo[id][holder] != 0) paidTwice = true;
            if (amount != _leafAmount(id, holder)) paidPastLeaf = true;
            paidTo[id][holder] += amount;
            paidByRound[id] += amount;
            paidOut[r.coin][asset] += amount;
            received[holder][asset] += amount;
            _seenInCall[holder][asset] += amount;
            claimsPaid++;
        }
    }

    function _leafAmount(uint256 id, address holder) internal view returns (uint256) {
        for (uint256 r; r < _rounds.length; r++) {
            if (_rounds[r].id != id) continue;
            for (uint256 j; j < _rounds[r].holders.length; j++) {
                if (_rounds[r].holders[j] == holder) return _rounds[r].amounts[j];
            }
        }
        return type(uint256).max;
    }

    // ------------------------------------------------------------------ views for the invariants

    function roundCountGhost() external view returns (uint256) {
        return _rounds.length;
    }

    function roundAt(uint256 i) external view returns (uint256 id, uint256 leafSum) {
        return (_rounds[i].id, _rounds[i].leafSum);
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }
}

/// The properties ADR 0029 names for the Distributor, under random sequences of every call.
contract DistributorInvariantTest is Test {
    DistributorHandler internal handler;
    Distributor internal d;
    MockQuote internal mock;

    function setUp() public {
        address admin = makeAddr("admin");
        address roundKey = makeAddr("roundKey");
        StokerKeys keys = new StokerKeys(admin);
        vm.prank(admin);
        keys.proposeKey(StokerKeys.Role.RoundKey, roundKey);
        vm.prank(roundKey);
        keys.acceptKey(StokerKeys.Role.RoundKey);
        mock = new MockQuote();
        address vault = makeAddr("taxVault");
        d = new Distributor(keys, vault);
        handler = new DistributorHandler(d, vault, keys, mock, roundKey, admin);
        // Every run starts with a round in each asset already past its delay, so each run pays claims, and
        // one more still inside it.
        handler.deposit(0, 0, 1e20);
        handler.deposit(0, 1, 1e20);
        handler.postRound(0, 0, type(uint256).max, 1);
        handler.postRound(0, 1, type(uint256).max, 2);
        vm.warp(block.timestamp + 1 days);
        handler.postRound(0, 0, type(uint256).max, 3);
        targetContract(address(handler));
    }

    /// A coin's pot is what was deposited for it less what was paid from it, and the pots together are
    /// exactly what the Distributor holds.
    function invariant_eachPotIsItsDepositsLessItsPayments() public view {
        for (uint256 a; a < 2; a++) {
            Currency asset = handler.assets(a);
            uint256 sum;
            for (uint256 c; c < 2; c++) {
                address coin = handler.coins(c);
                assertEq(d.potOf(coin, asset), handler.deposited(coin, asset) - handler.paidOut(coin, asset), "pot");
                assertLe(d.reservedOf(coin, asset), d.potOf(coin, asset), "reserved within the pot");
                sum += d.potOf(coin, asset);
            }
            uint256 held = asset.isAddressZero() ? address(d).balance : mock.balanceOf(address(d));
            assertEq(held, sum, "the pots are what it holds");
        }
    }

    /// A coin's rounds never pay more than that coin's own pot received.
    function invariant_aRoundNeverPaysMoreThanItsCoinsPot() public view {
        for (uint256 a; a < 2; a++) {
            for (uint256 c; c < 2; c++) {
                address coin = handler.coins(c);
                Currency asset = handler.assets(a);
                assertLe(handler.paidOut(coin, asset), handler.deposited(coin, asset));
            }
        }
    }

    function invariant_aHolderIsNeverPaidTwiceForOneRound() public view {
        assertFalse(handler.paidTwice());
    }

    function invariant_nothingIsPaidInsideTheRoundDelay() public view {
        assertFalse(handler.paidInsideDelay());
    }

    function invariant_aCancelledRootPaysNothing() public view {
        assertFalse(handler.paidCancelled());
        for (uint256 i; i < handler.roundCountGhost(); i++) {
            (uint256 id,) = handler.roundAt(i);
            Distributor.Round memory r = d.roundOf(id);
            if (r.cancelled) {
                assertEq(r.paid, 0);
                assertEq(handler.paidByRound(id), 0);
            }
        }
    }

    /// The Distributor never pays more than the roots owe: each holder exactly their leaf, each round at
    /// most what its leaves sum to and what it was posted with, and the round's own count agrees.
    function invariant_neverMoreThanTheRootsOwe() public view {
        assertFalse(handler.paidPastLeaf());
        for (uint256 i; i < handler.roundCountGhost(); i++) {
            (uint256 id, uint256 leafSum) = handler.roundAt(i);
            Distributor.Round memory r = d.roundOf(id);
            assertLe(handler.paidByRound(id), leafSum);
            assertLe(r.paid, r.total);
            assertEq(r.paid, handler.paidByRound(id));
        }
    }

    /// Every payment a holder received is a `Claimed` event of theirs, and every such event a payment.
    function invariant_everyPaymentIsAClaim() public view {
        assertFalse(handler.balanceMismatch());
        for (uint256 i; i < handler.holderCount(); i++) {
            address h = handler.holders(i);
            assertEq(mock.balanceOf(h), handler.received(h, handler.assets(0)));
            assertEq(h.balance, handler.received(h, handler.assets(1)));
        }
    }

    /// Nobody but the round key posts, and the Guard cancels only inside the delay.
    function invariant_onlyTheRoundKeyPosts_theGuardOnlyCancelsInTime() public view {
        assertFalse(handler.postedByOther());
        assertFalse(handler.cancelledAfterDelay());
        assertFalse(handler.rangeMiscount(), "a range cancel missed a round in its delay or miscounted");
    }

    /// A false root never pays past the total it was posted with, whatever its tree says (from the review).
    function invariant_aFalseRoundStopsAtItsTotal() public view {
        for (uint256 i; i < handler.roundCountGhost(); i++) {
            (uint256 id,) = handler.roundAt(i);
            assertLe(handler.paidByRound(id), d.roundOf(id).total, "paid past the posted total");
        }
    }

    /// Every run must pay claims, or it proved nothing about payments. Refusals, cancels and false roots
    /// stopped at their total are rarer, so they are summed over the runs in the process's environment,
    /// which no run's revert of the chain touches, and required once 32 runs have ended (the review
    /// measured 1,631 claims paid, 453 refusals and 211 cancels over 128 runs).
    function afterInvariant() external {
        assertGt(handler.claimsPaid(), 0, "no claim was paid");
        uint256 runs = _add("STOKER_247_RUNS", 1);
        uint256 refused = _add("STOKER_247_REFUSALS", handler.refusals());
        uint256 cancelled = _add("STOKER_247_CANCELS", handler.cancels());
        uint256 capped = _add("STOKER_247_CAPPED", handler.falseRoundsCapped());
        if (runs >= 32) {
            assertGt(refused, 0, "no refusal reached");
            assertGt(cancelled, 0, "no cancel reached");
            assertGt(capped, 0, "no false root stopped at its total");
        }
    }

    function _add(string memory key, uint256 x) internal returns (uint256 sum) {
        sum = vm.envOr(key, uint256(0)) + x;
        vm.setEnv(key, vm.toString(sum));
    }
}
