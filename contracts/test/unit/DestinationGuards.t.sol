// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// What the launch core does about a Creator Earnings Destination (#248): it takes any address and knows
/// nothing of what stands behind it, refuses by name the five of our own contracts that can never be paid
/// usefully (as a Destination, and as a trade's referrer), and gives nobody a way to change a launched
/// coin's Destination.
contract DestinationGuardsTest is DestinationsLocalBase {
    function _ours() internal view returns (address[5] memory) {
        return [address(hook), address(factory), address(pm), address(taxVault), address(distributor)];
    }

    // ---------------------------------------------------------------- what the factory refuses

    function test_guards_theFactoryRefusesADestinationThatCanNeverBePaid() public {
        address[5] memory ours = _ours();
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 i; i < ours.length; i++) {
                StokerFactory.LaunchParams memory p = _typedParams(
                    kind == NATIVE_PAIR ? address(0) : address(quote),
                    kind == QUOTE_FIRST,
                    0,
                    StokerHook.LaunchType.Standard,
                    0,
                    0,
                    0,
                    StokerHook.PayoutAsset.QuoteAsset
                );
                p.creatorDestination = ours[i];
                vm.prank(creator);
                vm.expectRevert(abi.encodeWithSelector(StokerFactory.InvalidDestination.selector, ours[i]));
                factory.launch(p);
            }
        }
    }

    /// Any other address is taken as it is: a wallet, a contract of the Creator's, each of the three
    /// Destination contracts, and one made after the factory. The factory asks it nothing.
    function test_guards_anyOtherAddressIsTaken_andTheFactoryAsksItNothing() public {
        address later = address(new Silent());
        address[6] memory taken = [
            makeAddr("anotherWallet"),
            address(burnDestination),
            address(liquidityDestination),
            address(holdersDestination),
            later,
            address(registry)
        ];
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 i; i < taken.length; i++) {
                PoolKey memory key = _launchTo(kind, taken[i]);
                assertEq(_destinationOf(key), taken[i]);
            }
            PoolKey memory mine = _launchTo(kind, address(0));
            assertEq(_destinationOf(mine), creator, "none named: the Creator's own wallet");
        }
        assertEq(Silent(payable(later)).calls(), 0, "the launch called nothing on the Destination");
    }

    // ---------------------------------------------------------------- what the hook refuses as a referrer

    /// The Tax Vault and the Distributor join the hook, the factory and the PoolManager: a trade naming one
    /// of them as its referrer reverts by name before the pool runs, whichever side the fee is taken on.
    function test_guards_theHookRefusesOurFiveContractsAsReferrers() public {
        address[5] memory ours = _ours();
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            uint256 unit = _unit(key);
            _trade(key, trader, true, true, 10 * unit);
            if (!_native(key)) _approveRouter(key, trader);
            bool q0 = _quoteIsCurrency0(key);
            for (uint256 i; i < ours.length; i++) {
                bytes memory data = _referral(ours[i], 50);
                bytes memory refused = _hookError(
                    IHooks.beforeSwap.selector, abi.encodeWithSelector(StokerHook.InvalidReferrer.selector, ours[i])
                );
                for (uint256 swapType; swapType < 4; swapType++) {
                    bool buy = swapType < 2;
                    bool exactIn = swapType % 2 == 0;
                    uint256 amount = buy == exactIn ? unit : 1e6 ether;
                    uint160 limit = buy == q0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
                    vm.expectRevert(refused);
                    if (_native(key)) _swapNativeWithData(key, trader, buy, exactIn, amount, 10 * unit, limit, data);
                    else _swapWithData(key, trader, buy, exactIn, amount, limit, data);
                }
                assertEq(_creditIn(key, ours[i]), 0, "nobody was credited");
            }
        }
    }

    // ---------------------------------------------------------------- nobody changes a Destination

    /// No call by anyone changes a launched coin's Destination. The terms are written once: nobody but the
    /// factory may register, the factory cannot register a pool twice, and no key's call, no Payout Call,
    /// no Destination's work and no vault call leaves the terms other than they were. After all of it the
    /// next swap still credits the same address.
    function test_guards_noCallChangesALaunchedCoinsDestination() public {
        address thief = makeAddr("thief");
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory walletCoin = _launchTo(kind, address(0));
            PoolKey memory burnCoin = _launchRewardTo(kind, address(burnDestination), 2_500, 2_500);
            PoolKey[2] memory coins = [walletCoin, burnCoin];
            for (uint256 c; c < coins.length; c++) {
                PoolKey memory key = coins[c];
                PoolId id = key.toId();
                address destination = _destinationOf(key);
                bytes32 terms = keccak256(abi.encode(hook.termsOf(id)));
                _churn(key, 2);

                // Registering again, with the thief as the Destination: by everyone who is not the factory.
                StokerHook.Terms memory forged = hook.termsOf(id);
                forged.creatorDestination = thief;
                address[8] memory callers =
                    [thief, creator, platform, ladderKey, roundKey, destination, address(taxVault), address(pm)];
                for (uint256 i; i < callers.length; i++) {
                    vm.prank(callers[i]);
                    vm.expectRevert(StokerHook.OnlyFactory.selector);
                    hook.registerLaunch(key, forged);
                }
                // And by the factory itself, were it ever to call again: a pool's terms are written once.
                vm.prank(address(factory));
                vm.expectRevert(StokerHook.AlreadyRegistered.selector);
                hook.registerLaunch(key, forged);

                // Every key's every call, the Payout Call, the Destination's work and the vault's calls.
                // The ladder key's one call: refused here, since the coin has not graduated, and a raise
                // that goes through moves the tier alone (`DestinationsGraduated.t.sol`, `Ladder.t.sol`).
                vm.prank(ladderKey);
                vm.expectRevert(StokerHook.NotGraduated.selector);
                hook.raiseTier(id, 3);
                vm.startPrank(platform);
                keys.proposeKey(StokerKeys.Role.LadderKey, thief);
                keys.revokeKey(StokerKeys.Role.Keeper);
                registry.delist(kind == NATIVE_PAIR ? address(0) : address(quote));
                keys.proposeAdmin(thief);
                vm.stopPrank();
                vm.prank(thief);
                keys.acceptAdmin();
                address[] memory owners = new address[](2);
                (owners[0], owners[1]) = (destination, platform);
                vm.prank(thief);
                hook.payout(_quoteOfKey(key), owners);
                if (destination == address(burnDestination)) {
                    vm.prank(thief);
                    burnDestination.applyEarnings(key);
                    _letThePriceStand();
                    vm.startPrank(thief);
                    taxVault.burn(key);
                    taxVault.addSupport(key);
                    taxVault.passHoldersPart(key);
                    vm.stopPrank();
                }
                // The same Creator launching the same coin again cannot take the pool's place.
                assertEq(keccak256(abi.encode(hook.termsOf(id))), terms, "the terms are as they were written");
                assertEq(_destinationOf(key), destination);

                uint256 before = _creditIn(key, destination);
                uint256 credited = _credited(key);
                _trade(key, trader, true, true, _unit(key));
                assertGt(_creditIn(key, destination) - before, 0, "the next swap credits the same address");
                assertEq(_creditIn(key, destination) - before, _credited(key) - credited);
                assertEq(_creditIn(key, thief), _creditIn(key, keys.admin()), "the thief has the Admin's share alone");

                // Put the fixture's Admin, keys and Listing back for the next turn.
                vm.prank(thief);
                keys.proposeAdmin(platform);
                vm.startPrank(platform);
                keys.acceptAdmin();
                keys.proposeKey(StokerKeys.Role.LadderKey, ladderKey);
                vm.stopPrank();
                vm.prank(ladderKey);
                keys.acceptKey(StokerKeys.Role.LadderKey);
                skip(1 days);
                vm.prank(platform);
                registry.scheduleChange(
                    kind == NATIVE_PAIR ? address(0) : address(quote),
                    kind == NATIVE_PAIR ? NATIVE_START_TICK : START_TICK,
                    GRADUATION_MULTIPLE,
                    REFERRER_FEE_CAP_BPS
                );
                skip(48 hours);
            }
        }
    }

    /// A Destination contract has no owner and no setter: its only function that writes is the work anyone
    /// may call, and what it serves is fixed in its code.
    function test_guards_aDestinationHasNoSetter() public view {
        EarningsDestination[3] memory d = [
            EarningsDestination(payable(address(burnDestination))),
            EarningsDestination(payable(address(liquidityDestination))),
            EarningsDestination(payable(address(holdersDestination)))
        ];
        for (uint256 i; i < d.length; i++) {
            assertEq(address(d[i].hook()), address(hook));
        }
        assertEq(address(burnDestination.taxVault()), address(taxVault));
        assertEq(address(liquidityDestination.taxVault()), address(taxVault));
        assertEq(address(holdersDestination.distributor()), address(distributor));
        assertEq(IERC20(address(quote)).allowance(address(burnDestination), address(taxVault)), 0);
    }
}

/// A contract that counts every call it receives.
contract Silent {
    uint256 public calls;

    fallback() external payable {
        calls++;
    }

    receive() external payable {
        calls++;
    }
}
