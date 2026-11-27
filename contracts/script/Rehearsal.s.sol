// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RehearsalBase} from "./rehearsal/RehearsalBase.sol";
import {RehearsalDollar} from "./rehearsal/RehearsalDollar.sol";
import {ListingMath} from "./ListingWrite.s.sol";
import {StokerKeys} from "../src/StokerKeys.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {Distributor} from "../src/Distributor.sol";
import {TaxVault} from "../src/TaxVault.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";
import {StokerCreatorLock} from "../src/StokerCreatorLock.sol";
import {EarningsDestination} from "../src/destinations/EarningsDestination.sol";

/// @title Rehearsal
/// @notice The rehearsal of the whole contract set on a testnet, and first on a fork of it (#251): one step a
///         call, in order, each sending real transactions from the rehearsal's own keys, with the two waits the
///         chain's clock imposes between them (the Graduation Hold's hour before `graduate`, the Round Delay's
///         24 hours before `pay`). `script/rehearse.sh` runs them.
///
///         setup     the Admin appoints the three server keys and each accepts; the issuer deploys the dollar
///                   stand-in; the Admin lists the native asset, the stand-in Stock Token and the dollar
///         launch    a standard coin (a permit First Buy, a Creator Lock), a Reward Launch (a native First
///                   Buy), a Stoke Launch (a First Buy from an allowance) and a second standard coin; a buy
///                   inside the Opening Fee's seconds
///         trade     buys and sells of all four through the Universal Router, one naming a referrer
///         tend      the Tax Vault's calls and the burn's Destination, made by the Keeper
///         freeze    a frozen Credit stays owed and is paid once unfrozen; a paused Quote Asset stops trading
///         lift      buys that leave three coins above their Graduation Targets
///         graduate  an hour later: Graduation recorded, the ladder key's raises, the Destinations' work,
///                   Payout Calls
///         rounds    a false Round Root posted and cancelled by the Guard, the true one posted again, and a
///                   round of source `earnings`
///         pay       24 hours later: the Keeper pushes every claim
///
///         Every refusal a step names is asked of the chain by a call inside the step's simulation, as the
///         address it names: it sends nothing, and a call that went through fails the step.
/// @dev    CONFIG, DEPLOYMENT and the eight REHEARSAL_<ROLE>_KEY variables (ADMIN, ROUND, LADDER, KEEPER,
///         CREATOR, TRADER, HOLDER, ISSUER), read from the environment and never arguments.
contract Rehearsal is RehearsalBase {
    // ------------------------------------------------------------------ fund

    /// The trader, which the faucet paid, sends each key that signs a float for its gas, the deployer's first:
    /// nothing else here needs the deployment, so this runs before it.
    function fund() external {
        string memory json = vm.readFile(vm.envString("CONFIG"));
        uint256 float = vm.parseJsonUint(json, ".rehearsal.gasFloat");
        uint256 key = vm.envUint("REHEARSAL_TRADER_KEY");
        string[7] memory names = [
            "REHEARSAL_DEPLOYER_KEY",
            "REHEARSAL_ADMIN_KEY",
            "REHEARSAL_ROUND_KEY",
            "REHEARSAL_LADDER_KEY",
            "REHEARSAL_KEEPER_KEY",
            "REHEARSAL_CREATOR_KEY",
            "REHEARSAL_ISSUER_KEY"
        ];
        vm.startBroadcast(key);
        for (uint256 i; i < names.length; i++) {
            address to = vm.addr(vm.envUint(names[i]));
            // The deployer pays for nine contracts, the factory's initcode among them.
            uint256 amount = i == 0 ? 10 * float : float;
            if (to.balance >= amount) continue;
            (bool ok,) = to.call{value: amount - to.balance}("");
            if (!ok) revert Unexpected("a float was not delivered");
        }
        vm.stopBroadcast();
        console2.log("fund: each signing key holds its float", float);
    }

    // ------------------------------------------------------------------ setup

    function setup() external {
        _load();
        if (vm.getNonce(issuer) != 0) revert StepNotReady("the issuer has sent a transaction: setup ran before");

        vm.startBroadcast(adminKey);
        d.keys.proposeKey(StokerKeys.Role.RoundKey, round);
        d.keys.proposeKey(StokerKeys.Role.LadderKey, ladder);
        d.keys.proposeKey(StokerKeys.Role.Keeper, keeper);
        vm.stopBroadcast();
        vm.broadcast(roundKey);
        d.keys.acceptKey(StokerKeys.Role.RoundKey);
        vm.broadcast(ladderKey);
        d.keys.acceptKey(StokerKeys.Role.LadderKey);
        vm.broadcast(keeperKey);
        d.keys.acceptKey(StokerKeys.Role.Keeper);

        vm.startBroadcast(issuerKey);
        RehearsalDollar made = new RehearsalDollar();
        if (address(made) != address(dollar)) revert Unexpected("the dollar is not at the issuer's first address");
        dollar.mint(creator, 1_000e6);
        dollar.mint(trader, 100_000e6);
        vm.stopBroadcast();

        // The Stoke Launch's Creator pays its First Buy in the Stock Token, which the faucet gave the trader.
        vm.broadcast(traderKey);
        IERC20(f.stockToken).transfer(creator, f.stockOpeningValue / 50);

        // The Listings: the dollar opens as a mainnet Listing would ($5,000, a multiple of 20); the native
        // asset and the Stock Token open small with the registry's least multiple, sized to a faucet's claim.
        int24 spacing = s.tickSpacing;
        vm.startBroadcast(adminKey);
        d.registry
            .list(
                address(0),
                ListingMath.startTickFor(f.nativeOpeningValue, spacing),
                f.smallGraduationMultiple,
                f.referrerFeeCapBps
            );
        d.registry
            .list(
                f.stockToken,
                ListingMath.startTickFor(f.stockOpeningValue, spacing),
                f.smallGraduationMultiple,
                f.referrerFeeCapBps
            );
        d.registry
            .list(
                address(dollar),
                ListingMath.startTickFor(f.dollarOpeningValue, spacing),
                f.dollarGraduationMultiple,
                f.referrerFeeCapBps
            );
        vm.stopBroadcast();

        _refused(
            "a stranger writing the Quote Registry",
            trader,
            address(d.registry),
            abi.encodeCall(QuoteRegistry.delist, (address(0))),
            QuoteRegistry.NotAdmin.selector
        );
        _refused(
            "a server key appointing a key",
            keeper,
            address(d.keys),
            abi.encodeCall(StokerKeys.proposeKey, (StokerKeys.Role.RoundKey, keeper)),
            StokerKeys.NotAdmin.selector
        );
        console2.log("setup: the three server keys are held, the dollar is at", address(dollar));
    }

    // ------------------------------------------------------------------ launch

    function launch() external {
        _load();
        if (address(dollar).code.length == 0) revert StepNotReady("run setup first");
        if (_launched(standard)) revert StepNotReady("the coins are launched already");

        // The standard coin: a First Buy by an ERC-2612 permit (one transaction, a signature and no approval),
        // the Creator's own wallet as the Destination, and a Creator Lock.
        uint256 dollars = f.dollarOpeningValue / 200;
        StokerFactory.LaunchParams memory p = _params(standard, address(0), dollars);
        p.creatorLockBps = f.creatorLockBps;
        p.creatorLockCliff = f.creatorLockCliff;
        p.creatorLockUnlock = f.creatorLockUnlock;
        StokerFactory.PermitSignature memory permit = _permit(address(dollar), dollars);
        vm.broadcast(creatorKey);
        d.factory.launchWithPermit(p, permit);

        // The Reward Launch: the native asset, a First Buy that is the value sent, the earnings to the holders.
        uint256 nativeBuy = f.nativeOpeningValue / 5_000;
        p = _params(reward, address(d.holdersDestination), nativeBuy);
        p.launchType = StokerHook.LaunchType.Reward;
        p.taxBps = f.rewardTaxBps;
        p.burnShareBps = f.rewardBurnShareBps;
        p.liquidityShareBps = f.rewardLiquidityShareBps;
        vm.broadcast(creatorKey);
        d.factory.launch{value: nativeBuy}(p);

        // The Stoke Launch: the Stock Token, a First Buy from an allowance, the earnings to the liquidity.
        uint256 stockBuy = f.stockOpeningValue / 200;
        p = _params(stoke, address(d.liquidityDestination), stockBuy);
        p.launchType = StokerHook.LaunchType.Liquidity;
        p.taxBps = f.stokeTaxBps;
        vm.startBroadcast(creatorKey);
        IERC20(f.stockToken).approve(address(d.factory), stockBuy);
        d.factory.launch(p);
        // A second standard coin with no First Buy, whose earnings burn it.
        d.factory.launch(_params(burner, address(d.burnDestination), 0));
        vm.stopBroadcast();

        // A buy inside the Opening Fee's seconds: all but a sliver of it becomes the coin's Support Liquidity.
        _swap(traderKey, burner, true, f.nativeOpeningValue / 100, "");

        _refused(
            "a launch that names the Tax Vault as its Destination",
            trader,
            address(d.factory),
            abi.encodeCall(StokerFactory.launch, (_params(burner, address(d.taxVault), 0))),
            StokerFactory.InvalidDestination.selector
        );
        console2.log("launch: four coins");
        console2.log("  standard", standard.coin);
        console2.log("  reward", reward.coin);
        console2.log("  stoke", stoke.coin);
        console2.log("  burner", burner.coin);
        console2.log("  the standard coin's Creator Lock", d.factory.creatorLockOf(standard.id));
    }

    // ------------------------------------------------------------------ trade

    function trade() external {
        _load();
        if (!_launched(burner)) revert StepNotReady("run launch first");
        _approveRouter(traderKey, address(dollar));
        _approveRouter(traderKey, f.stockToken);
        _approveRouter(traderKey, standard.coin);
        _approveRouter(traderKey, reward.coin);
        _approveRouter(traderKey, stoke.coin);
        _approveRouter(traderKey, burner.coin);

        // A buy of each, the Reward Launch's naming a referrer at the Listing's cap; then a sell of each. The
        // two coins whose burns the next step makes are sold back whole, so their prices stand where they were.
        _swap(traderKey, standard, true, f.dollarOpeningValue / 50, "");
        _swap(traderKey, reward, true, f.nativeOpeningValue / 50, abi.encode(holder, uint256(f.referrerFeeCapBps)));
        _swap(traderKey, stoke, true, f.stockOpeningValue / 50, "");
        _swap(traderKey, burner, true, f.nativeOpeningValue / 50, "");

        _swap(traderKey, standard, false, IERC20(standard.coin).balanceOf(trader) / 2, "");
        _swap(traderKey, reward, false, IERC20(reward.coin).balanceOf(trader), "");
        _swap(traderKey, stoke, false, IERC20(stoke.coin).balanceOf(trader) / 2, "");
        _swap(traderKey, burner, false, IERC20(burner.coin).balanceOf(trader), "");

        (bytes memory overCap, uint256 value) = _routerCall(
            reward, true, f.nativeOpeningValue / 50, 0, abi.encode(holder, uint256(f.referrerFeeCapBps) + 1)
        );
        _refusedWith(
            "a trade naming a Referrer Fee over the Listing's cap",
            trader,
            f.universalRouter,
            value,
            overCap,
            abi.encodePacked(StokerHook.ReferrerFeeOverCap.selector)
        );
        console2.log("trade: the referrer's Credit", d.hook.creditOf(holder, NATIVE));
        console2.log("  the Reward Launch's tax booked", d.hook.taxBooked(reward.id));
        console2.log("  the Stoke Launch's tax booked", d.hook.taxBooked(stoke.id));
        console2.log("  the Opening Fee booked on the second standard coin", d.hook.openingFeeBooked(burner.id));
    }

    // ------------------------------------------------------------------ tend

    function tend() external {
        _load();
        if (d.hook.taxBooked(reward.id) == 0) revert StepNotReady("run trade first");
        if (!_priceHasStood(reward) || !_priceHasStood(burner)) {
            revert StepNotReady("a price stands above its Reference Price: the burns wait; try again in a few minutes");
        }
        uint256 supplyBefore = IERC20(reward.coin).totalSupply() + IERC20(burner.coin).totalSupply();

        vm.startBroadcast(keeperKey);
        // The burn's Destination: the second standard coin's Creator earnings fund its burn, which buys and burns.
        d.burnDestination.applyEarnings(burner.key);
        d.taxVault.burn(burner.key);
        // The Reward Launch: the Reward Burn, the Reward Liquidity as Support Liquidity, the holders' part.
        d.taxVault.burn(reward.key);
        d.taxVault.addSupport(reward.key);
        d.taxVault.passHoldersPart(reward.key);
        // The Stoke Launch's tax, and the second standard coin's Opening Fee: Support Liquidity, no coin bought.
        d.taxVault.addSupport(stoke.key);
        d.taxVault.addSupport(burner.key);
        vm.stopBroadcast();

        if (IERC20(reward.coin).totalSupply() + IERC20(burner.coin).totalSupply() >= supplyBefore) {
            revert Unexpected("the burns lowered no supply");
        }
        _refused(
            "a second burn inside the interval",
            keeper,
            address(d.taxVault),
            abi.encodeCall(TaxVault.burn, (reward.key)),
            TaxVault.TooSoon.selector
        );
        _refused(
            "the burn's Destination working for a coin that names another",
            keeper,
            address(d.burnDestination),
            abi.encodeCall(EarningsDestination.applyEarnings, (standard.key)),
            EarningsDestination.NotThisCoinsDestination.selector
        );
        _refused(
            "a stranger depositing into the Distributor",
            trader,
            address(d.distributor),
            abi.encodeCall(Distributor.deposit, (reward.coin, NATIVE, 0)),
            Distributor.NotTaxVault.selector
        );
        console2.log("tend: the Reward Launch's pot in the Distributor", d.distributor.potOf(reward.coin, NATIVE));
    }

    // ------------------------------------------------------------------ freeze

    function freeze() external {
        _load();
        Currency usd = Currency.wrap(address(dollar));
        uint256 owed = d.hook.creditOf(creator, usd);
        if (owed == 0) revert StepNotReady("the Creator is owed nothing in the dollar: run trade first");
        address[] memory both = new address[](2);
        (both[0], both[1]) = (creator, admin);
        address[] memory one = new address[](1);
        one[0] = creator;
        uint256 creatorHeld = dollar.balanceOf(creator);
        uint256 adminOwed = d.hook.creditOf(admin, usd);
        uint256 adminHeld = dollar.balanceOf(admin);

        // The issuer freezes the Creator: the Payout Call pays the Admin and leaves the Creator owed.
        vm.broadcast(issuerKey);
        dollar.setFrozen(creator, true);
        vm.broadcast(keeperKey);
        d.hook.payout(usd, both);
        if (d.hook.creditOf(creator, usd) != owed || dollar.balanceOf(creator) != creatorHeld) {
            revert Unexpected("a frozen Credit moved");
        }
        if (d.hook.creditOf(admin, usd) != 0 || dollar.balanceOf(admin) != adminHeld + adminOwed) {
            revert Unexpected("the Admin was not paid beside the frozen Creator");
        }
        // Unfrozen, the same call pays it, to the same address.
        vm.broadcast(issuerKey);
        dollar.setFrozen(creator, false);
        vm.broadcast(keeperKey);
        d.hook.payout(usd, one);
        if (d.hook.creditOf(creator, usd) != 0 || dollar.balanceOf(creator) != creatorHeld + owed) {
            revert Unexpected("the unfrozen Credit was not paid in full");
        }

        // The issuer's pause stops every trade of a coin paired with the asset; nothing of ours can change that.
        vm.broadcast(issuerKey);
        dollar.setPaused(true);
        (bytes memory buy,) = _routerCall(standard, true, f.dollarOpeningValue / 50, 0, "");
        // Permit2 answers a failed pull in its own words, whatever the asset said.
        _refusedWith(
            "a buy of a coin whose Quote Asset is paused",
            trader,
            f.universalRouter,
            0,
            buy,
            bytes("TRANSFER_FROM_FAILED")
        );
        vm.broadcast(issuerKey);
        dollar.setPaused(false);
        console2.log("freeze: the Creator's frozen Credit stayed owed, then was paid", owed);
    }

    // ------------------------------------------------------------------ lift

    function lift() external {
        _load();
        if (d.distributor.potOf(reward.coin, NATIVE) == 0) revert StepNotReady("run tend first");
        _refused(
            "Graduation recorded with no hold running",
            keeper,
            address(d.hook),
            abi.encodeCall(StokerHook.graduate, (standard.id)),
            StokerHook.GraduationHoldNotComplete.selector
        );
        _swap(traderKey, standard, true, _toCrossTheTarget(standard), "");
        _swap(traderKey, reward, true, _toCrossTheTarget(reward), "");
        _swap(traderKey, stoke, true, _toCrossTheTarget(stoke), "");
        if (!_atOrAboveTarget(standard) || !_atOrAboveTarget(reward) || !_atOrAboveTarget(stoke)) {
            revert Unexpected("a coin is not above its Graduation Target");
        }
        // The Tax Vault never buys at a price only just reached: the Reward Burn waits, by name (#271).
        _refused(
            "the Reward Burn at a price only just reached",
            keeper,
            address(d.taxVault),
            abi.encodeCall(TaxVault.burn, (reward.key)),
            TaxVault.AboveReference.selector
        );
        console2.log("lift: three coins stand above their Graduation Targets since", block.timestamp);
        console2.log("  the Graduation Hold ends at", block.timestamp + d.hook.GRADUATION_HOLD());
    }

    // ------------------------------------------------------------------ graduate

    function graduate() external {
        _load();
        if (d.hook.graduationNow(standard.id).graduatedAt == 0) {
            revert StepNotReady("the Graduation Hold has not run its hour: wait, and no price may fall under its target");
        }
        _refused(
            "a raise before Graduation is recorded",
            ladder,
            address(d.hook),
            abi.encodeCall(StokerHook.raiseTier, (standard.id, 2)),
            StokerHook.NotGraduated.selector
        );

        vm.startBroadcast(keeperKey);
        d.hook.graduate(standard.id);
        d.hook.graduate(reward.id);
        d.hook.graduate(stoke.id);
        vm.stopBroadcast();

        _refused(
            "a raise by the Admin",
            admin,
            address(d.hook),
            abi.encodeCall(StokerHook.raiseTier, (standard.id, 2)),
            StokerHook.NotLadderKey.selector
        );
        _refused(
            "a raise by the Keeper",
            keeper,
            address(d.hook),
            abi.encodeCall(StokerHook.raiseTier, (standard.id, 2)),
            StokerHook.NotLadderKey.selector
        );
        _refused(
            "a raise of a coin that has not graduated",
            ladder,
            address(d.hook),
            abi.encodeCall(StokerHook.raiseTier, (burner.id, 2)),
            StokerHook.NotGraduated.selector
        );
        _refused(
            "Graduation recorded twice",
            keeper,
            address(d.hook),
            abi.encodeCall(StokerHook.graduate, (standard.id)),
            StokerHook.AlreadyGraduated.selector
        );

        // The ladder key's whole power: one coin to the second tier, one straight to the top.
        vm.startBroadcast(ladderKey);
        d.hook.raiseTier(standard.id, 2);
        d.hook.raiseTier(reward.id, 3);
        d.hook.raiseTier(stoke.id, 2);
        vm.stopBroadcast();
        _refused(
            "a raise that lowers a tier",
            ladder,
            address(d.hook),
            abi.encodeCall(StokerHook.raiseTier, (reward.id, 2)),
            StokerHook.InvalidTier.selector
        );

        // A buy of each after its raise: the Creator's part of the same fee is the new tier's share.
        _buyAndReadTheSplit(standard, f.dollarOpeningValue / 100, s.secondTierShareBps);
        _buyAndReadTheSplit(reward, f.nativeOpeningValue / 100, s.topTierShareBps);
        _buyAndReadTheSplit(stoke, f.stockOpeningValue / 100, s.secondTierShareBps);

        // Each Destination's work, and what the Tax Vault can do at these prices: Support Liquidity is placed
        // under the Reference Price, the holders' part is handed on, and the burns wait for the price to stand.
        vm.startBroadcast(keeperKey);
        d.holdersDestination.applyEarnings(reward.key);
        d.liquidityDestination.applyEarnings(stoke.key);
        d.burnDestination.applyEarnings(burner.key);
        d.taxVault.addSupport(stoke.key);
        d.taxVault.addSupport(reward.key);
        d.taxVault.passHoldersPart(reward.key);
        vm.stopBroadcast();

        _payouts();

        StokerCreatorLock creatorLock = StokerCreatorLock(d.factory.creatorLockOf(standard.id));
        _refused(
            "the Creator Lock claimed inside its cliff",
            creator,
            address(creatorLock),
            abi.encodeCall(StokerCreatorLock.claim, ()),
            StokerCreatorLock.NothingToClaim.selector
        );
        _refused(
            "the Creator Lock claimed by another address",
            trader,
            address(creatorLock),
            abi.encodeCall(StokerCreatorLock.claim, ()),
            StokerCreatorLock.NotCreator.selector
        );
        console2.log("graduate: the standard coin graduated at", d.hook.graduationOf(standard.id).graduatedAt);
        console2.log(
            "  its Creator Lock holds",
            creatorLock.amount(),
            "and releases from",
            creatorLock.graduatedAt() + creatorLock.cliff()
        );
        console2.log(
            "  the Reward Launch's earnings pot in the Distributor", d.distributor.earningsPotOf(reward.coin, NATIVE)
        );
    }

    function _buyAndReadTheSplit(Coin memory c, uint256 amount, uint16 shareBps) internal {
        if (d.hook.creatorShareOf(c.id) != shareBps) revert Unexpected("a coin's share is not its tier's");
        uint256 credited = d.hook.creatorCreditedOf(c.id);
        _swap(traderKey, c, true, amount, "");
        uint256 fee = (amount * s.platformFeeBps + 9_999) / 10_000;
        if (d.hook.creatorCreditedOf(c.id) - credited != fee * shareBps / 10_000) {
            revert Unexpected("the Creator's Credit is not the raised tier's share of the fee");
        }
    }

    /// The Keeper's Payout Calls: anyone can make them, and each Credit goes to its owner alone.
    function _payouts() internal {
        Currency usd = Currency.wrap(address(dollar));
        Currency stock = Currency.wrap(f.stockToken);
        address[] memory two = new address[](2);
        (two[0], two[1]) = (creator, admin);
        address[] memory nativeOwners = new address[](2);
        (nativeOwners[0], nativeOwners[1]) = (admin, holder);
        address[] memory one = new address[](1);
        one[0] = admin;
        uint256 referrerOwed = d.hook.creditOf(holder, NATIVE);
        uint256 referrerHeld = holder.balance;
        vm.startBroadcast(keeperKey);
        d.hook.payout(usd, two);
        d.hook.payout(NATIVE, nativeOwners);
        d.hook.payout(stock, one);
        vm.stopBroadcast();
        if (holder.balance != referrerHeld + referrerOwed || d.hook.creditOf(holder, NATIVE) != 0) {
            revert Unexpected("the referrer was not paid its Credit");
        }
        if (d.hook.creditOf(admin, usd) != 0 || d.hook.creditOf(admin, NATIVE) != 0) {
            revert Unexpected("the platform's share was not paid to the Admin");
        }
    }

    // ------------------------------------------------------------------ rounds

    function rounds() external {
        _load();
        uint256 pot = d.distributor.availableOf(reward.coin, NATIVE);
        uint256 earnings = d.distributor.earningsAvailableOf(reward.coin, NATIVE);
        if (pot == 0 || earnings == 0) {
            revert StepNotReady("the Reward Launch's two pots are not both filled: run graduate");
        }
        if (d.distributor.roundCount() != 0) revert StepNotReady("rounds were posted already");

        // A false root, as a stolen round key would post one: the whole pot to the key's own address. It is
        // refused nothing, since the Distributor cannot tell; the Guard cancels it inside the Round Delay.
        bytes32 falseRoot = d.distributor.leafOf(1, reward.coin, round, pot);
        vm.broadcast(roundKey);
        d.distributor.postRoot(1, reward.coin, NATIVE, falseRoot, pot);
        if (d.distributor.availableOf(reward.coin, NATIVE) != 0) {
            revert Unexpected("the root reserved less than its total");
        }
        vm.broadcast(adminKey);
        d.distributor.cancelRoot(1);
        if (d.distributor.availableOf(reward.coin, NATIVE) != pot) {
            revert Unexpected("the cancel freed less than it reserved");
        }

        // The true root, posted again under the next number, and a round of source `earnings` beside it.
        (bytes32 root,) = _roundOf(2, reward.coin, pot);
        (bytes32 earningsRoot,) = _roundOf(3, reward.coin, earnings);
        vm.startBroadcast(roundKey);
        d.distributor.postRoot(2, reward.coin, NATIVE, root, pot);
        d.distributor.postEarningsRoot(3, reward.coin, NATIVE, earningsRoot, earnings);
        vm.stopBroadcast();

        (, Distributor.Claim[] memory claims) = _roundOf(2, reward.coin, pot);
        _refused(
            "a claim inside the Round Delay",
            keeper,
            address(d.distributor),
            abi.encodeCall(Distributor.claim, (claims)),
            Distributor.RoundDelay.selector
        );
        Distributor.Claim[] memory thief = new Distributor.Claim[](1);
        thief[0] = Distributor.Claim(1, round, pot, new bytes32[](0));
        _refused(
            "a claim on the cancelled root",
            round,
            address(d.distributor),
            abi.encodeCall(Distributor.claim, (thief)),
            Distributor.RoundCancelled.selector
        );
        _refused(
            "a root posted by the Guard",
            admin,
            address(d.distributor),
            abi.encodeCall(Distributor.postRoot, (4, reward.coin, NATIVE, root, 1)),
            Distributor.NotRoundKey.selector
        );
        _refused(
            "a root that owes more than its coin's pot holds",
            round,
            address(d.distributor),
            abi.encodeCall(Distributor.postRoot, (4, reward.coin, NATIVE, root, 1)),
            Distributor.RootExceedsPot.selector
        );
        _refused(
            "a cancel by anyone but the Guard",
            round,
            address(d.distributor),
            abi.encodeCall(Distributor.cancelRoot, (2)),
            Distributor.NotGuard.selector
        );
        console2.log(
            "rounds: round 1 cancelled; rounds 2 and 3 pay from", block.timestamp + d.distributor.ROUND_DELAY()
        );
    }

    // ------------------------------------------------------------------ pay

    function pay() external {
        _load();
        Distributor.Round memory third = d.distributor.roundOf(3);
        if (third.postedAt == 0) revert StepNotReady("run rounds first");
        if (block.timestamp < uint256(third.postedAt) + d.distributor.ROUND_DELAY()) {
            revert StepNotReady("the Round Delay has not run its 24 hours");
        }
        (, Distributor.Claim[] memory tax) = _roundOf(2, reward.coin, d.distributor.roundOf(2).total);
        (, Distributor.Claim[] memory earnings) = _roundOf(3, reward.coin, third.total);
        // Sorted by holder, so each holder's two rounds are one payment.
        Distributor.Claim[] memory claims = new Distributor.Claim[](4);
        (claims[0], claims[1], claims[2], claims[3]) = (tax[0], earnings[0], tax[1], earnings[1]);
        uint256 traderHeld = trader.balance;
        uint256 holderHeld = holder.balance;

        vm.broadcast(keeperKey);
        d.distributor.claim(claims);

        if (trader.balance != traderHeld + tax[0].amount + earnings[0].amount) {
            revert Unexpected("the trader's rounds");
        }
        if (holder.balance != holderHeld + tax[1].amount + earnings[1].amount) {
            revert Unexpected("the holder's rounds");
        }
        if (d.distributor.potOf(reward.coin, NATIVE) != 0 || d.distributor.earningsPotOf(reward.coin, NATIVE) != 0) {
            revert Unexpected("a pot still holds what its round paid");
        }
        console2.log("pay: each holder paid both rounds in one payment");
        console2.log("  the trader", tax[0].amount + earnings[0].amount);
        console2.log("  the holder", tax[1].amount + earnings[1].amount);
    }

    // ------------------------------------------------------------------ lock

    /// On a fork alone, where seven days can pass: the Creator claims the standard coin's Creator Lock once its
    /// cliff has run from Graduation, and the coins go to the Creator's own address.
    function lock() external {
        _load();
        StokerCreatorLock creatorLock = StokerCreatorLock(d.factory.creatorLockOf(standard.id));
        if (creatorLock.claimable() == 0) revert StepNotReady("nothing of the Creator Lock is released yet");
        uint256 held = IERC20(standard.coin).balanceOf(creator);
        uint256 amount = creatorLock.amount();
        vm.broadcast(creatorKey);
        creatorLock.claim();
        if (IERC20(standard.coin).balanceOf(creator) != held + amount || creatorLock.claimed() != amount) {
            revert Unexpected("the Creator Lock did not pay the Creator its coins");
        }
        console2.log("lock: the Creator claimed", amount);
    }

    // ------------------------------------------------------------------ report

    /// Reads the chain as it stands and checks the books: sends nothing.
    function report() external {
        _load();
        Currency[3] memory assets = [NATIVE, Currency.wrap(f.stockToken), Currency.wrap(address(dollar))];
        string[3] memory names = ["native", "stock", "dollar"];
        for (uint256 i; i < 3; i++) {
            if (!assets[i].isAddressZero() && Currency.unwrap(assets[i]).code.length == 0) continue;
            uint256 claims = pm.balanceOf(address(d.hook), assets[i].toId());
            if (claims != d.hook.totalCredits(assets[i])) {
                revert Unexpected("the hook's claims do not back its Credits");
            }
            console2.log("Credits owed and backed,", names[i], claims);
        }
        if (!_launched(standard)) return;
        Coin[4] memory coins;
        (coins[0], coins[1], coins[2], coins[3]) = (standard, reward, stoke, burner);
        uint256[3] memory waiting;
        for (uint256 i; i < 4; i++) {
            Coin memory c = coins[i];
            TaxVault.Books memory b = d.taxVault.booksOf(c.id);
            uint256 w = d.hook.taxBooked(c.id) + d.hook.openingFeeBooked(c.id) - b.burnSpent - b.supportSpent
                - b.holdersSpent + (b.burnFunded - b.burnFundedSpent) + (b.supportFunded - b.supportFundedSpent);
            waiting[c.quote == address(0) ? 0 : c.quote == f.stockToken ? 1 : 2] += w;
            StokerHook.Graduation memory g = d.hook.graduationOf(c.id);
            console2.log(c.symbol, c.coin);
            console2.log("  tier", d.hook.creatorTierOf(c.id), "graduated at", g.graduatedAt);
            console2.log("  seed liquidity", _seedLiquidity(c), "supply", IERC20(c.coin).totalSupply());
            if (_seedLiquidity(c) == 0) revert Unexpected("a Seed Position is gone");
        }
        for (uint256 i; i < 3; i++) {
            if (pm.balanceOf(address(d.taxVault), assets[i].toId()) != waiting[i]) {
                revert Unexpected("the Tax Vault's claims are not what its books say waits");
            }
        }
        uint256 pots = d.distributor.potOf(reward.coin, NATIVE) + d.distributor.earningsPotOf(reward.coin, NATIVE);
        if (address(d.distributor).balance != pots) revert Unexpected("the Distributor does not hold its pots");
        console2.log("the Distributor's pots, held in full", pots);
        StokerCreatorLock held = StokerCreatorLock(d.factory.creatorLockOf(standard.id));
        if (IERC20(standard.coin).balanceOf(address(held)) != held.amount() - held.claimed()) {
            revert Unexpected("the Creator Lock does not hold its coins");
        }
        console2.log("report: the books are whole");
    }
}
