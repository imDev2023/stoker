// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Distributor} from "../../src/Distributor.sol";
import {ForkDistributorBase} from "./ForkDistributorBase.sol";
import {Merkle} from "../utils/Merkle.sol";

/// The gas of a pushed claim and of a holder's own first claim (#247), measured as #232 measured its
/// minimal distributor (`docs/evm/research/robinhood-chain.md`, section 5): a round of 16,384 holders,
/// every account and slot the claim touches cold, holders with no prior balance, and each total counting
/// the 21,000 base and the calldata's gas beside the execution. The figures are logged and bounded, so a
/// change that makes a claim much dearer fails here.
contract ForkDistributorGasTest is ForkDistributorBase {
    uint256 internal constant HOLDERS = 16_384;
    uint256 internal constant PUSHED = 50;
    /// NVDA's beacon implementation (`docs/evm/research/robinhood-chain.md`): the proxy delegates to it on
    /// every transfer, after reading the beacon, which is the registry.
    address internal constant NVDA_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    struct Tree {
        address[] holders;
        uint256[] amounts;
        bytes32[][] levels;
        uint256 round;
    }

    function test_fork_gas_nvda() public {
        (uint256 pushed, uint256 first) = _measure(NVDA_ASSET, coinA);
        emit log_named_uint("NVDA: one pushed claim, of a batch of 50", pushed);
        emit log_named_uint("NVDA: a holder's own first claim", first);
        // #232's minimal distributor: 88,648 and 152,233. Ours binds more in the leaf and keeps a pot.
        assertLt(pushed, 110_000);
        assertLt(first, 175_000);
    }

    function test_fork_gas_eth() public {
        (uint256 pushed, uint256 first) = _measure(ETH, coinN);
        emit log_named_uint("ETH: one pushed claim, of a batch of 50", pushed);
        emit log_named_uint("ETH: a holder's own first claim", first);
        // #232's minimal distributor: 87,228 and 129,005.
        assertLt(pushed, 110_000);
        assertLt(first, 150_000);
    }

    /// Posts a round of 16,384 holders in `asset` for `coin`, then measures a Keeper's batch of the first
    /// 50 and the 51st holder's own claim.
    function _measure(Currency asset, address coin) internal returns (uint256 perPushed, uint256 firstOwn) {
        Tree memory t = _tree(coin);
        uint256 total;
        for (uint256 i; i < HOLDERS; i++) {
            total += t.amounts[i];
        }
        _fund(coin, asset, total);
        vm.prank(roundKey);
        distributor.postRoot(t.round, coin, asset, Merkle.root(t.levels), total);
        _warpPastDelay(t.round);

        Distributor.Claim[] memory batch = new Distributor.Claim[](PUSHED);
        for (uint256 i; i < PUSHED; i++) {
            batch[i] = Distributor.Claim(t.round, t.holders[i], t.amounts[i], Merkle.proof(t.levels, i));
        }
        address keeper = makeAddr("keeper");
        _coolEverything(asset);
        vm.prank(keeper);
        distributor.claim{gas: 10_000_000}(batch);
        perPushed = _txGas(abi.encodeCall(Distributor.claim, (batch))) / PUSHED;
        for (uint256 i; i < PUSHED; i++) {
            assertEq(_balance(asset, t.holders[i]), t.amounts[i]);
        }

        Distributor.Claim[] memory own = new Distributor.Claim[](1);
        own[0] = Distributor.Claim(t.round, t.holders[PUSHED], t.amounts[PUSHED], Merkle.proof(t.levels, PUSHED));
        _coolEverything(asset);
        vm.prank(t.holders[PUSHED]);
        distributor.claim{gas: 10_000_000}(own);
        firstOwn = _txGas(abi.encodeCall(Distributor.claim, (own)));
        assertEq(_balance(asset, t.holders[PUSHED]), t.amounts[PUSHED]);
    }

    function _tree(address coin) internal view returns (Tree memory t) {
        t.round = distributor.roundCount() + 1;
        t.holders = new address[](HOLDERS);
        t.amounts = new uint256[](HOLDERS);
        bytes32[] memory leaves = new bytes32[](HOLDERS);
        for (uint256 i; i < HOLDERS; i++) {
            t.holders[i] = address(uint160(uint256(keccak256(abi.encode("gas holder", i)))));
            t.amounts[i] = 1e12 + i;
            leaves[i] = _leaf(distributor, coin, t.round, t.holders[i], t.amounts[i]);
        }
        t.levels = Merkle.levels(leaves);
    }

    /// Marks every account and slot the claim touches cold, as in a fresh transaction.
    function _coolEverything(Currency asset) internal {
        vm.cool(address(distributor));
        vm.cool(address(keys));
        if (!asset.isAddressZero()) {
            vm.cool(Currency.unwrap(asset));
            vm.cool(STOCK_REGISTRY);
            vm.cool(NVDA_IMPLEMENTATION);
        }
    }

    /// The last call's execution gas plus the transaction's 21,000 and its calldata (16 a non-zero byte,
    /// 4 a zero byte), as #232 counted.
    function _txGas(bytes memory data) internal view returns (uint256 gas) {
        Vm.Gas memory g = vm.lastCallGas();
        gas = 21_000 + g.gasTotalUsed;
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }
}
