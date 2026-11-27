// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {DeploymentChecks} from "../../script/deployment/DeploymentChecks.sol";
import {DestinationHelpers} from "../utils/DestinationHelpers.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {SeedRemover} from "../utils/SeedRemover.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";
import {WholeSetHandler} from "./WholeSetHandler.sol";

/// @notice The whole contract set, deployed exactly as `script/Deploy.s.sol` deploys it (#251): through
///         `StokerDeployer`, from Robinhood Chain's own settings file, and passed through the deployment's own
///         checks, against v4-core's PoolManager compiled from source. Then seven Launches of all three types
///         in the three pool kinds, naming each kind of Creator Earnings Destination, three of them with a
///         Creator Lock; the handler may launch three more. The helpers are the per-slice tests' own.
abstract contract WholeSetFixture is DestinationHelpers, DeploymentChecks {
    using StateLibrary for IPoolManager;

    uint256 internal constant MAX_POOLS = 10;
    /// A pool's Creator Earnings Destination: 0 the burn, 1 the liquidity, 2 the holders, 3 the Creator's wallet.
    uint256 internal constant WALLET = 3;

    WholeSetHandler internal handler;
    MockQuote internal mockQuote;
    /// A second listed asset, which the Admin's registry writes play with: no coin is launched against it.
    MockQuote internal otherQuote;
    Settings internal settings;

    PoolKey[] internal _keys;
    uint256[] internal _kinds;
    address[] internal _locks;
    uint128[] internal _seedAtLaunch;
    mapping(PoolId => uint256) internal _indexPlusOne;
    mapping(address coin => uint256) internal _coinIndexPlusOne;

    /// The Credits the launches of `setUp` booked, before the handler began to read events.
    mapping(Currency asset => uint256) internal _creditsAtSetUp;

    /// Every address a Credit can be booked to: the Creator, the Admins, the Destinations and the traders.
    address[] internal _owners;
    address internal adminTwo = makeAddr("adminTwo");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        pm = new PoolManager(address(this));
        mockQuote = new MockQuote();
        otherQuote = new MockQuote();
        quote = IERC20(address(mockQuote));
        (creator, creatorKey) = makeAddrAndKey("creator");
        swapRouter = new PoolSwapTest(pm);

        // The chain's own settings, with the two facts a local run cannot share: the PoolManager and the Admin.
        settings = _loadSettings("script/config/robinhood.json");
        settings.chainId = block.chainid;
        settings.poolManager = address(pm);
        settings.admin = platform;
        _quietChecks = true;
        Deployment memory d = _deployStokerSet(settings, address(this));
        _checkDeployment(
            settings, _loadDecided("script/config/decided.json"), d, address(this), KeysExpected.MayBeUnappointed
        );
        (keys, registry, distributor, taxVault) = (d.keys, d.registry, d.distributor, d.taxVault);
        (factory, hook) = (d.factory, d.hook);
        (burnDestination, liquidityDestination, holdersDestination) =
        (d.burnDestination, d.liquidityDestination, d.holdersDestination);

        // What the Admin does first, as on a chain: the three server keys, each by its two steps, and the Listings.
        _appoint(StokerKeys.Role.RoundKey, roundKey);
        _appoint(StokerKeys.Role.LadderKey, ladderKey);
        _appoint(StokerKeys.Role.Keeper, keeper);
        vm.startPrank(platform);
        registry.list(address(quote), START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        registry.list(address(0), NATIVE_START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        registry.list(address(otherQuote), START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        vm.stopPrank();

        // A campaign trades inside the Opening Fee's seconds too, so no launch moves the clock past them.
        _tradeInOpening = true;
        _topCreator();
        _owners.push(creator);
        _owners.push(platform);
        _owners.push(adminTwo);
        _owners.push(address(burnDestination));
        _owners.push(address(liquidityDestination));
        _owners.push(address(holdersDestination));

        StokerHook.LaunchType standard = StokerHook.LaunchType.Standard;
        StokerHook.LaunchType reward = StokerHook.LaunchType.Reward;
        StokerHook.LaunchType stoke = StokerHook.LaunchType.Liquidity;
        StokerHook.PayoutAsset inQuote = StokerHook.PayoutAsset.QuoteAsset;
        _launchOne(standard, QUOTE_FIRST, WALLET, 0, 0, 0, inQuote, 2_000, 1 ether);
        _launchOne(standard, COIN_FIRST, 0, 0, 0, 0, inQuote, 0, 0);
        _launchOne(reward, NATIVE_PAIR, 2, 300, 2_500, 2_500, inQuote, 0, 0.01 ether);
        _launchOne(reward, COIN_FIRST, WALLET, 500, 1_000, 0, StokerHook.PayoutAsset.Coin, 1_000, 0);
        _launchOne(stoke, QUOTE_FIRST, 1, 300, 0, 0, inQuote, 0, 0);
        _launchOne(stoke, NATIVE_PAIR, 0, 500, 0, 0, inQuote, 0, 0);
        _launchOne(standard, NATIVE_PAIR, 1, 0, 0, 0, inQuote, 500, 0);

        _creditsAtSetUp[mockCurrency()] = hook.totalCredits(mockCurrency());
        _creditsAtSetUp[NATIVE] = hook.totalCredits(NATIVE);
        handler = new WholeSetHandler(this);
        address[4] memory traders = handler.actorList();
        for (uint256 i; i < traders.length; i++) {
            _owners.push(traders[i]);
        }
        _seed();
        targetContract(address(handler));
    }

    /// Where every run of a campaign starts: not from seven coins nobody has traded, from which a run of a
    /// hundred calls seldom reaches a paid round or a raise, but from a market already under way. Made through
    /// the handler's own calls, so everything is in its books: buys inside five coins' opening seconds; a
    /// minute later a round trip in every pool; the holders' Destination's work and the holders' part passed
    /// on, so two pots are filled; two coins with a Creator Lock bought past their Graduation Targets; and then
    /// an hour, so their Graduation is recorded by the first call that swaps them or asks.
    ///
    /// `setUp` is one transaction, and the hook judges a pool's hold once per transaction, by its first swap.
    /// So the two coins lifted here are ones that have not swapped before the minute passes (no First Buy, no
    /// opening buy): their first swap, their lift and the model's note of it then fall in the same second, as
    /// they would in transactions of their own.
    function _seed() internal {
        uint256[5] memory opening = [uint256(0), 1, 2, 4, 5];
        for (uint256 i; i < opening.length; i++) {
            handler.trade(opening[i], i, true, true, 5 ether, 1);
        }
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        for (uint256 k; k < _keys.length; k++) {
            handler.buyThenSell(k, k + 1, 5 ether);
        }
        handler.trade(1, 0, true, true, 5 ether, 4 + 16 * 50);
        handler.applyOwn(2);
        handler.passHoldersPart(2);
        handler.lift(3, 0);
        handler.lift(6, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    function _appoint(StokerKeys.Role role, address who) internal {
        vm.prank(keys.admin());
        keys.proposeKey(role, who);
        vm.prank(who);
        keys.acceptKey(role);
    }

    function _topCreator() internal {
        if (quote.balanceOf(creator) < 1_000 ether) mockQuote.mint(creator, 100_000 ether);
        if (creator.balance < 100 ether) vm.deal(creator, 10_000 ether);
    }

    function _top(address who) internal {
        if (quote.balanceOf(who) < 10_000 ether && !mockQuote.isBlocked(who)) mockQuote.mint(who, 1_000_000 ether);
        if (who.balance < 1_000 ether) vm.deal(who, 100_000 ether);
    }

    function _launchOne(
        StokerHook.LaunchType launchType,
        uint256 poolKind,
        uint256 destinationKind,
        uint16 taxBps,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        StokerHook.PayoutAsset payoutAsset,
        uint16 lockBps,
        uint256 firstBuy
    ) internal returns (uint256 k) {
        StokerFactory.LaunchParams memory p = _typedParams(
            poolKind == NATIVE_PAIR ? address(0) : address(quote),
            poolKind == QUOTE_FIRST,
            firstBuy,
            launchType,
            taxBps,
            burnShareBps,
            liquidityShareBps,
            payoutAsset
        );
        p.creatorDestination = destinationKind == 0
            ? address(burnDestination)
            : destinationKind == 1
                ? address(liquidityDestination)
                : destinationKind == 2 ? address(holdersDestination) : address(0);
        if (lockBps != 0) {
            p.creatorLockBps = lockBps;
            p.creatorLockCliff = 3 days;
            p.creatorLockUnlock = 4 days;
        }
        (address coin, PoolKey memory key) = _launchWith(p);
        k = _keys.length;
        _keys.push(key);
        _kinds.push(destinationKind);
        _locks.push(factory.creatorLockOf(key.toId()));
        _seedAtLaunch.push(_seedLiquidity(key));
        _indexPlusOne[key.toId()] = k + 1;
        _coinIndexPlusOne[coin] = k + 1;
    }

    // ------------------------------------------------ the handler's window onto the fixture

    function poolCount() public view returns (uint256) {
        return _keys.length;
    }

    function maxPools() external pure returns (uint256) {
        return MAX_POOLS;
    }

    function keyOf(uint256 k) public view returns (PoolKey memory) {
        return _keys[k];
    }

    function idOf(uint256 k) public view returns (PoolId) {
        return _keys[k].toId();
    }

    /// A pool's index by its id, or by its coin; `poolCount()` for one that is not a pool of the campaign's.
    function indexOf(PoolId id) external view returns (uint256) {
        uint256 i = _indexPlusOne[id];
        return i == 0 ? _keys.length : i - 1;
    }

    function indexOfCoin(address coin) external view returns (uint256) {
        uint256 i = _coinIndexPlusOne[coin];
        return i == 0 ? _keys.length : i - 1;
    }

    function coinOf(uint256 k) public view returns (address) {
        return address(_coinOfKey(_keys[k]));
    }

    function quoteOf(uint256 k) public view returns (Currency) {
        return _quoteOfKey(_keys[k]);
    }

    function unitOf(uint256 k) public view returns (uint256) {
        return _unit(_keys[k]);
    }

    function kindOf(uint256 k) external view returns (uint256) {
        return _kinds[k];
    }

    function lockOf(uint256 k) public view returns (address) {
        return _locks[k];
    }

    function seedAtLaunch(uint256 k) external view returns (uint128) {
        return _seedAtLaunch[k];
    }

    function seedNow(uint256 k) public view returns (uint128) {
        return _seedLiquidity(_keys[k]);
    }

    function supportNow(uint256 k, int24 lower, int24 upper) public view returns (uint128) {
        return pm.getPositionLiquidity(
            _keys[k].toId(), Position.calculatePositionKey(address(taxVault), lower, upper, bytes32(0))
        );
    }

    function ownerCount() public view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 i) public view returns (address) {
        return _owners[i];
    }

    function creatorAddr() external view returns (address) {
        return creator;
    }

    function strangerAddr() external view returns (address) {
        return stranger;
    }

    function adminTwoAddr() external view returns (address) {
        return adminTwo;
    }

    function mockCurrency() public view returns (Currency) {
        return Currency.wrap(address(quote));
    }

    function otherQuoteAddr() external view returns (address) {
        return address(otherQuote);
    }

    function destinationAt(uint256 i) public view returns (EarningsDestination) {
        if (i == 0) return EarningsDestination(payable(address(burnDestination)));
        if (i == 1) return EarningsDestination(payable(address(liquidityDestination)));
        return EarningsDestination(payable(address(holdersDestination)));
    }

    function contracts()
        external
        view
        returns (
            address hook_,
            address vault_,
            address distributor_,
            address keys_,
            address registry_,
            address factory_
        )
    {
        return (
            address(hook), address(taxVault), address(distributor), address(keys), address(registry), address(factory)
        );
    }

    function balanceIn(Currency asset, address who) public view returns (uint256) {
        return _balance(asset, who);
    }

    function atOrAboveTarget(uint256 k) public view returns (bool) {
        StokerHook.Terms memory terms = hook.termsOf(_keys[k].toId());
        (uint160 sqrtPrice,,,) = pm.getSlot0(_keys[k].toId());
        return
            terms.quoteIsCurrency0
                ? sqrtPrice <= terms.graduationSqrtPriceX96
                : sqrtPrice >= terms.graduationSqrtPriceX96;
    }

    /// What the handler notes of a pool after every call: whether its price stands at or above its Graduation
    /// Target, its recorded Graduation, and its Creator Tier.
    function observe(uint256 k) external view returns (bool above, uint256 graduatedAt, uint8 tier) {
        PoolId id = _keys[k].toId();
        return (atOrAboveTarget(k), hook.graduationOf(id).graduatedAt, hook.creatorTierOf(id));
    }

    /// Whether a pool is a Reward Launch's, and whether its holders are paid in the coin.
    function rewardOf(uint256 k) external view returns (bool reward, bool inTheCoin) {
        StokerHook.Terms memory terms = hook.termsOf(_keys[k].toId());
        return (terms.launchType == StokerHook.LaunchType.Reward, terms.payoutAsset == StokerHook.PayoutAsset.Coin);
    }

    function setBlocked(address who, bool blocked) external {
        mockQuote.setBlocked(who, blocked);
    }

    /// One trade through the test router as `who`, of any of the four kinds, carrying the trade's `hookData`.
    function tradeAs(uint256 k, address who, bool buy, bool exactIn, uint256 amount, bytes calldata hookData) external {
        _top(who);
        PoolKey memory key = _keys[k];
        if (_native(key)) {
            vm.prank(who);
            IERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
            _swapNativeWithData(
                key,
                who,
                buy,
                exactIn,
                amount,
                who.balance,
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                hookData
            );
        } else {
            _approveRouter(key, who);
            bool zeroForOne = buy == _isQuote0(key);
            _swapWithData(
                key,
                who,
                buy,
                exactIn,
                amount,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                hookData
            );
        }
    }

    /// What an exact-in buy must pay, fees included, to leave the coin's price about 3% past its Graduation
    /// Target; zero when it stands there already.
    function toCross(uint256 k) public view returns (uint256) {
        PoolId id = _keys[k].toId();
        StokerHook.Terms memory terms = hook.termsOf(id);
        (uint160 sqrtPrice,,,) = pm.getSlot0(id);
        uint128 liquidity = pm.getLiquidity(id);
        uint256 net;
        if (terms.quoteIsCurrency0) {
            uint160 beyond = SafeCast.toUint160(FullMath.mulDiv(terms.graduationSqrtPriceX96, 985, 1000));
            if (sqrtPrice <= beyond) return 0;
            net = SqrtPriceMath.getAmount0Delta(beyond, sqrtPrice, liquidity, true);
        } else {
            uint160 beyond = SafeCast.toUint160(FullMath.mulDiv(terms.graduationSqrtPriceX96, 1015, 1000));
            if (sqrtPrice >= beyond) return 0;
            net = SqrtPriceMath.getAmount1Delta(sqrtPrice, beyond, liquidity, true);
        }
        // Inside a Launch's first seconds the Opening Fee takes most of a buy, and this would fall short: the
        // caller then finds the price under the target and does nothing.
        return FullMath.mulDivRoundingUp(net, 10_000, 10_000 - terms.platformFeeBps - terms.taxBps) + 1;
    }

    /// A Launch made in the middle of a campaign, of the type, pool kind and Destination the seeds choose.
    function launchNew(uint256 typeSeed, uint256 kindSeed, uint256 destinationSeed, bool withLock, uint256 firstBuySeed)
        external
        returns (uint256 k)
    {
        require(_keys.length < MAX_POOLS, "the campaign's pools are all launched");
        _topCreator();
        uint256 poolKind = kindSeed % 3;
        uint256 firstBuy = firstBuySeed % 3 == 0 ? 0 : (poolKind == NATIVE_PAIR ? 0.01 ether : 1 ether);
        uint16 lockBps = withLock ? 1_500 : 0;
        StokerHook.PayoutAsset inQuote = StokerHook.PayoutAsset.QuoteAsset;
        if (typeSeed % 3 == 0) {
            return _launchOne(
                StokerHook.LaunchType.Standard, poolKind, destinationSeed % 4, 0, 0, 0, inQuote, lockBps, firstBuy
            );
        }
        if (typeSeed % 3 == 1) {
            return _launchOne(
                StokerHook.LaunchType.Reward,
                poolKind,
                destinationSeed % 4,
                uint16(100 * (1 + (typeSeed / 3) % 5)),
                typeSeed % 2 == 0 ? 2_500 : 0,
                1_000,
                (typeSeed / 16) % 2 == 0 ? inQuote : StokerHook.PayoutAsset.Coin,
                lockBps,
                firstBuy
            );
        }
        return _launchOne(
            StokerHook.LaunchType.Liquidity,
            poolKind,
            destinationSeed % 4,
            uint16(100 * (1 + (typeSeed / 3) % 5)),
            0,
            0,
            inQuote,
            lockBps,
            firstBuy
        );
    }

    function fundAs(uint256 k, address who, bool burn, uint256 amount) external {
        _top(who);
        PoolKey memory key = _keys[k];
        bool isNative = _native(key);
        vm.startPrank(who);
        if (!isNative) quote.approve(address(taxVault), amount);
        if (burn) taxVault.fundBurn{value: isNative ? amount : 0}(key, amount);
        else taxVault.fundSupport{value: isNative ? amount : 0}(key, amount);
        vm.stopPrank();
    }

    /// A Keeper's Payout Call in one asset for every address a Credit can be booked to, under a Keeper's gas.
    function payoutAll(Currency asset, address caller) external {
        vm.prank(caller);
        hook.payout{gas: 2_000_000}(asset, _owners);
    }

    /// Code that tries to remove liquidity, put at the address that owns the position (the factory for a Seed
    /// Position, the Tax Vault for Support Liquidity), since v4 lets only a position's owner lower it. The
    /// owner's own code is put back afterwards, whatever happened. Only the hook's refusal stops it.
    function removeAs(address positionOwner, uint256 k, int24 lower, int24 upper, uint256 liquidity)
        external
        returns (bool removed)
    {
        bytes memory own = positionOwner.code;
        vm.etch(positionOwner, address(new SeedRemover(pm)).code);
        try SeedRemover(positionOwner).remove(_keys[k], lower, upper, SafeCast.toInt256(liquidity)) {
            removed = true;
        } catch {}
        vm.etch(positionOwner, own);
    }

    function seedRangeOf(uint256 k) external view returns (int24 lower, int24 upper) {
        return factory.seedRange(_keys[k].toId());
    }

    /// Everything no key of ours may move, in one hash: every Credit, every Seed Position and every Support
    /// Liquidity position the caller names, every Creator Lock's coins and claims, every Launch's terms and
    /// its record of Graduation, the Tax Vault's books and the Distributor's pots. A coin's Creator Tier is
    /// left out: raising it is the ladder key's one power.
    function fingerprint(bytes32 supportDigest) external view returns (bytes32 h) {
        h = supportDigest;
        Currency[2] memory assets = [mockCurrency(), NATIVE];
        for (uint256 i; i < _owners.length; i++) {
            for (uint256 a; a < 2; a++) {
                h = keccak256(abi.encode(h, hook.creditOf(_owners[i], assets[a]), _balance(assets[a], _owners[i])));
            }
        }
        for (uint256 k; k < _keys.length; k++) {
            PoolId id = _keys[k].toId();
            address coin = coinOf(k);
            Currency asset = quoteOf(k);
            h = keccak256(
                abi.encode(
                    h,
                    seedNow(k),
                    abi.encode(hook.termsOf(id)),
                    hook.graduationOf(id).graduatedAt,
                    hook.creatorCreditedOf(id),
                    hook.taxBooked(id),
                    abi.encode(taxVault.booksOf(id))
                )
            );
            h = keccak256(
                abi.encode(
                    h,
                    distributor.potOf(coin, asset),
                    distributor.earningsPotOf(coin, asset),
                    distributor.potOf(coin, Currency.wrap(coin)),
                    IERC20(coin).balanceOf(creator)
                )
            );
            if (_locks[k] != address(0)) {
                h = keccak256(abi.encode(h, IERC20(coin).balanceOf(_locks[k]), StokerCreatorLock(_locks[k]).claimed()));
            }
        }
    }
}
