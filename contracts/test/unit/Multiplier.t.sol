// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {Distributor} from "../../src/Distributor.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";

/// A stand-in Stock Token with an ERC-8056 multiplier, as Robinhood Chain's have: a corporate action (a split,
/// a dividend) changes `uiMultiplier()`, the shares each raw unit stands for, and no balance. Any address set
/// as forbidden is refused the reading by name, so a contract of ours that read it would stop the test.
contract MultiplierQuote is MockQuote {
    uint256 internal _multiplier = 1e18;
    mapping(address => bool) public forbidden;

    error MultiplierReadBy(address reader);

    function setUiMultiplier(uint256 multiplier) external {
        _multiplier = multiplier;
    }

    function forbid(address reader) external {
        forbidden[reader] = true;
    }

    function uiMultiplier() external view returns (uint256) {
        if (forbidden[msg.sender]) revert MultiplierReadBy(msg.sender);
        return _multiplier;
    }
}

/// The security standards' profile of Robinhood Chain names one trap above all others: a Stock Token's ERC-8056
/// multiplier is 1e18 at launch, so code that applies it wrongly gives the right answer until the first
/// corporate action, in every test that never moves it. Stoker's contracts are on the safe side of it by
/// reading no price and no multiplier at all (ADR 0028: the hook reads no oracle, and the multiplier is display
/// only, the API's to show beside raw units). This file moves the multiplier and proves exactly that: every
/// figure a contract of ours books or pays is in raw units and is the same to the unit across a 10:1 split, no
/// contract of ours reads the multiplier, and none carries its selector.
///
/// It does not test a pricing module against a second price source, as the standards' own
/// `MultiplierConventionProperties` does: the contracts have no pricing module. What the site shows a visitor
/// of a Stock Token's amount is the stack's (#252, #256), not proven here.
contract MultiplierTest is DestinationsLocalBase {
    MultiplierQuote internal stock;
    PoolKey internal key;
    address internal holderA = makeAddr("holderA");
    address internal holderB = makeAddr("holderB");

    /// Every figure of one run of the scenario, in the Stock Token's raw units and the coin's.
    struct Figures {
        uint256 creatorCredit;
        uint256 platformCredit;
        uint256 taxBooked;
        uint256 coinsBought;
        uint256 quoteBack;
        uint256 creatorPaid;
        uint256 burnSpent;
        uint256 supplyBurned;
        uint256 supportAdded;
        uint256 holdersPart;
        uint256 paidA;
        uint256 paidB;
    }

    function setUp() public override {
        pm = new PoolManager(address(this));
        stock = new MultiplierQuote();
        mockQuote = MockQuote(address(stock));
        quote = IERC20(address(stock));
        _deployStoker();
        mockQuote.mint(creator, 1_000 ether);
        mockQuote.mint(trader, 1_000_000 ether);
        _deployDestinations();
        key = _launchRewardTo(COIN_FIRST, address(0), 2_500, 2_500);
        // The PoolManager and every contract of ours: none may read the multiplier.
        address[8] memory ours = [
            address(pm),
            address(hook),
            address(factory),
            address(taxVault),
            address(distributor),
            address(burnDestination),
            address(liquidityDestination),
            address(holdersDestination)
        ];
        for (uint256 i; i < ours.length; i++) {
            stock.forbid(ours[i]);
        }
    }

    /// A buy, a sell, a Payout Call, the Tax Vault's three calls and a paid Reward Round, with the multiplier
    /// set to `before` at the start and to `after_` once the trades are booked: a corporate action that lands
    /// between a trade and its payments.
    function _scenario(uint256 before, uint256 after_) internal returns (Figures memory f) {
        stock.setUiMultiplier(before);
        Currency asset = _quoteOfKey(key);
        IERC20 coin = _coinOfKey(key);
        uint256 creatorOwed = _credit(creator);
        uint256 platformOwed = _credit(platform);
        uint256 coins = coin.balanceOf(trader);
        _trade(key, trader, true, true, 10 ether);
        f.coinsBought = coin.balanceOf(trader) - coins;
        uint256 held = quote.balanceOf(trader);
        _trade(key, trader, false, true, f.coinsBought / 2);
        f.quoteBack = quote.balanceOf(trader) - held;
        f.creatorCredit = _credit(creator) - creatorOwed;
        f.platformCredit = _credit(platform) - platformOwed;
        f.taxBooked = hook.taxBooked(key.toId());

        stock.setUiMultiplier(after_);

        address[] memory owners = new address[](1);
        owners[0] = creator;
        held = quote.balanceOf(creator);
        hook.payout(asset, owners);
        f.creatorPaid = quote.balanceOf(creator) - held;

        _letThePriceStand();
        uint256 supply = coin.totalSupply();
        (f.burnSpent,) = taxVault.burn(key);
        f.supplyBurned = supply - coin.totalSupply();
        (f.supportAdded,) = taxVault.addSupport(key);
        (, f.holdersPart) = taxVault.passHoldersPart(key);

        (address[] memory holders, uint256[] memory amounts) =
            _pair(holderA, f.holdersPart / 3, holderB, f.holdersPart - f.holdersPart / 3);
        Built memory round = _post(address(coin), asset, holders, amounts);
        _warpPastDelay(round.round);
        distributor.claim(_claims(round));
        f.paidA = quote.balanceOf(holderA);
        f.paidB = quote.balanceOf(holderB);
    }

    function _assertSame(Figures memory a, Figures memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "a figure changed with the multiplier");
        assertGt(a.creatorCredit, 0);
        assertGt(a.taxBooked, 0);
        assertGt(a.burnSpent, 0);
        assertGt(a.supportAdded, 0);
        assertGt(a.paidA, 0);
        assertEq(a.creatorPaid, a.creatorCredit, "a Credit is paid in the raw units it was booked in");
        assertEq(a.paidA + a.paidB, a.holdersPart, "a round pays the raw units its pot took in");
    }

    /// A 10:1 split changes no figure of ours: the same scenario with the multiplier at 1, at 10, and changed
    /// from 1 to 10 between the trades and the payments gives the same Credits, tax, pieces, pot and payments,
    /// to the unit.
    function test_multiplier_aSplitChangesNoFigureOfOurs() public {
        uint256 start = vm.snapshotState();
        Figures memory atOne = _scenario(1e18, 1e18);
        vm.revertToState(start);
        Figures memory atTen = _scenario(10e18, 10e18);
        vm.revertToState(start);
        Figures memory across = _scenario(1e18, 10e18);
        _assertSame(atOne, atTen);
        _assertSame(atOne, across);
    }

    /// The scenario ran with every contract of ours forbidden the reading, and the refusal is live: a reading
    /// by the hook, were it ever made, reverts by name.
    function test_multiplier_noContractOfOursReadsIt() public {
        _scenario(1e18, 10e18);
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(MultiplierQuote.MultiplierReadBy.selector, address(hook)));
        stock.uiMultiplier();
        assertEq(stock.uiMultiplier(), 10e18, "anyone else reads it");
    }

    /// No runtime of ours carries the multiplier's selector, nor that of a price feed's `latestRoundData()`:
    /// the hook, the factory, the Tax Vault, the Distributor, the registry, the keys, the three Destinations,
    /// a coin and a Creator Lock.
    function test_multiplier_noRuntimeCarriesItsSelectorOrAPriceFeeds() public {
        StokerCreatorLock lock = new StokerCreatorLock(_coinOfKey(key), hook, key.toId(), creator, 1, 7 days, 0);
        address[11] memory ours = [
            address(hook),
            address(factory),
            address(taxVault),
            address(distributor),
            address(registry),
            address(keys),
            address(burnDestination),
            address(liquidityDestination),
            address(holdersDestination),
            address(_coinOfKey(key)),
            address(lock)
        ];
        bytes4[2] memory selectors = [bytes4(keccak256("uiMultiplier()")), bytes4(keccak256("latestRoundData()"))];
        for (uint256 i; i < ours.length; i++) {
            assertGt(ours[i].code.length, 0);
            for (uint256 s; s < selectors.length; s++) {
                assertFalse(_carries(ours[i].code, selectors[s]), "a runtime of ours carries a price's selector");
            }
        }
        // The search finds a selector that is there: the coin's own `burn(uint256)`.
        assertTrue(_carries(address(_coinOfKey(key)).code, StokerCoin.burn.selector), "the search sees a selector");
    }

    function _carries(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i + 4 <= code.length; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }
}
