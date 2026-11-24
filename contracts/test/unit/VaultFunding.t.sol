// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {UnlockedCaller, DoubleCaller} from "./TaxVaultHostile.t.sol";

/// An asset that keeps a hundredth of every transfer while told to: what the Listing rule bars (ADR 0028),
/// here so the vault's own check is seen to hold whatever is listed.
contract SkimmingStock is ERC20 {
    bool public skimming;

    constructor() ERC20("Skimming Stock", "SKIM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setSkimming(bool skimming_) external {
        skimming = skimming_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (skimming && from != address(0) && to != address(0)) {
            super._update(from, address(0xdead), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}

/// Stands where the Distributor is and, from inside `deposit`, calls the vault's two funding calls, then
/// takes the deposit as the interface says so the outer call completes.
contract FundingReenterer {
    TaxVault internal vault;
    PoolKey internal key;
    uint256 public attempts;
    uint256 public metTheGuard;

    function arm(TaxVault vault_, PoolKey calldata key_) external {
        vault = vault_;
        key = key_;
    }

    function deposit(address, Currency asset, uint256 amount) external payable {
        IERC20 token = IERC20(Currency.unwrap(asset));
        token.approve(address(vault), type(uint256).max);
        bytes4[2] memory calls = [TaxVault.fundBurn.selector, TaxVault.fundSupport.selector];
        for (uint256 i; i < 2; i++) {
            attempts++;
            (bool ok, bytes memory err) = address(vault).call(abi.encodeWithSelector(calls[i], key, 1 ether));
            if (!ok && err.length == 4 && bytes4(err) == TaxVault.Reentered.selector) metTheGuard++;
        }
        token.transferFrom(msg.sender, address(this), amount);
    }
}

/// The Tax Vault's funding entry points (#248): anyone may give a coin's Quote Asset to its burn or to its
/// Support Liquidity, and the vault's existing capped calls spend it, by the same buy and the same addition,
/// in books apart from the coin's tax.
contract VaultFundingTest is DestinationsLocalBase {
    address internal funder = makeAddr("funder");

    function setUp() public override {
        super.setUp();
        mockQuote.mint(funder, 1_000_000 ether);
        vm.deal(funder, 1_000 ether);
    }

    function _fundBurn(PoolKey memory key, address who, uint256 amount) internal {
        vm.startPrank(who);
        if (_native(key)) {
            taxVault.fundBurn{value: amount}(key, amount);
        } else {
            quote.approve(address(taxVault), amount);
            taxVault.fundBurn(key, amount);
        }
        vm.stopPrank();
    }

    function _fundSupport(PoolKey memory key, address who, uint256 amount) internal {
        vm.startPrank(who);
        if (_native(key)) {
            taxVault.fundSupport{value: amount}(key, amount);
        } else {
            quote.approve(address(taxVault), amount);
            taxVault.fundSupport(key, amount);
        }
        vm.stopPrank();
    }

    /// How many events of the Tax Vault's carry `sig`.
    function _count(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256) {
        return _countFrom(logs, address(taxVault), sig);
    }

    function _countFrom(Vm.Log[] memory logs, address emitter, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig) n++;
        }
    }

    // ---------------------------------------------------------------- funding

    /// Anyone funds any coin of ours: exactly the amount leaves the funder and becomes the vault's claims,
    /// and the books count it apart from the coin's tax.
    function test_fund_anyoneFundsACoin_exactlyTheAmountBecomesClaims() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            uint256 unit = _unit(key);
            uint256 claims = _vaultClaims(key);
            uint256 balance = _quoteBalanceOf(key, funder);

            // The allowance first: an expected event is the next one emitted.
            bool isNative = _native(key);
            vm.startPrank(funder);
            if (!isNative) quote.approve(address(taxVault), 8 * unit);
            vm.expectEmit(true, true, false, true, address(taxVault));
            emit TaxVault.BurnFunded(key.toId(), funder, 3 * unit);
            taxVault.fundBurn{value: isNative ? 3 * unit : 0}(key, 3 * unit);
            vm.expectEmit(true, true, false, true, address(taxVault));
            emit TaxVault.SupportFunded(key.toId(), funder, 5 * unit);
            taxVault.fundSupport{value: isNative ? 5 * unit : 0}(key, 5 * unit);
            vm.stopPrank();

            assertEq(_vaultClaims(key) - claims, 8 * unit, "the vault's claims grew by exactly what was funded");
            assertEq(balance - _quoteBalanceOf(key, funder), 8 * unit, "exactly the amount left the funder");
            (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(key);
            assertEq(burnFunded, 3 * unit);
            assertEq(supportFunded, 5 * unit);
            // A standard coin has no tax: nothing waits on the tax's own books.
            (uint256 burnPart, uint256 supportPart, uint256 holdersPart,) = taxVault.waiting(key);
            assertEq(burnPart + supportPart + holdersPart, 0, "funding is not tax");
            assertEq(address(taxVault).balance, 0, "the vault holds no native asset");
            if (!_native(key)) {
                assertEq(quote.balanceOf(address(taxVault)), 0, "the vault holds no Quote Asset");
                assertEq(quote.allowance(funder, address(taxVault)), 0, "the allowance was used whole");
            }
        }
    }

    /// A funded burn on a coin with no tax at all: the supply falls by exactly what each capped piece bought.
    function test_fund_aFundedBurn_theSupplyFalls_inCappedPieces() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            IERC20 coin = _coinOfKey(key);
            uint256 cap = taxVault.pieceCap(key);
            uint256 funded = cap * 5 / 2;
            _fundBurn(key, funder, funded);

            uint256 spentInAll;
            for (uint256 piece; piece < 3; piece++) {
                uint256 supply = coin.totalSupply();
                uint256 capNow = taxVault.pieceCap(key);
                vm.recordLogs();
                vm.prank(stranger);
                (uint256 spent, uint256 burned) = taxVault.burn(key);
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertLe(spent, capNow, "a piece is capped");
                assertGt(burned, 0);
                assertEq(supply - coin.totalSupply(), burned, "the supply fell by exactly what the piece bought");
                assertEq(coin.balanceOf(address(taxVault)), 0, "the vault keeps no coin");
                assertEq(_count(logs, TaxVault.FundedBurned.selector), 1, "a funded burn says so");
                assertEq(_count(logs, TaxVault.RewardBurned.selector), 0, "and is no Reward Burn");
                spentInAll += spent;
                // The vault's own buy raised the price; the next waits until the Reference Price has followed.
                _letThePriceStand();
            }
            assertEq(spentInAll, funded, "all of it was spent, and no more");
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            assertEq(b.burnFundedSpent, funded);
            assertEq(b.burnSpent, 0, "the tax's own book did not move");
            assertEq(_vaultClaims(key), 0, "nothing is left in the vault");
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.burn(key);
        }
    }

    /// Funded Support Liquidity: Quote Asset alone below the price, no coin bought, the price unmoved.
    function test_fund_fundedSupport_quoteAssetAlone_noCoinBought_thePriceUnmoved() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            _trade(key, trader, true, true, 30 * _unit(key));
            IERC20 coin = _coinOfKey(key);
            uint256 funded = taxVault.pieceCap(key) / 2;
            _fundSupport(key, funder, funded);

            uint160 price = _sqrtPrice(key);
            uint256 supply = coin.totalSupply();
            uint256 traderCoins = coin.balanceOf(trader);
            uint128 poolLiquidity = _poolLiquidity(key);
            vm.recordLogs();
            vm.prank(stranger);
            (uint256 added, uint128 liquidity) = taxVault.addSupport(key);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Support memory s;
            s.liquidity = liquidity;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == address(taxVault) && logs[i].topics[0] == TaxVault.SupportAdded.selector) {
                    (s.lower, s.upper,,) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
                }
                if (logs[i].emitter == address(taxVault) && logs[i].topics[0] == TaxVault.FundedSupportAdded.selector) {
                    assertEq(abi.decode(logs[i].data, (uint256)), added, "all of this piece was funded");
                }
            }
            assertEq(_count(logs, TaxVault.FundedSupportAdded.selector), 1);
            assertEq(_countFrom(logs, address(pm), IPoolManager.Swap.selector), 0, "no swap: no coin bought");

            assertEq(_sqrtPrice(key), price, "the price did not move");
            assertEq(_poolLiquidity(key), poolLiquidity, "it lies beside the price, not at it");
            assertEq(coin.totalSupply(), supply, "no coin was bought or burned");
            assertEq(coin.balanceOf(trader), traderCoins);
            assertEq(coin.balanceOf(address(taxVault)), 0);
            assertLe(added, funded);
            assertGe(added, funded - 2, "all of it but the rounding");
            assertEq(_supportLiquidity(key, s), liquidity, "the vault holds the position");
            (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, s);
            assertEq(coinsHeld, 0, "Quote Asset alone");
            assertApproxEqAbs(quoteHeld, added, 2);
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            assertEq(b.supportFundedSpent, added);
            assertEq(b.supportSpent, 0, "the tax's own book did not move");
        }
    }

    // ---------------------------------------------------------------- beside a coin's tax

    /// On a Reward Launch with a burn share, one `burn` spends the tax's part first and what was funded
    /// after it, in one capped piece and one buy, and reports each part's own figures.
    function test_fund_onePieceOneBuy_theTaxFirst_eachPartReported() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchRewardTo(kind, address(0), 5_000, 0);
            _trade(key, trader, true, true, 2 * _unit(key));
            _letThePriceStand();
            (uint256 taxPart,,,) = taxVault.waiting(key);
            uint256 cap = taxVault.pieceCap(key);
            assertGt(taxPart, 0);
            assertLt(taxPart, cap, "the tax's part alone is under a piece");
            _fundBurn(key, funder, 10 * cap);

            IERC20 coin = _coinOfKey(key);
            uint256 supply = coin.totalSupply();
            vm.recordLogs();
            vm.prank(stranger);
            (uint256 spent, uint256 burned) = taxVault.burn(key);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(spent, cap, "one piece, the cap, whatever the sources");
            (uint256 taxSpent, uint256 taxCoins, uint256 fundedSpent, uint256 fundedCoins, uint256 swaps) =
                _burnParts(logs);
            assertEq(swaps, 1, "one buy");
            assertEq(taxSpent, taxPart, "the tax's part first, all of it");
            assertEq(fundedSpent, cap - taxPart, "then what was funded, up to the cap");
            assertEq(taxCoins + fundedCoins, burned, "the two parts are the whole buy");
            assertEq(supply - coin.totalSupply(), burned);
            // Each part has the coins its share of the spend bought.
            assertApproxEqAbs(fundedCoins, burned * fundedSpent / spent, 1);

            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            assertEq(b.burnSpent, taxPart);
            assertEq(b.burnFundedSpent, cap - taxPart);

            // The interval is one for both sources.
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
            taxVault.burn(key);
        }
    }

    function _burnParts(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 taxSpent, uint256 taxCoins, uint256 fundedSpent, uint256 fundedCoins, uint256 swaps)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == IPoolManager.Swap.selector) swaps++;
            if (logs[i].emitter != address(taxVault)) continue;
            if (logs[i].topics[0] == TaxVault.RewardBurned.selector) {
                (taxSpent, taxCoins) = abi.decode(logs[i].data, (uint256, uint256));
            }
            if (logs[i].topics[0] == TaxVault.FundedBurned.selector) {
                (fundedSpent, fundedCoins) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    /// Funding and tax never count as each other: with a Reward Launch's burn, liquidity and holders' parts
    /// all waiting and both pots funded, draining the burn and the Support Liquidity to the end spends
    /// exactly each part of the tax and exactly what was funded, and the holders' part is handed over whole.
    function test_fund_fundingAndTaxNeverCountAsEachOther() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchRewardTo(kind, address(0), 2_500, 2_500);
            // What earlier turns of this loop left in the vault in the same asset (a piece's rounding).
            uint256 claimsBefore = _vaultClaims(key);
            _churn(key, 3);
            _letThePriceStand();
            uint256 booked = _taxBooked(key);
            (uint256 burnPart, uint256 supportPart, uint256 holdersPart,) = taxVault.waiting(key);
            assertEq(burnPart, booked * 2_500 / 10_000);
            uint256 fundedBurn = 3 * _unit(key) / 10;
            uint256 fundedSupport = 2 * _unit(key) / 10;
            _fundBurn(key, funder, fundedBurn);
            _fundSupport(key, funder, fundedSupport);
            assertEq(
                _vaultClaims(key) - claimsBefore,
                booked + fundedBurn + fundedSupport,
                "the claims are the tax and the funding"
            );
            // Funding moved nothing on the tax's books.
            (uint256 b1, uint256 s1, uint256 h1,) = taxVault.waiting(key);
            assertEq(b1, burnPart);
            assertEq(s1, supportPart);
            assertEq(h1, holdersPart);

            for (uint256 i; i < 400; i++) {
                (uint256 bw, uint256 sw) = taxVault.fundedWaiting(key);
                (uint256 tb, uint256 ts,,) = taxVault.waiting(key);
                if (bw + tb == 0 && sw + ts <= 2) break;
                if (bw + tb > 0) {
                    vm.prank(stranger);
                    taxVault.burn(key);
                }
                if (sw + ts > 2) {
                    vm.prank(stranger);
                    try taxVault.addSupport(key) {} catch {}
                }
                _letThePriceStand();
            }
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            assertEq(b.burnSpent, burnPart, "the burn spent exactly its share of the tax");
            assertEq(b.burnFundedSpent, fundedBurn, "and exactly what was funded for it");
            assertEq(b.burnFunded, fundedBurn);
            assertLe(b.supportSpent, supportPart);
            assertLe(b.supportFundedSpent, fundedSupport);
            assertGe(b.supportSpent + b.supportFundedSpent + 2, supportPart + fundedSupport, "but the rounding");
            assertEq(b.holdersSpent, 0, "the holders' part was touched by neither");

            // The vault's own buys paid no tax, so the tax booked is what the trades paid.
            assertEq(_taxBooked(key), booked);
            uint256 potBefore = distributor.potOf(address(_coinOfKey(key)), _quoteOfKey(key));
            vm.prank(stranger);
            (, uint256 passed) = taxVault.passHoldersPart(key);
            assertEq(passed, holdersPart, "the holders' part, whole");
            assertEq(distributor.potOf(address(_coinOfKey(key)), _quoteOfKey(key)) - potBefore, holdersPart);
            assertLe(_vaultClaims(key) - claimsBefore, 2, "nothing is left but the Support Liquidity's rounding");
        }
    }

    /// One coin's funding is never spent on another.
    function test_fund_oneCoinsFundingNeverPaysForAnother() public {
        PoolKey memory a = _launchTo(QUOTE_FIRST, address(0));
        PoolKey memory b = _launchTo(COIN_FIRST, address(0));
        _fundBurn(a, funder, 1 ether);
        _fundSupport(a, funder, 1 ether);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.burn(b);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.addSupport(b);
        (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(b);
        assertEq(burnFunded + supportFunded, 0);
        // And the burn's funding is not the Support Liquidity's.
        PoolKey memory c = _launchTo(QUOTE_FIRST, address(0));
        _fundBurn(c, funder, 1 ether);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.addSupport(c);
        PoolKey memory d = _launchTo(QUOTE_FIRST, address(0));
        _fundSupport(d, funder, 1 ether);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.burn(d);
    }

    // ---------------------------------------------------------------- refusals

    function test_fund_refusals_byName() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(0));
        PoolKey memory nativeKey = _launchTo(NATIVE_PAIR, address(0));
        vm.startPrank(funder);
        quote.approve(address(taxVault), type(uint256).max);

        // Nothing to fund.
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.fundBurn(key, 0);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.fundSupport(nativeKey, 0);

        // Value with an ERC-20, and value that is not the native amount.
        vm.expectRevert(abi.encodeWithSelector(TaxVault.ValueMismatch.selector, 0, 1));
        taxVault.fundBurn{value: 1}(key, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxVault.ValueMismatch.selector, 0, 1));
        taxVault.fundSupport{value: 1}(key, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxVault.ValueMismatch.selector, 1 ether, 1 ether - 1));
        taxVault.fundBurn{value: 1 ether - 1}(nativeKey, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxVault.ValueMismatch.selector, 1 ether, 0));
        taxVault.fundSupport(nativeKey, 1 ether);

        // A pool that is not ours: another spacing, another hook.
        PoolKey memory other = _onAnotherSpacing(key);
        vm.expectRevert(TaxVault.NotAStokerPool.selector);
        taxVault.fundBurn(other, 1 ether);
        other = _onNoHook(key);
        vm.expectRevert(TaxVault.NotAStokerPool.selector);
        taxVault.fundSupport(other, 1 ether);
        vm.stopPrank();

        // No allowance: the asset refuses, and nothing is counted.
        vm.prank(stranger);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        taxVault.fundBurn(key, 1 ether);
        (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(key);
        assertEq(burnFunded + supportFunded, 0);
        assertEq(_vaultClaims(key), 0);
        assertEq(address(taxVault).balance, 0);
    }

    /// An asset that delivers less than the amount is refused, so the books never run ahead of the claims.
    function test_fund_anAssetThatDeliversShortIsRefused() public {
        SkimmingStock skim = new SkimmingStock();
        vm.prank(platform);
        registry.list(address(skim), START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        StokerFactory.LaunchParams memory p;
        p.name = "Skim Coin";
        p.symbol = "SKC";
        p.quote = address(skim);
        vm.prank(creator);
        (address coin,) = factory.launch(p);
        bool q0 = address(skim) < coin;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(q0 ? address(skim) : coin),
            currency1: Currency.wrap(q0 ? coin : address(skim)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        skim.mint(funder, 100 ether);
        vm.startPrank(funder);
        skim.approve(address(taxVault), type(uint256).max);
        taxVault.fundBurn(key, 1 ether);
        skim.setSkimming(true);
        vm.expectRevert(TaxVault.FundingShort.selector);
        taxVault.fundBurn(key, 1 ether);
        vm.expectRevert(TaxVault.FundingShort.selector);
        taxVault.fundSupport(key, 1 ether);
        vm.stopPrank();
        (uint256 burnFunded,) = taxVault.fundedWaiting(key);
        assertEq(burnFunded, 1 ether, "only what arrived whole is counted");
        assertEq(pm.balanceOf(address(taxVault), Currency.wrap(address(skim)).toId()), 1 ether);
    }

    /// Funding opens the vault's own unlock, so it cannot run inside another: not inside a trader's swap.
    function test_fund_neverInsideAnUnlock() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(0));
        UnlockedCaller c = new UnlockedCaller(pm);
        mockQuote.mint(address(c), 10 ether);
        vm.prank(address(c));
        quote.approve(address(taxVault), type(uint256).max);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        c.callInsideUnlock(address(taxVault), abi.encodeCall(TaxVault.fundBurn, (key, 1 ether)));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        c.callInsideUnlock(address(taxVault), abi.encodeCall(TaxVault.fundSupport, (key, 1 ether)));
    }

    /// The funding calls are behind the vault's own guard: a Distributor that calls them from inside its
    /// `deposit`, in the middle of `passHoldersPart`, meets it both times.
    function test_fund_reenteringFromTheDistributorMeetsTheGuard() public {
        PoolKey memory key = _launchRewardTo(QUOTE_FIRST, address(0), 0, 0);
        _churn(key, 1);
        vm.etch(address(distributor), address(new FundingReenterer()).code);
        FundingReenterer d = FundingReenterer(address(distributor));
        d.arm(taxVault, key);
        mockQuote.mint(address(d), 10 ether);
        vm.prank(stranger);
        taxVault.passHoldersPart(key);
        assertEq(d.attempts(), 2, "it tried both funding calls");
        assertEq(d.metTheGuard(), 2, "each met Reentered");
        (uint256 burnFunded, uint256 supportFunded) = taxVault.fundedWaiting(key);
        assertEq(burnFunded + supportFunded, 0);
    }

    // ---------------------------------------------------------------- dust

    /// Dust wastes one interval at most and never shrinks a piece: a wallet that funds a coin's burn with
    /// dust and spends it the moment real funding arrives delays the first real piece by one interval, and
    /// every piece after it is the cap. While real funding waits, a call spends real funding.
    function test_fund_dustDelaysAPieceByOneIntervalAtMost_andNeverShrinksIt() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            address pest = makeAddr("pest");
            mockQuote.mint(pest, 1 ether);
            vm.deal(pest, 1 ether);
            uint256 dust = _unit(key) / 1e6;

            // The pest funds dust and burns it, using this interval's buy.
            _fundBurn(key, pest, dust);
            vm.prank(pest);
            (uint256 spent,) = taxVault.burn(key);
            assertEq(spent, dust);
            uint256 dustAt = vm.getBlockTimestamp();

            // Real funding arrives a second later and waits for the interval's end, not longer.
            skip(1);
            uint256 cap = taxVault.pieceCap(key);
            _fundBurn(key, funder, 3 * cap);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, dustAt + PIECE_INTERVAL));
            taxVault.burn(key);
            vm.warp(dustAt + PIECE_INTERVAL);

            // The pest funds dust again and calls first: the piece it triggers is the real funding's, whole.
            _fundBurn(key, pest, dust);
            uint256 capNow = taxVault.pieceCap(key);
            vm.prank(pest);
            (spent,) = taxVault.burn(key);
            assertEq(spent, capNow, "a full piece, whoever called");
        }
    }

    /// Two funded pieces cannot be stacked in one transaction.
    function test_fund_twoPiecesInOneTransactionAreRefused() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(0));
        uint256 cap = taxVault.pieceCap(key);
        _fundBurn(key, funder, 4 * cap);
        _fundSupport(key, funder, 4 * cap);
        DoubleCaller twice = new DoubleCaller();
        vm.expectPartialRevert(TaxVault.TooSoon.selector);
        twice.twice(taxVault, key, TaxVault.burn.selector);
        vm.expectPartialRevert(TaxVault.TooSoon.selector);
        twice.twice(taxVault, key, TaxVault.addSupport.selector);
    }

    /// The vault's own buy with funded Quote Asset pays the Platform Fee like any buy, and no tax, on a taxed
    /// coin too: the tax booked does not move.
    function test_fund_aFundedBuyPaysTheFee_andNoTax() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchRewardTo(kind, address(0), 0, 0);
            _fundBurn(key, funder, taxVault.pieceCap(key));
            uint256 booked = _taxBooked(key);
            uint256 claims = _hookClaimsOf(key);
            vm.prank(stranger);
            (uint256 spent,) = taxVault.burn(key);
            assertEq(_taxBooked(key), booked, "no tax on the vault's own buy");
            assertEq(_hookClaimsOf(key) - claims, _rateOfGross(spent, PLATFORM_FEE_BPS), "the Platform Fee");
        }
    }

    function test_fund_anIdOfAnotherPoolReadsNothing() public view {
        TaxVault.Books memory b = taxVault.booksOf(PoolId.wrap(keccak256("no pool")));
        assertEq(b.burnFunded + b.supportFunded, 0);
    }
}
