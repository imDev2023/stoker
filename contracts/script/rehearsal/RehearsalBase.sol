// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StokerDeployer} from "../deployment/StokerDeployer.sol";
import {RehearsalDollar} from "./RehearsalDollar.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {Distributor} from "../../src/Distributor.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";
import {BurnDestination} from "../../src/destinations/BurnDestination.sol";
import {LiquidityDestination} from "../../src/destinations/LiquidityDestination.sol";
import {HoldersDestination} from "../../src/destinations/HoldersDestination.sol";
import {Merkle} from "../../test/utils/Merkle.sol";
import {RouterLib, IUniversalRouter, IV4Quoter, IPermit2Allowance} from "../../test/fork/RouterLib.sol";

/// @notice What the rehearsal's steps share (#251): the deployment and the chain's settings read from their
///         files, the rehearsal's own keys read from the environment, its four coins found again from their
///         names (a coin's address follows from the factory, its Creator, its name and its salt, so no step
///         keeps a note of another's), and trading through the chain's own Universal Router and V4 Quoter.
abstract contract RehearsalBase is Script, StokerDeployer {
    using StateLibrary for IPoolManager;

    /// The rehearsal's own figures, from the `rehearsal` block of the chain's settings file.
    struct Figures {
        address universalRouter;
        address v4Quoter;
        address permit2;
        address stockToken;
        uint256 nativeOpeningValue;
        uint256 stockOpeningValue;
        uint16 smallGraduationMultiple;
        uint256 dollarOpeningValue;
        uint16 dollarGraduationMultiple;
        uint16 referrerFeeCapBps;
        uint16 rewardTaxBps;
        uint16 rewardBurnShareBps;
        uint16 rewardLiquidityShareBps;
        uint16 stokeTaxBps;
        uint16 creatorLockBps;
        uint32 creatorLockCliff;
        uint32 creatorLockUnlock;
    }

    /// One of the rehearsal's coins.
    struct Coin {
        string name;
        string symbol;
        bytes32 salt;
        address quote;
        address coin;
        PoolKey key;
        PoolId id;
    }

    Currency internal constant NATIVE = Currency.wrap(address(0));

    Settings internal s;
    Figures internal f;
    Deployment internal d;
    IPoolManager internal pm;
    RehearsalDollar internal dollar;

    uint256 internal adminKey;
    uint256 internal roundKey;
    uint256 internal ladderKey;
    uint256 internal keeperKey;
    uint256 internal creatorKey;
    uint256 internal traderKey;
    uint256 internal holderKey;
    uint256 internal issuerKey;
    address internal admin;
    address internal round;
    address internal ladder;
    address internal keeper;
    address internal creator;
    address internal trader;
    address internal holder;
    address internal issuer;

    /// The standard coin, paired with the dollar stand-in, its Creator's wallet as the Destination, with a
    /// Creator Lock; the Reward Launch, paired with the native asset, its earnings to the holders; the Stoke
    /// Launch, paired with the chain's stand-in Stock Token, its earnings to the liquidity; and a second
    /// standard coin, paired with the native asset, whose earnings burn it.
    Coin internal standard;
    Coin internal reward;
    Coin internal stoke;
    Coin internal burner;

    error StepNotReady(string why);
    error Unexpected(string what);

    function _load() internal {
        s = _loadSettings(vm.envString("CONFIG"));
        string memory json = vm.readFile(vm.envString("CONFIG"));
        f.universalRouter = vm.parseJsonAddress(json, ".rehearsal.universalRouter");
        f.v4Quoter = vm.parseJsonAddress(json, ".rehearsal.v4Quoter");
        f.permit2 = vm.parseJsonAddress(json, ".rehearsal.permit2");
        f.stockToken = vm.parseJsonAddress(json, ".rehearsal.stockToken");
        f.nativeOpeningValue = vm.parseJsonUint(json, ".rehearsal.nativeOpeningValue");
        f.stockOpeningValue = vm.parseJsonUint(json, ".rehearsal.stockOpeningValue");
        f.smallGraduationMultiple = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.smallGraduationMultiple"));
        f.dollarOpeningValue = vm.parseJsonUint(json, ".rehearsal.dollarOpeningValue");
        f.dollarGraduationMultiple = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.dollarGraduationMultiple"));
        f.referrerFeeCapBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.referrerFeeCapBps"));
        f.rewardTaxBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.rewardTaxBps"));
        f.rewardBurnShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.rewardBurnShareBps"));
        f.rewardLiquidityShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.rewardLiquidityShareBps"));
        f.stokeTaxBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.stokeTaxBps"));
        f.creatorLockBps = SafeCast.toUint16(vm.parseJsonUint(json, ".rehearsal.creatorLockBps"));
        f.creatorLockCliff = SafeCast.toUint32(vm.parseJsonUint(json, ".rehearsal.creatorLockCliff"));
        f.creatorLockUnlock = SafeCast.toUint32(vm.parseJsonUint(json, ".rehearsal.creatorLockUnlock"));

        string memory record = vm.readFile(vm.envString("DEPLOYMENT"));
        d.keys = StokerKeys(vm.parseJsonAddress(record, ".contracts.keys"));
        d.registry = QuoteRegistry(vm.parseJsonAddress(record, ".contracts.registry"));
        d.distributor = Distributor(vm.parseJsonAddress(record, ".contracts.distributor"));
        d.taxVault = TaxVault(payable(vm.parseJsonAddress(record, ".contracts.taxVault")));
        d.factory = StokerFactory(vm.parseJsonAddress(record, ".contracts.factory"));
        d.hook = StokerHook(payable(vm.parseJsonAddress(record, ".contracts.hook")));
        d.burnDestination = BurnDestination(payable(vm.parseJsonAddress(record, ".contracts.burnDestination")));
        d.liquidityDestination =
            LiquidityDestination(payable(vm.parseJsonAddress(record, ".contracts.liquidityDestination")));
        d.holdersDestination = HoldersDestination(payable(vm.parseJsonAddress(record, ".contracts.holdersDestination")));
        pm = IPoolManager(s.poolManager);

        (adminKey, admin) = _key("REHEARSAL_ADMIN_KEY");
        (roundKey, round) = _key("REHEARSAL_ROUND_KEY");
        (ladderKey, ladder) = _key("REHEARSAL_LADDER_KEY");
        (keeperKey, keeper) = _key("REHEARSAL_KEEPER_KEY");
        (creatorKey, creator) = _key("REHEARSAL_CREATOR_KEY");
        (traderKey, trader) = _key("REHEARSAL_TRADER_KEY");
        (holderKey, holder) = _key("REHEARSAL_HOLDER_KEY");
        (issuerKey, issuer) = _key("REHEARSAL_ISSUER_KEY");
        if (d.keys.admin() != admin) revert StepNotReady("the rehearsal's Admin key is not this deployment's Admin");

        // The issuer's first transaction deploys the dollar, so its address follows from the issuer's alone.
        dollar = RehearsalDollar(vm.computeCreateAddress(issuer, 0));
        // The dollar's coin sorts before it and the Stock Token's after, so both currency orders are rehearsed.
        standard = _coin("Rehearsal Standard", "RSTD", address(dollar), false);
        reward = _coin("Rehearsal Reward", "RRWD", address(0), true);
        stoke = _coin("Rehearsal Stoke", "RSTK", f.stockToken, true);
        burner = _coin("Rehearsal Burner", "RBRN", address(0), true);
    }

    function _key(string memory name) internal view returns (uint256 key, address who) {
        key = vm.envUint(name);
        who = vm.addr(key);
    }

    /// A coin of the rehearsal's, at the first salt that sorts it on the asked side of its Quote Asset.
    function _coin(string memory name, string memory symbol, address quote, bool quoteIsCurrency0)
        internal
        view
        returns (Coin memory c)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(StokerCoin).creationCode, abi.encode(name, symbol)));
        for (uint256 i = 1;; i++) {
            address coin =
                vm.computeCreate2Address(keccak256(abi.encode(creator, bytes32(i))), initHash, address(d.factory));
            if ((quote < coin) == quoteIsCurrency0) {
                c = Coin({
                    name: name,
                    symbol: symbol,
                    salt: bytes32(i),
                    quote: quote,
                    coin: coin,
                    key: PoolKey({
                        currency0: Currency.wrap(quoteIsCurrency0 ? quote : coin),
                        currency1: Currency.wrap(quoteIsCurrency0 ? coin : quote),
                        fee: 0,
                        tickSpacing: s.tickSpacing,
                        hooks: IHooks(address(d.hook))
                    }),
                    id: PoolId.wrap(bytes32(0))
                });
                c.id = c.key.toId();
                return c;
            }
        }
    }

    function _launched(Coin memory c) internal view returns (bool) {
        return c.coin.code.length != 0;
    }

    function _params(Coin memory c, address destination, uint256 firstBuy)
        internal
        pure
        returns (StokerFactory.LaunchParams memory p)
    {
        p.name = c.name;
        p.symbol = c.symbol;
        p.quote = c.quote;
        p.salt = c.salt;
        p.creatorDestination = destination;
        p.firstBuy = firstBuy;
    }

    /// An ERC-2612 permit for the factory, signed by the Creator's key.
    function _permit(address token, uint256 value) internal view returns (StokerFactory.PermitSignature memory sig) {
        sig.deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                creator,
                address(d.factory),
                value,
                IERC20Permit(token).nonces(creator),
                sig.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (sig.v, sig.r, sig.s) = vm.sign(creatorKey, digest);
    }

    // ---------------------------------------------------------------- trading as a visitor would

    function _quoteCurrency(Coin memory c) internal pure returns (Currency) {
        return Currency.wrap(c.quote);
    }

    function _quoteIs0(Coin memory c) internal pure returns (bool) {
        return Currency.unwrap(c.key.currency0) == c.quote;
    }

    function _balance(Currency asset, address who) internal view returns (uint256) {
        return asset.isAddressZero() ? who.balance : IERC20(Currency.unwrap(asset)).balanceOf(who);
    }

    /// Lets the Universal Router pull `token` from `who` through Permit2, as the site's approval does.
    function _approveRouter(uint256 key, address token) internal {
        vm.startBroadcast(key);
        IERC20(token).approve(f.permit2, type(uint256).max);
        IPermit2Allowance(f.permit2).approve(token, f.universalRouter, type(uint160).max, type(uint48).max);
        vm.stopBroadcast();
    }

    /// The Universal Router's call for one exact-in trade: the six-field struct of the router the chain's
    /// traffic uses, the Quote Asset or the coin settled, the other taken, and the native value a buy sends.
    function _routerCall(Coin memory c, bool buy, uint256 amountIn, uint256 least, bytes memory hookData)
        internal
        view
        returns (bytes memory call, uint256 value)
    {
        bool zeroForOne = buy == _quoteIs0(c);
        Currency q = _quoteCurrency(c);
        Currency coin = Currency.wrap(c.coin);
        (Currency cin, Currency cout) = buy ? (q, coin) : (coin, q);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterLib.ExactInputSingleParams(
                c.key, zeroForOne, SafeCast.toUint128(amountIn), SafeCast.toUint128(least), 0, hookData
            )
        );
        params[1] = abi.encode(cin, amountIn);
        params[2] = abi.encode(cout, least);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL), params
        );
        call = abi.encodeCall(
            IUniversalRouter.execute, (abi.encodePacked(RouterLib.V4_SWAP), inputs, block.timestamp + 1 days)
        );
        value = cin.isAddressZero() ? amountIn : 0;
    }

    /// One exact-in trade through the chain's Universal Router, its least amount out set from the chain's V4
    /// Quoter less a tenth. `hookData` names a referrer and a Referrer Fee, or nobody.
    function _swap(uint256 key, Coin memory c, bool buy, uint256 amountIn, bytes memory hookData)
        internal
        returns (uint256 quoted)
    {
        if (amountIn == 0) return 0;
        // The Quoter runs the hook in a call of its own, here in the simulation alone: nothing is sent.
        (quoted,) = IV4Quoter(f.v4Quoter)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams(c.key, buy == _quoteIs0(c), SafeCast.toUint128(amountIn), hookData)
            );
        (bytes memory call, uint256 value) = _routerCall(c, buy, amountIn, quoted * 9 / 10, hookData);
        vm.broadcast(key);
        (bool ok, bytes memory answer) = f.universalRouter.call{value: value}(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }

    /// What a buy must pay, fees and tax included, to leave the coin's price past its Graduation Target by
    /// about 3%: the seed's own arithmetic, since nothing else is in range above the price.
    function _toCrossTheTarget(Coin memory c) internal view returns (uint256 gross) {
        StokerHook.Terms memory t = d.hook.termsOf(c.id);
        (uint160 sqrtPrice,,,) = pm.getSlot0(c.id);
        uint128 liquidity = pm.getLiquidity(c.id);
        uint256 net;
        if (t.quoteIsCurrency0) {
            // The pool's price is coins per unit of the Quote Asset, so a dearer coin is a lower price.
            uint160 beyond = SafeCast.toUint160(FullMath.mulDiv(t.graduationSqrtPriceX96, 985, 1000));
            if (sqrtPrice <= beyond) return 0;
            net = SqrtPriceMath.getAmount0Delta(beyond, sqrtPrice, liquidity, true);
        } else {
            uint160 beyond = SafeCast.toUint160(FullMath.mulDiv(t.graduationSqrtPriceX96, 1015, 1000));
            if (sqrtPrice >= beyond) return 0;
            net = SqrtPriceMath.getAmount1Delta(sqrtPrice, beyond, liquidity, true);
        }
        gross = FullMath.mulDivRoundingUp(net, 10_000, 10_000 - t.platformFeeBps - t.taxBps) + 1;
    }

    function _atOrAboveTarget(Coin memory c) internal view returns (bool) {
        StokerHook.Terms memory t = d.hook.termsOf(c.id);
        (uint160 sqrtPrice,,,) = pm.getSlot0(c.id);
        return t.quoteIsCurrency0 ? sqrtPrice <= t.graduationSqrtPriceX96 : sqrtPrice >= t.graduationSqrtPriceX96;
    }

    /// Whether the Tax Vault's buys would go through now: the coin's price at or under its Reference Price.
    function _priceHasStood(Coin memory c) internal view returns (bool) {
        (, int24 tick,,) = pm.getSlot0(c.id);
        int24 referenceTick = d.hook.referenceTick(c.id);
        return _quoteIs0(c) ? tick >= referenceTick : tick <= referenceTick;
    }

    function _seedLiquidity(Coin memory c) internal view returns (uint128) {
        (int24 lower, int24 upper) = d.factory.seedRange(c.id);
        return pm.getPositionLiquidity(c.id, Position.calculatePositionKey(address(d.factory), lower, upper, 0));
    }

    // ---------------------------------------------------------------- rounds

    /// A round's two holders and what each is owed of its total: three fifths and the rest.
    function _roundOf(uint256 number, address coin, uint256 total)
        internal
        view
        returns (bytes32 root, Distributor.Claim[] memory claims)
    {
        address[2] memory who = [trader, holder];
        uint256[2] memory owed = [total * 3 / 5, total - total * 3 / 5];
        bytes32[] memory leaves = new bytes32[](2);
        for (uint256 i; i < 2; i++) {
            leaves[i] = d.distributor.leafOf(number, coin, who[i], owed[i]);
        }
        Merkle.Tree memory tree = Merkle.build(leaves);
        root = Merkle.root(tree);
        claims = new Distributor.Claim[](2);
        for (uint256 i; i < 2; i++) {
            claims[i] = Distributor.Claim(number, who[i], owed[i], Merkle.proof(tree, i));
        }
    }

    // ---------------------------------------------------------------- refusals, asked of the chain by a call

    /// A call that must be refused by a named error. It runs in this script's simulation alone, as `who`:
    /// nothing is sent, and a call that went through fails the step. The name is looked for anywhere in the
    /// revert data, since the PoolManager wraps a hook's error in its own.
    function _refused(string memory what, address who, address target, bytes memory call, bytes4 errorSelector)
        internal
    {
        _refusedWith(what, who, target, 0, call, abi.encodePacked(errorSelector));
    }

    function _refusedWith(
        string memory what,
        address who,
        address target,
        uint256 value,
        bytes memory call,
        bytes memory name
    ) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(who);
        (bool ok, bytes memory answer) = target.call{value: value}(call);
        vm.revertToState(snapshot);
        if (ok) revert Unexpected(string.concat("went through: ", what));
        if (!_contains(answer, name)) {
            console2.logBytes(answer);
            revert Unexpected(string.concat("refused, but not by the expected name: ", what));
        }
        console2.log("  refused by name:", what);
    }

    function _contains(bytes memory data, bytes memory name) internal pure returns (bool) {
        if (name.length == 0 || data.length < name.length) return false;
        for (uint256 i; i + name.length <= data.length; i++) {
            bool same = true;
            for (uint256 k; k < name.length; k++) {
                if (data[i + k] != name[k]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
