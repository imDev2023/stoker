// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";

/// The launch type and its terms (#245): the factory takes Solana's steps and refuses anything off them,
/// which the spike did not; the terms are written once and read from the hook.
contract TaxTermsTest is TaxLocalBase {
    StokerHook.LaunchType internal constant STANDARD = StokerHook.LaunchType.Standard;
    StokerHook.LaunchType internal constant REWARD = StokerHook.LaunchType.Reward;
    StokerHook.LaunchType internal constant STOKE = StokerHook.LaunchType.Liquidity;
    StokerHook.PayoutAsset internal constant IN_QUOTE = StokerHook.PayoutAsset.QuoteAsset;
    StokerHook.PayoutAsset internal constant IN_COIN = StokerHook.PayoutAsset.Coin;

    function _p(StokerHook.LaunchType t, uint16 tax, uint16 burnShare, uint16 liqShare, StokerHook.PayoutAsset pa)
        internal
        returns (StokerFactory.LaunchParams memory)
    {
        return _typedParams(address(quote), true, 0, t, tax, burnShare, liqShare, pa);
    }

    function _refused(StokerFactory.LaunchParams memory p, bytes memory err) internal {
        vm.prank(creator);
        vm.expectRevert(err);
        factory.launch(p);
    }

    function _shares(uint16 b, uint16 l) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StokerFactory.InvalidShares.selector, b, l);
    }

    function _rate(uint16 t) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StokerFactory.InvalidTaxRate.selector, t);
    }

    function test_terms_everyStepPairAtMostHalf_launches_andIsWrittenOnce() public {
        uint16[4] memory steps = [uint16(0), 1_000, 2_500, 5_000];
        for (uint256 i; i < 4; i++) {
            for (uint256 j; j < 4; j++) {
                (uint16 b, uint16 l) = (steps[i], steps[j]);
                StokerFactory.LaunchParams memory p = _p(REWARD, 200, b, l, j % 2 == 0 ? IN_QUOTE : IN_COIN);
                if (uint256(b) + l > 5_000) {
                    _refused(p, _shares(b, l));
                    continue;
                }
                (, PoolKey memory key) = _launchWith(p);
                StokerHook.Terms memory t = hook.termsOf(key.toId());
                assertEq(uint8(t.launchType), uint8(REWARD));
                assertEq(t.taxBps, 200);
                assertEq(t.burnShareBps, b);
                assertEq(t.liquidityShareBps, l);
                assertEq(uint8(t.payoutAsset), uint8(p.payoutAsset));
            }
        }
    }

    function test_terms_sharesOffTheSteps_revert() public {
        uint16[5] memory off = [uint16(1), 500, 2_000, 3_000, 10_000];
        for (uint256 i; i < off.length; i++) {
            _refused(_p(REWARD, 300, off[i], 0, IN_QUOTE), _shares(off[i], 0));
            _refused(_p(REWARD, 300, 0, off[i], IN_QUOTE), _shares(0, off[i]));
        }
    }

    function test_terms_moreThanHalfTogether_reverts() public {
        _refused(_p(REWARD, 300, 5_000, 1_000, IN_QUOTE), _shares(5_000, 1_000));
        _refused(_p(REWARD, 300, 2_500, 5_000, IN_QUOTE), _shares(2_500, 5_000));
        _refused(_p(REWARD, 300, 5_000, 5_000, IN_QUOTE), _shares(5_000, 5_000));
    }

    function test_terms_taxOffSolanasRates_reverts() public {
        uint16[6] memory off = [uint16(0), 50, 99, 150, 501, 600];
        for (uint256 i; i < off.length; i++) {
            _refused(_p(REWARD, off[i], 0, 0, IN_QUOTE), _rate(off[i]));
            _refused(_p(STOKE, off[i], 0, 0, IN_QUOTE), _rate(off[i]));
        }
        for (uint16 t = 100; t <= 500; t += 100) {
            (, PoolKey memory key) = _launchWith(_p(REWARD, t, 0, 0, IN_QUOTE));
            assertEq(hook.termsOf(key.toId()).taxBps, t);
        }
    }

    function test_terms_standardLaunchTakesNoTaxTerms() public {
        _refused(_p(STANDARD, 100, 0, 0, IN_QUOTE), _rate(100));
        _refused(_p(STANDARD, 0, 1_000, 0, IN_QUOTE), _shares(1_000, 0));
        _refused(_p(STANDARD, 0, 0, 1_000, IN_QUOTE), _shares(0, 1_000));
        _refused(_p(STANDARD, 0, 0, 0, IN_COIN), abi.encodeWithSelector(StokerFactory.InvalidPayoutAsset.selector));
        (, PoolKey memory key) = _launchWith(_p(STANDARD, 0, 0, 0, IN_QUOTE));
        StokerHook.Terms memory t = hook.termsOf(key.toId());
        assertEq(t.taxBps, 0);
        assertEq(t.liquidityShareBps, 0);
    }

    /// A Stoke Launch: its whole tax becomes Support Liquidity, with no holders' part and no burn share.
    function test_terms_stokeLaunch_wholeTaxToLiquidity_noHoldersPart() public {
        _refused(_p(STOKE, 300, 1_000, 0, IN_QUOTE), _shares(1_000, 0));
        _refused(_p(STOKE, 300, 0, 5_000, IN_QUOTE), _shares(0, 5_000));
        _refused(_p(STOKE, 300, 0, 0, IN_COIN), abi.encodeWithSelector(StokerFactory.InvalidPayoutAsset.selector));
        StokerFactory.LaunchParams memory p = _p(STOKE, 300, 0, 0, IN_QUOTE);
        (, PoolKey memory key) = _launchWith(p);
        StokerHook.Terms memory t = hook.termsOf(key.toId());
        assertEq(uint8(t.launchType), uint8(STOKE));
        assertEq(t.burnShareBps, 0, "no burn share");
        assertEq(t.liquidityShareBps, 10_000, "the whole tax to liquidity");
    }

    function test_terms_eventSaysTheSame() public {
        StokerFactory.LaunchParams memory p = _p(REWARD, 400, 1_000, 2_500, IN_COIN);
        vm.recordLogs();
        (, PoolKey memory key) = _launchWith(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != StokerHook.TaxTermsRegistered.selector) {
                continue;
            }
            found++;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            (uint8 t, uint16 tax, uint16 b, uint16 l, uint8 pa) =
                abi.decode(logs[i].data, (uint8, uint16, uint16, uint16, uint8));
            assertEq(t, uint8(REWARD));
            assertEq(tax, 400);
            assertEq(b, 1_000);
            assertEq(l, 2_500);
            assertEq(pa, uint8(IN_COIN));
        }
        assertEq(found, 1, "one TaxTermsRegistered");
    }

    // ------------------------------------------------ the Tax Vault's deployment

    function test_vault_factoryRefusesAVaultMadeForAnother() public {
        TaxVault other = new TaxVault(pm, stranger, holdersPart, PIECE_BPS, PIECE_INTERVAL, SUPPORT_WIDTH_SPACINGS);
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(pm, listings, platform, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, TICK_SPACING, bytes32(0), other);
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(
            pm, listings, platform, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, TICK_SPACING, bytes32(0), TaxVault(payable(0))
        );
    }

    function test_vault_refusesUnboundedSettings() public {
        IHoldersPart d = holdersPart;
        IPoolManager m = pm;
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, d, 0, 60, 10);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, d, 101, 60, 10);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, d, 50, 0, 10);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, d, 50, 60, 0);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, d, 50, 60, 1_001);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, stranger, IHoldersPart(address(0)), 50, 60, 10);
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        new TaxVault(m, address(0), d, 50, 60, 10);
        // The vault has no owner and no setter: its settings are what it was deployed with.
        assertEq(address(taxVault.distributor()), address(holdersPart));
        assertEq(taxVault.factory(), address(factory));
        assertEq(taxVault.pieceBps(), PIECE_BPS);
    }
}
