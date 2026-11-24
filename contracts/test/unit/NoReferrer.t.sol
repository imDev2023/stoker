// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";

/// A swap that names no referrer costs the trader exactly what it did before the Referrer Fee existed
/// (#243): the same trades, in the same order, against figures recorded from `main` at 242af52, before
/// the hook changed. Each figure is what the trader paid or received, in raw units, and what the hook took.
contract NoReferrerTest is LocalBase {
    struct Figures {
        uint256 quoteMoved; // Quote Asset the trader paid (buys) or received (sells)
        uint256 coinsMoved; // coins the trader received (buys) or paid (sells)
        uint256 fee; // what the hook's claims grew by
    }

    function setUp() public override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
    }

    /// The four trades in a coin paired with an ERC-20, after a First Buy of 1, as `main` priced them.
    function _erc20Trades(bool quoteIsCurrency0) internal returns (Figures[4] memory f) {
        (, PoolKey memory key) = _launch(quoteIsCurrency0, 1 ether);
        IERC20 coin = _coin(key);
        f[0] = _see(key, true, true, 10 ether);
        f[1] = _see(key, true, false, 1e9 ether);
        f[2] = _see(key, false, true, coin.balanceOf(trader) / 2);
        f[3] = _see(key, false, false, 2 ether);
    }

    function _see(PoolKey memory key, bool buy, bool exactIn, uint256 amount) internal returns (Figures memory f) {
        IERC20 coin = _coin(key);
        f.quoteMoved = quote.balanceOf(trader);
        f.coinsMoved = coin.balanceOf(trader);
        f.fee = _hookClaims();
        _swap(key, trader, buy, exactIn, amount);
        f.quoteMoved = _diff(f.quoteMoved, quote.balanceOf(trader));
        f.coinsMoved = _diff(f.coinsMoved, coin.balanceOf(trader));
        f.fee = _hookClaims() - f.fee;
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// The four trades in a coin paired with the native asset, after a First Buy of 0.1, as `main` priced them.
    function _nativeTrades() internal returns (Figures[4] memory f) {
        (address coin, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        f[0] = _seeNative(key, coin, true, true, 1 ether);
        f[1] = _seeNative(key, coin, true, false, 1e9 ether);
        f[2] = _seeNative(key, coin, false, true, IERC20(coin).balanceOf(trader) / 2);
        f[3] = _seeNative(key, coin, false, false, 0.05 ether);
    }

    function _seeNative(PoolKey memory key, address coin, bool buy, bool exactIn, uint256 amount)
        internal
        returns (Figures memory f)
    {
        f.quoteMoved = trader.balance;
        f.coinsMoved = IERC20(coin).balanceOf(trader);
        f.fee = _nativeClaims();
        _swapNative(key, trader, buy, exactIn, amount, 100 ether);
        f.quoteMoved = _diff(f.quoteMoved, trader.balance);
        f.coinsMoved = _diff(f.coinsMoved, IERC20(coin).balanceOf(trader));
        f.fee = _nativeClaims() - f.fee;
    }

    function _assertFigures(Figures[4] memory seen, uint256[3][4] memory recorded) internal pure {
        for (uint256 i; i < 4; i++) {
            assertEq(seen[i].quoteMoved, recorded[i][0], "the Quote Asset the trader paid or received");
            assertEq(seen[i].coinsMoved, recorded[i][1], "the coins the trader received or paid");
            assertEq(seen[i].fee, recorded[i][2], "what the hook took");
        }
    }

    function test_noReferrer_erc20_quoteIsCurrency0_costsWhatItDidBefore() public {
        _assertFigures(
            _erc20Trades(true),
            [
                [uint256(10000000000000000000), 266495690144372810211535404599, 100000000000000000],
                [uint256(51983830552862284), 1000000000000000000000000000, 519838305528623],
                [uint256(5721753337162120375), 133747845072186405105767702299, 57795488254162833],
                [uint256(2000000000000000000), 59784607637215000660906902484, 20202020202020203]
            ]
        );
    }

    function test_noReferrer_erc20_quoteIsCurrency1_costsWhatItDidBefore() public {
        _assertFigures(
            _erc20Trades(false),
            [
                [uint256(10000000000000000000), 266495690144372810211534773869, 100000000000000000],
                [uint256(51983830552862284), 1000000000000000000000000000, 519838305528623],
                [uint256(5721753337162120375), 133747845072186405105767386934, 57795488254162833],
                [uint256(2000000000000000000), 59784607637215000660908098754, 20202020202020203]
            ]
        );
    }

    function test_noReferrer_native_costsWhatItDidBefore() public {
        _assertFigures(
            _nativeTrades(),
            [
                [uint256(1000000000000000000), 338827510871955966874821686543, 10000000000000000],
                [uint256(4611361061531565), 1000000000000000000000000000, 46113610615316],
                [uint256(600371202520900306), 169913755435977983437410843271, 6064355581019196],
                [uint256(50000000000000000), 18565121987655951015172661948, 505050505050506]
            ]
        );
    }
}
