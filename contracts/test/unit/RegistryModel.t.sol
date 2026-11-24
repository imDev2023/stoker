// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "../utils/LocalBase.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {IQuoteListings} from "../../src/interfaces/IQuoteListings.sol";

/// The Quote Registry against the rule as ADR 0028 words it, kept here as a second, plain copy (the review
/// of 2026-11-24). Random sequences of the Admin's writes and of waits, many of them on the rule's own
/// edges (a second short of a day, of 48 hours), are sent to the registry and to the copy. After every
/// step the registry must have taken or refused the write exactly as the rule says, and must answer the
/// Listing in force, the change waiting and the last write as the copy does. The single tests each walk one
/// path; this walks the paths between them: a change coming into force unseen, then a delisting, then a
/// second change, a withdrawal, a routine write on the first second it is allowed.
contract RegistryModelTest is LocalBase {
    address internal ASSET = address(0xA55E7);
    uint256 internal constant STEPS = 48;

    // The rule's figures, written out again and not read from the contract.
    uint256 internal constant DAY = 24 hours;
    uint256 internal constant DELAY = 48 hours;
    int24 internal constant UP = 2_231;
    int24 internal constant DOWN = 2_876;

    struct Model {
        bool everListed;
        bool listed;
        int24 tick;
        uint16 multiple;
        uint16 cap;
        uint256 lastWrite;
        bool pending;
        int24 pTick;
        uint16 pMultiple;
        uint16 pCap;
        uint256 pAt;
    }

    Model internal m;
    uint256 internal taken;
    uint256 internal refused;
    uint256 internal cameIntoForce;

    /// A change that has waited its 48 hours is the Listing, from that moment, with nobody calling.
    function _settle() internal {
        if (m.pending && vm.getBlockTimestamp() >= m.pAt) {
            (m.listed, m.tick, m.multiple, m.cap) = (true, m.pTick, m.pMultiple, m.pCap);
            m.lastWrite = m.pAt;
            m.pending = false;
            cameIntoForce++;
        }
    }

    /// A start price the pools can open at, with room above it for the largest Graduation Target.
    function _valid(int24 tick) internal pure returns (bool) {
        return tick > -887_200 && tick + 70_000 < 887_200;
    }

    function _wait(uint256 r) internal {
        uint256[8] memory waits =
            [uint256(1), 1 hours, DAY - 1, DAY, DELAY - DAY, DELAY - 1, DELAY, 3 days + (r >> 8) % 1 days];
        skip(waits[r % waits.length]);
    }

    function _expect(bool ok, bool should, string memory what) internal {
        assertEq(ok, should, what);
        if (ok) taken++;
        else refused++;
    }

    function _step(uint256 r) internal {
        uint256 op = r % 8;
        r >>= 8;
        uint256 nowAt = vm.getBlockTimestamp();
        // forge-lint: disable-start(unsafe-typecast)
        int24 tick = m.everListed ? m.tick : START_TICK;
        uint16 multiple = uint16(2 + r % 999);
        uint16 cap = uint16((r >> 16) % 501);
        // forge-lint: disable-end(unsafe-typecast)
        bool ok;

        if (op <= 2) {
            _wait(r);
        } else if (op == 3) {
            vm.prank(platform);
            try registry.list(ASSET, tick, multiple, cap) {
                ok = true;
            } catch {}
            _expect(ok, !m.everListed, "a new Listing is taken once and only once");
            if (ok) {
                (m.everListed, m.listed, m.tick, m.multiple, m.cap) = (true, true, tick, multiple, cap);
                m.lastWrite = nowAt;
            }
        } else if (op == 4) {
            // A routine write: up to 20 spacings either way, so both sides of the 25% band are met.
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 move = (int24(int256(r % 41)) - 20) * TICK_SPACING;
            vm.prank(platform);
            try registry.writeStartPrice(ASSET, tick + move) {
                ok = true;
            } catch {}
            bool should = m.listed && !m.pending && nowAt >= m.lastWrite + DAY && move <= UP && move >= -DOWN
                && _valid(tick + move);
            _expect(ok, should, "a routine write: listed, nothing waiting, a day since the last, within 25%");
            if (ok) {
                m.tick = tick + move;
                m.lastWrite = nowAt;
            }
        } else if (op == 5) {
            // A deliberate change: any figures inside the bounds, by any amount.
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 to = tick + (int24(int256((r >> 32) % 401)) - 200) * TICK_SPACING;
            vm.prank(platform);
            try registry.scheduleChange(ASSET, to, multiple, cap) {
                ok = true;
            } catch {}
            _expect(
                ok,
                m.everListed && !m.pending && nowAt >= m.lastWrite + DAY && _valid(to),
                "a change is scheduled: once listed, nothing waiting, a day since the last write"
            );
            if (ok) {
                (m.pending, m.pTick, m.pMultiple, m.pCap, m.pAt) = (true, to, multiple, cap, nowAt + DELAY);
                m.lastWrite = nowAt;
            }
        } else if (op == 6) {
            vm.prank(platform);
            try registry.withdrawChange(ASSET) {
                ok = true;
            } catch {}
            _expect(ok, m.pending, "a change is withdrawn only while it waits");
            if (ok) m.pending = false;
        } else {
            vm.prank(platform);
            try registry.delist(ASSET) {
                ok = true;
            } catch {}
            _expect(ok, m.listed, "a delisting needs a Listing");
            if (ok) (m.listed, m.pending) = (false, false);
        }
    }

    function _compare() internal view {
        IQuoteListings.Listing memory l = registry.listingOf(ASSET);
        assertEq(l.listed, m.listed, "listed");
        assertEq(l.startTick, m.tick, "the start price in force");
        assertEq(l.graduationMultiple, m.multiple, "the Graduation multiple in force");
        assertEq(l.referrerFeeCapBps, m.cap, "the Referrer Fee cap in force");
        QuoteRegistry.ScheduledChange memory c = registry.scheduledChangeOf(ASSET);
        assertEq(c.effectiveAt, m.pending ? m.pAt : 0, "the change waiting");
        if (m.pending) {
            assertEq(c.startTick, m.pTick);
            assertEq(c.graduationMultiple, m.pMultiple);
            assertEq(c.referrerFeeCapBps, m.pCap);
        }
        assertEq(registry.lastWriteAt(ASSET), m.lastWrite, "the last write");
    }

    function testFuzz_registry_everySequenceOfWritesFollowsTheRule(uint256 seed) public {
        for (uint256 i; i < STEPS; i++) {
            _settle();
            _step(uint256(keccak256(abi.encode(seed, i))));
            _settle();
            _compare();
        }
    }

    /// The sequences do reach the edges: writes taken, writes refused, and changes coming into force.
    function test_registry_theSequencesReachTheRulesEdges() public {
        for (uint256 seed; seed < 24; seed++) {
            // A fresh asset for each sequence; the clock simply runs on.
            // forge-lint: disable-next-line(unsafe-typecast)
            ASSET = address(uint160(0xA55E7 + seed));
            delete m;
            for (uint256 i; i < STEPS; i++) {
                _settle();
                _step(uint256(keccak256(abi.encode(seed, i))));
                _settle();
                _compare();
            }
        }
        assertGt(taken, 100, "writes taken");
        assertGt(refused, 100, "writes refused");
        assertGt(cameIntoForce, 10, "changes that came into force");
    }
}
