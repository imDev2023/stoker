// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IQuoteListings} from "./interfaces/IQuoteListings.sol";
import {StokerKeys} from "./StokerKeys.sol";

/// @title QuoteRegistry
/// @notice One EVM chain's Quote Registry (ADR 0028): the factory launches a coin only against an asset
///         with a Listing, and each new Launch copies its Listing's start price, Graduation multiple and
///         Referrer Fee cap into its own terms, so no write here ever touches a coin already launched.
///
///         Only the Admin writes it, from a hardware wallet, and the contract bounds what any write can do:
///
///         - A new Listing is one write, in force at once.
///         - A routine write moves a Listing's start price by 25% at most, and a Listing takes at most one
///           write a day (a rolling 24 hours, of every kind but a delisting).
///         - A deliberate change of any figure (the Opening Value through the start price, the Graduation
///           multiple, the Referrer Fee cap) is scheduled: readable here at once, in force 48 hours after it
///           is posted with nobody calling anything, and withdrawable by the Admin until then.
///         - Delisting stops new Launches on an asset at once; it harms nobody, so it is not held to the day,
///           and a delisted asset comes back only by a scheduled change.
/// @dev Reads `block.timestamp` only, never `block.number`, which is an estimate of the L1 block on
///      Robinhood Chain and Arbitrum. A sequencer can shift a timestamp by seconds, which moves a day or
///      48 hours by as much and no more: every `block-timestamp` lint finding below is one of these two
///      clocks. Timestamps are stored as `uint40`, which lasts until the year 36812. No proxy, no pause, no
///      owner but the Admin of `keys`.
contract QuoteRegistry is IQuoteListings {
    /// @notice A Listing takes at most one write in this long.
    uint256 public constant WRITE_INTERVAL = 1 days;
    /// @notice A scheduled change is in force this long after it is posted.
    uint256 public constant CHANGE_DELAY = 48 hours;
    /// @notice The most a routine write may raise a start price: 1.0001^2231 = 1.24995, the last tick at or
    ///         under +25%.
    int24 public constant MAX_TICKS_UP = 2_231;
    /// @notice The most a routine write may lower a start price: 1.0001^-2876 = 0.75008, the last tick at or
    ///         above -25%.
    int24 public constant MAX_TICKS_DOWN = 2_876;
    uint16 public constant MIN_GRADUATION_MULTIPLE = 2;
    uint16 public constant MAX_GRADUATION_MULTIPLE = 1_000;
    /// @notice The highest Referrer Fee cap a Listing may carry: 5.00% of the Quote Asset's side.
    uint16 public constant MAX_REFERRER_FEE_CAP_BPS = 500;
    /// @notice Room kept above a start price for its Graduation Target: 1.0001^70000 is about 1,097, over the
    ///         largest multiple, so every target is a price the pool can reach.
    int24 public constant GRADUATION_HEADROOM = 70_000;

    /// @notice Where the Admin is read.
    StokerKeys public immutable keys;
    /// @notice The tick spacing of every pool the factory opens; a start price is always a multiple of it.
    int24 public immutable tickSpacing;

    /// @notice A change of a Listing's figures, posted and waiting; `effectiveAt` is zero when none waits.
    struct ScheduledChange {
        int24 startTick;
        uint16 graduationMultiple;
        uint16 referrerFeeCapBps;
        uint40 effectiveAt;
    }

    struct Entry {
        Listing listing;
        bool everListed;
        uint40 lastWriteAt;
        ScheduledChange change;
    }

    mapping(address quote => Entry) internal _entries;

    event Listed(address indexed quote, int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps);
    event StartPriceWritten(address indexed quote, int24 previousStartTick, int24 startTick);
    event ChangeScheduled(
        address indexed quote, int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps, uint256 effectiveAt
    );
    event ChangeWithdrawn(address indexed quote);
    event Delisted(address indexed quote);

    error NotAdmin();
    error InvalidSettings();
    error AlreadyListed(address quote);
    error NeverListed(address quote);
    error NotListed(address quote);
    error WriteTooSoon(uint256 nextWriteAt);
    error MoveTooLarge(int24 fromTick, int24 toTick);
    error ChangePending(uint256 effectiveAt);
    error NoChangePending(address quote);
    error InvalidStartTick(int24 startTick);
    error InvalidGraduationMultiple(uint16 graduationMultiple);
    error InvalidReferrerFeeCap(uint16 referrerFeeCapBps);

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    constructor(StokerKeys keys_, int24 tickSpacing_) {
        if (address(keys_) == address(0)) revert InvalidSettings();
        if (tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING) {
            revert InvalidSettings();
        }
        keys = keys_;
        tickSpacing = tickSpacing_;
    }

    // ------------------------------------------------------------------ writes, the Admin's alone

    /// @notice Lists an asset never listed before, in force at once; the zero address is the chain's native
    ///         asset. An asset once delisted comes back only by `scheduleChange`.
    function list(address quote, int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps)
        external
        onlyAdmin
    {
        Entry storage e = _entries[quote];
        if (e.everListed) revert AlreadyListed(quote);
        _checkFigures(startTick, graduationMultiple, referrerFeeCapBps);
        e.listing = Listing({
            listed: true,
            startTick: startTick,
            graduationMultiple: graduationMultiple,
            referrerFeeCapBps: referrerFeeCapBps
        });
        e.everListed = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        e.lastWriteAt = uint40(block.timestamp);
        emit Listed(quote, startTick, graduationMultiple, referrerFeeCapBps);
    }

    /// @notice The routine write: a new start price for a listed asset, at most 25% from the one in force,
    ///         at most once a day, and never while a scheduled change waits.
    function writeStartPrice(address quote, int24 startTick) external onlyAdmin {
        Entry storage e = _settled(quote);
        if (!e.listing.listed) revert NotListed(quote);
        if (e.change.effectiveAt != 0) revert ChangePending(e.change.effectiveAt);
        _checkInterval(e);
        _checkStartTick(startTick);
        int24 previous = e.listing.startTick;
        if (startTick > previous + MAX_TICKS_UP || startTick < previous - MAX_TICKS_DOWN) {
            revert MoveTooLarge(previous, startTick);
        }
        e.listing.startTick = startTick;
        // forge-lint: disable-next-line(unsafe-typecast)
        e.lastWriteAt = uint40(block.timestamp);
        emit StartPriceWritten(quote, previous, startTick);
    }

    /// @notice A deliberate change of every figure of a Listing, by any amount within the bounds: posted
    ///         now, readable at once through `scheduledChangeOf`, in force `CHANGE_DELAY` later. On a delisted
    ///         asset it lists it again when it comes into force.
    function scheduleChange(address quote, int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps)
        external
        onlyAdmin
    {
        Entry storage e = _settled(quote);
        if (!e.everListed) revert NeverListed(quote);
        if (e.change.effectiveAt != 0) revert ChangePending(e.change.effectiveAt);
        _checkInterval(e);
        _checkFigures(startTick, graduationMultiple, referrerFeeCapBps);
        uint256 effectiveAt = block.timestamp + CHANGE_DELAY;
        e.change = ScheduledChange({
            startTick: startTick,
            graduationMultiple: graduationMultiple,
            referrerFeeCapBps: referrerFeeCapBps,
            // forge-lint: disable-next-line(unsafe-typecast)
            effectiveAt: uint40(effectiveAt)
        });
        // forge-lint: disable-next-line(unsafe-typecast)
        e.lastWriteAt = uint40(block.timestamp);
        emit ChangeScheduled(quote, startTick, graduationMultiple, referrerFeeCapBps, effectiveAt);
    }

    /// @notice Withdraws a scheduled change before it comes into force.
    function withdrawChange(address quote) external onlyAdmin {
        Entry storage e = _settled(quote);
        if (e.change.effectiveAt == 0) revert NoChangePending(quote);
        delete e.change;
        emit ChangeWithdrawn(quote);
    }

    /// @notice Stops new Launches on an asset at once, and withdraws any change waiting for it. Coins already
    ///         launched on it trade on, untouched.
    function delist(address quote) external onlyAdmin {
        Entry storage e = _settled(quote);
        if (!e.listing.listed) revert NotListed(quote);
        e.listing.listed = false;
        if (e.change.effectiveAt != 0) {
            delete e.change;
            emit ChangeWithdrawn(quote);
        }
        emit Delisted(quote);
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IQuoteListings
    /// @dev A scheduled change is in force from its `effectiveAt`, whether or not anything was written since.
    function listingOf(address quote) external view returns (Listing memory listing) {
        Entry storage e = _entries[quote];
        ScheduledChange memory c = e.change;
        // forge-lint: disable-next-line(block-timestamp)
        if (c.effectiveAt != 0 && block.timestamp >= c.effectiveAt) {
            return Listing({
                listed: true,
                startTick: c.startTick,
                graduationMultiple: c.graduationMultiple,
                referrerFeeCapBps: c.referrerFeeCapBps
            });
        }
        return e.listing;
    }

    /// @notice The change waiting for a Listing; `effectiveAt` is zero when none waits (and once it is in
    ///         force, when `listingOf` returns its figures).
    function scheduledChangeOf(address quote) external view returns (ScheduledChange memory c) {
        c = _entries[quote].change;
        // forge-lint: disable-next-line(block-timestamp)
        if (c.effectiveAt != 0 && block.timestamp >= c.effectiveAt) delete c;
    }

    /// @notice When a Listing was last written: listed, written, scheduled, or a scheduled change in force.
    function lastWriteAt(address quote) external view returns (uint256 at) {
        Entry storage e = _entries[quote];
        at = e.lastWriteAt;
        uint256 effectiveAt = e.change.effectiveAt;
        // forge-lint: disable-next-line(block-timestamp)
        if (effectiveAt != 0 && block.timestamp >= effectiveAt && effectiveAt > at) at = effectiveAt;
    }

    // ------------------------------------------------------------------ internals

    /// @dev Folds a scheduled change that has come into force into the Listing before any write reads it,
    ///      as the moment it came into force: the Listing's write of that day.
    function _settled(address quote) internal returns (Entry storage e) {
        e = _entries[quote];
        ScheduledChange memory c = e.change;
        // forge-lint: disable-next-line(block-timestamp)
        if (c.effectiveAt != 0 && block.timestamp >= c.effectiveAt) {
            e.listing = Listing({
                listed: true,
                startTick: c.startTick,
                graduationMultiple: c.graduationMultiple,
                referrerFeeCapBps: c.referrerFeeCapBps
            });
            if (c.effectiveAt > e.lastWriteAt) e.lastWriteAt = c.effectiveAt;
            delete e.change;
        }
    }

    function _checkInterval(Entry storage e) internal view {
        uint256 next = uint256(e.lastWriteAt) + WRITE_INTERVAL;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < next) revert WriteTooSoon(next);
    }

    function _checkFigures(int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps) internal view {
        _checkStartTick(startTick);
        if (graduationMultiple < MIN_GRADUATION_MULTIPLE || graduationMultiple > MAX_GRADUATION_MULTIPLE) {
            revert InvalidGraduationMultiple(graduationMultiple);
        }
        if (referrerFeeCapBps > MAX_REFERRER_FEE_CAP_BPS) revert InvalidReferrerFeeCap(referrerFeeCapBps);
    }

    /// @dev A start price on the tick spacing, above the lowest usable tick, with room above it for the
    ///      Graduation Target below the highest. Either currency order then opens and seeds inside the range.
    function _checkStartTick(int24 startTick) internal view {
        if (
            startTick % tickSpacing != 0 || startTick <= TickMath.minUsableTick(tickSpacing)
                || startTick + GRADUATION_HEADROOM >= TickMath.maxUsableTick(tickSpacing)
        ) revert InvalidStartTick(startTick);
    }

    function _onlyAdmin() internal view {
        if (msg.sender != keys.admin()) revert NotAdmin();
    }
}
