// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StokerKeys} from "./StokerKeys.sol";
import {StokerHook} from "./StokerHook.sol";
import {IHoldersPart} from "./interfaces/IHoldersPart.sol";

/// @notice What the Distributor reads to find a Launch's terms: the Tax Vault's factory, and its hook.
interface IVaultFactory {
    function factory() external view returns (address);
}

interface IFactoryHook {
    function hook() external view returns (StokerHook);
}

/// @title Distributor
/// @notice Pays Holder Rewards on an EVM chain (ADR 0029, #247).
///
///         The Tax Vault hands each Reward Launch's holders' part to this contract, which keeps a pot per
///         coin and asset: the Quote Asset, or the coin itself when the Launch's Payout Asset is the coin.
///         The round key posts a Round Root for a coin's Reward Round, the Merkle root of what each holder
///         is owed, with the total it owes; the total is reserved from that coin's pot in that asset at
///         once, so a root can never owe more than its own coin's pot holds, nor anything of another's.
///
///         A root pays nothing during the Round Delay, 24 hours from its posting. During the delay the
///         Guard (the Admin's power, ADR 0030) can cancel it, and what it reserved is free again in the
///         coin's pot; the Guard can never post a root. After the delay anyone may submit a holder's claim,
///         and the payment always goes to the holder. Each holder's payment in a batch is made on its own,
///         so a holder the asset refuses (a Stock Token's blocklist, its issuer's pause) stays owed without
///         stopping the others. A holder's claims for several rounds in a row are paid as one payment.
///
///         A pot rises only by a deposit and falls only by a payment.
///
///         A coin whose Creator Earnings Destination is its holders has a second pot here (#248): the
///         Destination hands the Creator's Credits over through `depositEarnings`, and the round key posts
///         Round Roots of their own for them (`postEarningsRoot`), paid as Holder Dividends. A round names
///         the pot it pays from, so a coin's earnings and its Reward Tax are never paid from each other.
/// @dev No owner, no setter, no proxy, no pause. The round key and the Guard are read from `StokerKeys`
///      at the moment of each call, so a replacement or a revoke takes effect at once. The clocks read
///      `block.timestamp` alone.
contract Distributor is IHoldersPart {
    using SafeERC20 for IERC20;

    /// @notice How long a Round Root waits before it pays, and how long the Guard has to cancel it.
    uint256 public constant ROUND_DELAY = 24 hours;

    /// @notice The gas a native payment pushed to a holder carries, as the hook's native Payout Call
    ///         (#242): enough for a smart wallet's receive, too little to matter to the caller's batch. A
    ///         holder whose receive needs more is paid in full when it claims for itself.
    uint256 public constant NATIVE_CLAIM_GAS = 50_000;
    /// @dev What the call itself costs the caller beyond the gas it forwards: a cold account (2,600), the
    ///      value transfer (9,000) and a new account (25,000), with room to spare.
    uint256 internal constant NATIVE_CALL_OVERHEAD = 40_000;

    /// @dev The claim's re-entry guard, in transient storage: keccak256("stoker.distributor.claim") - 1.
    bytes32 internal constant CLAIM_LOCK_SLOT = 0xed860a12f198218f222ef8e96e0fa5a6a4c5df2b5c2f30240c2984fc3b1fd8de;

    /// @notice Where the round key and the Guard (the Admin) are read.
    StokerKeys public immutable keys;
    /// @notice The only address that may deposit: the Tax Vault (#245), fixed at deployment.
    address public immutable taxVault;

    /// @notice Where a pot's funds came from, and so which pot a round pays from (#248): the Reward Tax's
    ///         holders' part, or a Creator's earnings (Holder Dividends).
    enum Source {
        Tax,
        Earnings
    }

    /// @notice A posted Round Root.
    /// @param source Which of the coin's pots it reserved from and pays from.
    /// @param coin The coin whose holders the round pays, and whose pot it pays from.
    /// @param postedAt When it was posted; it pays from `postedAt + ROUND_DELAY`.
    /// @param cancelled Whether the Guard cancelled it; a cancelled root never pays.
    /// @param asset What it pays in: the coin's Quote Asset, or the coin.
    /// @param root The Merkle root of the round's leaves (see `leafOf`).
    /// @param total What the round owes in all, reserved from the coin's pot when it was posted.
    /// @param paid What it has paid so far, never more than `total`.
    struct Round {
        address coin;
        uint40 postedAt;
        bool cancelled;
        Source source;
        Currency asset;
        bytes32 root;
        uint128 total;
        uint128 paid;
    }

    /// @notice One holder's claim on one round.
    struct Claim {
        uint256 round;
        address holder;
        uint256 amount;
        bytes32[] proof;
    }

    /// @notice What this contract holds for each coin's holders, by asset: raised by a deposit, lowered by
    ///         a payment, and by nothing else.
    mapping(address coin => mapping(Currency asset => uint256)) public potOf;
    /// @dev What a new root for the coin may owe: its pot less what its live roots still owe. Kept rather
    ///      than what is reserved, so a payment, which lowers the pot and what is reserved alike, writes the
    ///      pot alone.
    mapping(address coin => mapping(Currency asset => uint256)) internal _available;
    /// @notice What this contract holds of each coin's Creator earnings for its holders, by asset (#248):
    ///         raised by its Destination's deposit, lowered by a payment of an earnings round, and by
    ///         nothing else. Apart from `potOf`, the Reward Tax's.
    mapping(address coin => mapping(Currency asset => uint256)) public earningsPotOf;
    /// @dev What a new earnings root for the coin may owe.
    mapping(address coin => mapping(Currency asset => uint256)) internal _earningsAvailable;
    /// @notice The number of roots ever posted; rounds are numbered from 1.
    uint256 public roundCount;
    mapping(uint256 round => Round) internal _rounds;
    /// @notice Whether a holder has been paid for a round.
    mapping(uint256 round => mapping(address holder => bool)) public isClaimed;

    event Deposited(address indexed coin, Currency indexed asset, uint256 amount);
    /// @notice A coin's Creator Earnings Destination handed `amount` of its earnings to the coin's holders.
    event EarningsDeposited(address indexed coin, Currency indexed asset, address indexed destination, uint256 amount);
    /// @notice The round is a round of source `earnings`: it pays Holder Dividends from the coin's earnings
    ///         pot. Emitted beside its `RootPosted`.
    event EarningsRootPosted(uint256 indexed round, address indexed coin);
    event RootPosted(
        uint256 indexed round, address indexed coin, Currency asset, bytes32 root, uint256 total, uint256 payableAt
    );
    /// @notice The Guard cancelled a root; `released` is what it had reserved, free again in the pot.
    event RootCancelled(uint256 indexed round, uint256 released);
    event Claimed(uint256 indexed round, address indexed holder, Currency asset, uint256 amount);
    /// @notice The asset refused to pay the holder (a blocklist, a pause, a reverting receive); the claim
    ///         stays owed to that holder.
    event ClaimRefused(uint256 indexed round, address indexed holder, Currency asset, uint256 amount);

    error ZeroAddress();
    error NotTaxVault();
    /// @notice An earnings deposit by anyone but the coin's own Creator Earnings Destination, as its Launch's
    ///         terms name it, or for a pool that is not ours.
    error NotTheCoinsDestination();
    error NotRoundKey();
    error GuardCannotPost();
    error NotGuard();
    error ValueMismatch(uint256 expected, uint256 sent);
    /// @notice The asset delivered other than exactly the amount deposited.
    error DepositShort();
    error WrongRound(uint256 round, uint256 next);
    error InvalidRoot();
    error RootExceedsPot(uint256 total, uint256 available);
    error UnknownRound(uint256 round);
    error RoundCancelled(uint256 round);
    /// @notice The round's Round Delay has not passed; it pays from `payableAt`.
    error RoundDelay(uint256 round, uint256 payableAt);
    error DelayOver(uint256 round);
    error InvalidRange(uint256 firstRound, uint256 lastRound);
    error InvalidProof(uint256 round, address holder);
    /// @notice The claim would take the round past the total it was posted with.
    error RoundTotalExceeded(uint256 round);
    error ClaimReentered();
    /// @notice The call was given too little gas to carry a native payment's full allowance.
    error ClaimGasTooLow();

    /// @param keys_ Where the round key and the Admin are read.
    /// @param taxVault_ The Tax Vault, the only depositor: deployed after this contract, at an address the
    ///        deployment computes beforehand, since the Tax Vault in turn fixes this contract's (#251).
    constructor(StokerKeys keys_, address taxVault_) {
        if (address(keys_) == address(0) || taxVault_ == address(0)) revert ZeroAddress();
        keys = keys_;
        taxVault = taxVault_;
    }

    // ------------------------------------------------------------------ the holders' part

    /// @notice Takes a coin's holders' part from the Tax Vault into that coin's pot in `asset`
    ///         (`IHoldersPart`, #245): the native asset as the call's value, exactly `amount`; an ERC-20
    ///         pulled from the Tax Vault, which approved exactly `amount`, with no value.
    /// @dev A coin's Creator earnings arrive through `depositEarnings`, into a pot of their own (#248).
    function deposit(address coin, Currency asset, uint256 amount) external payable {
        if (msg.sender != taxVault) revert NotTaxVault();
        _pull(asset, amount);
        _addToPot(Source.Tax, coin, asset, amount);
        // The only call before it is to the asset the Tax Vault named, and our own Tax Vault is the caller.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposited(coin, asset, amount);
    }

    /// @notice Takes `amount` of a coin's Creator earnings, in its Quote Asset, into that coin's earnings pot
    ///         (#248), from the coin's own Creator Earnings Destination alone: the address its Launch's terms
    ///         name, read from the hook, never a list a key keeps. The native asset is the call's value,
    ///         exactly `amount`; an ERC-20 is pulled from the caller's allowance. It raises the pot and what
    ///         an earnings root may reserve together.
    /// @param key The coin's pool: it names the coin and the Quote Asset.
    function depositEarnings(PoolKey calldata key, uint256 amount) external payable {
        StokerHook.Terms memory t = IFactoryHook(IVaultFactory(taxVault).factory()).hook().termsOf(key.toId());
        // The pool id hashes every field of the key, so only a pool our factory opened has registered terms.
        if (!t.registered || msg.sender != t.creatorDestination) revert NotTheCoinsDestination();
        (Currency asset, Currency coin) =
            t.quoteIsCurrency0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _pull(asset, amount);
        _addToPot(Source.Earnings, Currency.unwrap(coin), asset, amount);
        // The calls before it are our own contracts' views and the coin's listed Quote Asset.
        // forge-lint: disable-next-line(reentrancy-events)
        emit EarningsDeposited(Currency.unwrap(coin), asset, msg.sender, amount);
    }

    /// @dev Takes exactly `amount` of `asset` from the caller: the native asset as the call's value, an ERC-20
    ///      from the caller's allowance with no value.
    function _pull(Currency asset, uint256 amount) internal {
        if (asset.isAddressZero()) {
            if (msg.value != amount) revert ValueMismatch(amount, msg.value);
            return;
        }
        if (msg.value != 0) revert ValueMismatch(0, msg.value);
        IERC20 token = IERC20(Currency.unwrap(asset));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        // Exactly the amount, on purpose: a pot must never count more than arrived (a transfer fee).
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (token.balanceOf(address(this)) - before != amount) revert DepositShort();
    }

    // ------------------------------------------------------------------ Round Roots

    /// @notice Posts the Round Root of `coin`'s next Reward Round, paying `total` in `asset` from that
    ///         coin's pot, by the round key alone. It reserves `total` from what the pot holds unreserved
    ///         and refuses a root that owes more. It pays from `ROUND_DELAY` after now.
    /// @param round The round's number, which must be the next one: the leaves carry it.
    function postRoot(uint256 round, address coin, Currency asset, bytes32 root, uint256 total) external {
        _post(Source.Tax, round, coin, asset, root, total);
    }

    /// @notice Posts the Round Root of a round of source `earnings` (#248): `coin`'s next round of Holder
    ///         Dividends, paying `total` in `asset` from that coin's earnings pot and from nothing else. In
    ///         every other way it is `postRoot`: the round key alone, the next round number, the Round Delay,
    ///         the Guard's cancel, and the same claims.
    function postEarningsRoot(uint256 round, address coin, Currency asset, bytes32 root, uint256 total) external {
        _post(Source.Earnings, round, coin, asset, root, total);
        // forge-lint: disable-next-line(reentrancy-events)
        emit EarningsRootPosted(round, coin);
    }

    function _post(Source source, uint256 round, address coin, Currency asset, bytes32 root, uint256 total) internal {
        address roundKey = keys.holderOf(StokerKeys.Role.RoundKey);
        // A revoked key reads as nobody, which no caller is.
        if (msg.sender != roundKey) revert NotRoundKey();
        // The Guard only ever cancels: an Admin that named itself the round key still cannot post.
        if (msg.sender == keys.admin()) revert GuardCannotPost();
        uint256 next = roundCount + 1;
        if (round != next) revert WrongRound(round, next);
        if (coin == address(0) || root == bytes32(0) || total == 0) revert InvalidRoot();
        uint256 available = _availableIn(source)[coin][asset];
        if (total > available) revert RootExceedsPot(total, available);

        roundCount = round;
        _availableIn(source)[coin][asset] = available - total;
        _rounds[round] = Round({
            coin: coin,
            // Timestamps fit a uint40 until the year 36812.
            // forge-lint: disable-next-line(unsafe-typecast)
            postedAt: uint40(block.timestamp),
            cancelled: false,
            source: source,
            asset: asset,
            root: root,
            total: SafeCast.toUint128(total),
            paid: 0
        });
        // The calls before it are our own keys' views.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RootPosted(round, coin, asset, root, total, block.timestamp + ROUND_DELAY);
    }

    /// @notice Cancels a Round Root inside its Round Delay, by the Guard (the Admin of the moment) alone.
    ///         It never pays, and what it reserved is free again in the coin's pot.
    function cancelRoot(uint256 round) external {
        if (msg.sender != keys.admin()) revert NotGuard();
        Round storage r = _roundOf(round);
        if (r.cancelled) revert RoundCancelled(round);
        // The Round Delay is a day; a sequencer's few seconds move its end by as much and no more.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= uint256(r.postedAt) + ROUND_DELAY) revert DelayOver(round);
        _cancel(round, r);
    }

    /// @notice Cancels every round from `firstRound` to `lastRound` still inside its Round Delay, by the
    ///         Guard alone, and passes over any already cancelled or past its delay, so one stale round
    ///         never blocks the rest. A stolen round key may post a false root for every Reward Launch's
    ///         pot; with `StokerKeys.revokeKey` this stops them all in one or a few signatures, whatever
    ///         the number of Launches. The caller bounds the gas by the range; a range past the last round
    ///         stops at it. It only cancels: it never posts and never pays.
    /// @return cancelled How many rounds it cancelled.
    function cancelRoots(uint256 firstRound, uint256 lastRound) external returns (uint256 cancelled) {
        if (msg.sender != keys.admin()) revert NotGuard();
        if (firstRound == 0 || firstRound > lastRound) revert InvalidRange(firstRound, lastRound);
        uint256 last = lastRound < roundCount ? lastRound : roundCount;
        for (uint256 round = firstRound; round <= last; round++) {
            Round storage r = _rounds[round];
            // forge-lint: disable-next-line(block-timestamp)
            if (r.cancelled || block.timestamp >= uint256(r.postedAt) + ROUND_DELAY) continue;
            _cancel(round, r);
            cancelled++;
        }
    }

    /// @dev Cancels a round inside its delay: nothing pays inside the delay, so the whole total was still
    ///      reserved, and it is free again in the coin's pot.
    function _cancel(uint256 round, Round storage r) internal {
        r.cancelled = true;
        uint256 released = r.total - r.paid;
        _availableIn(r.source)[r.coin][r.asset] += released;
        // The call before it is our own keys' view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RootCancelled(round, released);
    }

    // ------------------------------------------------------------------ claims

    /// @notice Pays each claim's amount to its holder, and to nobody else. Anyone may call it, for any
    ///         holders; the Keeper calls it after each Round Delay, and a holder may claim their own.
    ///
    ///         Claims in a row for the same holder in the same asset, several rounds of theirs, are paid as
    ///         one payment of their sum. Each holder's payment is made on its own: one the asset refuses
    ///         leaves that holder's claims owed, and the others are paid. A claim already paid is passed
    ///         over, so a holder's own claim landing first cannot stop the Keeper's batch. A claim on an
    ///         unknown or cancelled round, on a round inside its delay, with a proof that does not verify,
    ///         or past its round's total reverts the call.
    /// @dev The native asset is paid by a call carrying `NATIVE_CLAIM_GAS` that copies no return data, or
    ///      all the gas there is when the holder is the caller. A caller with too little gas for that
    ///      allowance reverts the whole call rather than starve a holder into a refusal.
    function claim(Claim[] calldata claims) external {
        if (_claimLocked()) revert ClaimReentered();
        _setClaimLock(true);
        bool[] memory took = new bool[](claims.length);
        uint256 i = 0;
        while (i < claims.length) {
            address holder = claims[i].holder;
            Currency asset = _payableRound(claims[i].round).asset;
            uint256 end = i;
            uint256 sum = 0;
            for (; end < claims.length && claims[end].holder == holder; end++) {
                Claim calldata c = claims[end];
                Round storage r = _payableRound(c.round);
                if (Currency.unwrap(r.asset) != Currency.unwrap(asset)) break;
                if (isClaimed[c.round][holder]) continue;
                if (!MerkleProof.verifyCalldata(c.proof, r.root, leafOf(c.round, r.coin, holder, c.amount))) {
                    // A claim that does not verify is the caller's error and reverts the whole call.
                    // forge-lint: disable-next-line(require-revert-in-loop)
                    revert InvalidProof(c.round, holder);
                }
                uint256 paid = uint256(r.paid) + c.amount;
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (paid > r.total) revert RoundTotalExceeded(c.round);
                isClaimed[c.round][holder] = true;
                // At most `total`, a uint128, by the line above.
                // forge-lint: disable-next-line(unsafe-typecast)
                r.paid = uint128(paid);
                // What it reserved is paid: the pot falls, and what a new root may owe stays as it was.
                _potIn(r.source)[r.coin][asset] -= c.amount;
                sum += c.amount;
                took[end] = true;
            }
            if (sum > 0) {
                bool ok = _pay(asset, holder, sum);
                for (uint256 k = i; k < end; k++) {
                    if (!took[k]) continue;
                    if (ok) {
                        // forge-lint: disable-next-line(reentrancy-events)
                        emit Claimed(claims[k].round, holder, asset, claims[k].amount);
                    } else {
                        _restore(claims[k].round, holder, asset, claims[k].amount);
                    }
                }
            }
            i = end;
        }
        _setClaimLock(false);
    }

    /// @dev Raises one of a coin's pots and what a new root of that source may owe from it, together, so every
    ///      unit deposited can be reserved by a root.
    function _addToPot(Source source, address coin, Currency asset, uint256 amount) internal {
        _potIn(source)[coin][asset] += amount;
        _availableIn(source)[coin][asset] += amount;
    }

    /// @dev A source's pots: the Reward Tax's or the Creator earnings', which nothing ever moves between.
    function _potIn(Source source)
        internal
        view
        returns (mapping(address coin => mapping(Currency asset => uint256)) storage)
    {
        return source == Source.Tax ? potOf : earningsPotOf;
    }

    function _availableIn(Source source)
        internal
        view
        returns (mapping(address coin => mapping(Currency asset => uint256)) storage)
    {
        return source == Source.Tax ? _available : _earningsAvailable;
    }

    /// @dev Puts a refused claim back as it was: owed to the same holder, by the same round, from the same
    ///      pot. Every figure is added back, never overwritten.
    function _restore(uint256 round, address holder, Currency asset, uint256 amount) internal {
        Round storage r = _rounds[round];
        isClaimed[round][holder] = false;
        // It was added by this call's own claim, so it fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.paid -= uint128(amount);
        _potIn(r.source)[r.coin][asset] += amount;
        // forge-lint: disable-next-line(reentrancy-events)
        emit ClaimRefused(round, holder, asset, amount);
    }

    /// @dev Pays `amount` of `asset` to `holder` and says whether it arrived, without reverting.
    function _pay(Currency asset, address holder, uint256 amount) internal returns (bool ok) {
        if (asset.isAddressZero()) {
            if (holder == msg.sender) {
                // A holder claiming their own may spend all the gas they brought on receiving it.
                assembly ("memory-safe") {
                    ok := call(gas(), holder, amount, 0, 0, 0, 0)
                }
            } else {
                // Never let a caller starve a holder into a refusal: without the full allowance in hand the
                // whole call reverts and every claim stays as it was.
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (gasleft() < NATIVE_CLAIM_GAS * 64 / 63 + NATIVE_CALL_OVERHEAD) revert ClaimGasTooLow();
                // No return data is copied, so a holder's revert reason costs the caller nothing.
                assembly ("memory-safe") {
                    ok := call(NATIVE_CLAIM_GAS, holder, amount, 0, 0, 0, 0)
                }
            }
            return ok;
        }
        // An ERC-20's `transfer`, as SafeERC20 checks it, but returning false where SafeERC20 reverts, and
        // reading one word of return data at most. The call runs the asset's code, never the holder's.
        address token = Currency.unwrap(asset);
        bytes memory data = abi.encodeCall(IERC20.transfer, (holder, amount));
        assembly ("memory-safe") {
            ok := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            if ok {
                switch returndatasize()
                case 0 { ok := gt(extcodesize(token), 0) }
                default { ok := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }

    function _roundOf(uint256 round) internal view returns (Round storage r) {
        // Reached from `claim`'s loop, where a claim on no round is the caller's error and reverts the call.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (round == 0 || round > roundCount) revert UnknownRound(round);
        r = _rounds[round];
    }

    /// @dev A round that may pay now: known, not cancelled, and past its Round Delay.
    function _payableRound(uint256 round) internal view returns (Round storage r) {
        r = _roundOf(round);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (r.cancelled) revert RoundCancelled(round);
        uint256 payableAt = uint256(r.postedAt) + ROUND_DELAY;
        // forge-lint: disable-next-line(block-timestamp, require-revert-in-loop)
        if (block.timestamp < payableAt) revert RoundDelay(round, payableAt);
    }

    function _claimLocked() internal view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(CLAIM_LOCK_SLOT)
        }
    }

    function _setClaimLock(bool locked) internal {
        assembly ("memory-safe") {
            tstore(CLAIM_LOCK_SLOT, locked)
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice The leaf of `holder`'s claim of `amount` on `round` of `coin`, as the Reward Engine builds
    ///         the tree: the chain, this contract, the coin, the round, the holder and the amount,
    ///         ABI-encoded and hashed twice (OpenZeppelin's standard leaf), so a proof cannot be replayed on
    ///         another round, coin, contract or chain.
    function leafOf(uint256 round, address coin, address holder, uint256 amount) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), coin, round, holder, amount))));
    }

    /// @notice A posted round.
    function roundOf(uint256 round) external view returns (Round memory) {
        return _rounds[round];
    }

    /// @notice What a new root for `coin` in `asset` may owe at most: its pot less what its live roots owe.
    function availableOf(address coin, Currency asset) external view returns (uint256) {
        return _available[coin][asset];
    }

    /// @notice What a new earnings root for `coin` in `asset` may owe at most (#248).
    function earningsAvailableOf(address coin, Currency asset) external view returns (uint256) {
        return _earningsAvailable[coin][asset];
    }

    /// @notice What `coin`'s live earnings roots still owe from its earnings pot in `asset`.
    function earningsReservedOf(address coin, Currency asset) external view returns (uint256) {
        return earningsPotOf[coin][asset] - _earningsAvailable[coin][asset];
    }

    /// @notice What `coin`'s live roots still owe from its pot in `asset`: never more than the pot.
    function reservedOf(address coin, Currency asset) external view returns (uint256) {
        return potOf[coin][asset] - _available[coin][asset];
    }
}
