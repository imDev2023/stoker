// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerTestBase} from "../utils/StokerTestBase.sol";

/// @notice The fork fixture: Robinhood Chain (4663) at one pinned block, our contracts deployed against
///         the chain's real PoolManager, with NVIDIA's Stock Token (NVDA) as the Quote Asset.
///         Needs `ROBINHOOD_RPC_URL`, an archive endpoint; CI runs these only where that secret exists.
abstract contract ForkBase is StokerTestBase {
    /// L2 block 120,800,000 (timestamp 1795370197, 2026-11-22), the spike's block, so its chain facts hold.
    uint256 internal constant FORK_BLOCK = 120_800_000;

    // Robinhood Chain mainnet addresses (Robinhood Chain knowledge base, robinhood-chain/44-uniswap-v4-hooks.md).
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    /// The Universal Router the chain's traffic uses: 478 of 507 direct router calls in 2,400 blocks
    /// sampled over the 24 hours to block 121,654,185 (2026-11-23); 28 went to the feed's v2.1.2 router
    /// (0x204F...0498) and 1 to 0x06Af...bf99.
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// Universal Router v2.1.2, the one Uniswap's feed lists: 5.8% of router swaps over the same 24 hours
    /// and growing (docs/evm/research/quote-assets-and-rehearsal.md, #249). The same six-field structs.
    address internal constant UNIVERSAL_ROUTER_V2_1_2 = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant PROTOCOL_FEE_CONTROLLER = 0x6d0009504D129CF5002Dba61D9Ae8575AA79314c;
    /// NVIDIA • Robinhood Token, an ERC-8056 Stock Token behind the shared beacon, with ERC-2612 permit.
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// The one registry every Stock Token asks about both parties of a transfer (`isBlocked(address)`).
    address internal constant STOCK_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    function setUp() public virtual {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        pm = POOL_MANAGER;
        quote = IERC20(NVDA);
        _deployStoker();
        deal(NVDA, creator, 1_000 ether);
        deal(NVDA, trader, 1_000 ether);
    }

    function _block(address who) internal {
        vm.mockCall(STOCK_REGISTRY, abi.encodeWithSignature("isBlocked(address)", who), abi.encode(true));
    }
}
