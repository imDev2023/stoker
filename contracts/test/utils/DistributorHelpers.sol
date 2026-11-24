// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor} from "../../src/Distributor.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {StokerTestBase} from "./StokerTestBase.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {Merkle} from "./Merkle.sol";

/// @notice What the Distributor's local and fork tests share (#247): deploying it beside the real Tax Vault,
///         each knowing the other's address, naming the round key, filling a coin's pot, and posting and
///         claiming Reward Rounds the way the Reward Engine and the Keeper will.
abstract contract DistributorHelpers is StokerTestBase {
    Distributor internal distributor;
    address internal roundKey = makeAddr("roundKey");

    /// A round built off-chain: its holders, what each is owed, and each one's proof.
    struct Built {
        uint256 round;
        address coin;
        Currency asset;
        address[] holders;
        uint256[] amounts;
        bytes32[][] proofs;
        bytes32 root;
        uint256 total;
    }

    /// The base deploys the Distributor in the stand-in's place, against its `StokerKeys`, for the Tax
    /// Vault's address it computed: the vault deployed next fixes this Distributor's address in turn.
    function _deployHoldersPart(address taxVault_) internal virtual override returns (IHoldersPart) {
        distributor = new Distributor(keys, taxVault_);
        return distributor;
    }

    /// Checks that the Distributor and the Tax Vault each know the other, and names the round key through
    /// the Admin's two steps.
    function _deployDistributor() internal {
        assertEq(distributor.taxVault(), address(taxVault), "the Distributor knows the Tax Vault");
        assertEq(address(taxVault.distributor()), address(distributor), "the Tax Vault knows the Distributor");
        _setRoundKey(roundKey);
    }

    function _setRoundKey(address who) internal {
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.RoundKey, who);
        vm.prank(who);
        keys.acceptKey(StokerKeys.Role.RoundKey);
    }

    /// Hands `amount` of `asset` to the Distributor for `coin` from the Tax Vault's address, exactly as
    /// `TaxVault._deposit` does: the native asset as value; an ERC-20 approved for exactly the amount and
    /// pulled by the Distributor inside the call, the allowance cleared after. The fork's
    /// `ForkDistributorTax.t.sol` fills pots through the vault's own calls from real trades instead.
    function _fund(address coin, Currency asset, uint256 amount) internal {
        _fundAs(distributor, address(taxVault), coin, asset, amount);
    }

    function _fundAs(Distributor d, address depositor, address coin, Currency asset, uint256 amount) internal {
        vm.startPrank(depositor);
        if (asset.isAddressZero()) {
            vm.deal(depositor, depositor.balance + amount);
            d.deposit{value: amount}(coin, asset, amount);
        } else {
            IERC20 token = IERC20(Currency.unwrap(asset));
            deal(address(token), depositor, token.balanceOf(depositor) + amount);
            token.approve(address(d), amount);
            d.deposit(coin, asset, amount);
            token.approve(address(d), 0);
        }
        vm.stopPrank();
    }

    /// The leaf as the Reward Engine computes it, written here apart from the contract: the chain, the
    /// Distributor, the coin, the round, the holder and the amount, ABI-encoded and hashed twice
    /// (OpenZeppelin's standard leaf).
    function _leaf(Distributor d, address coin, uint256 round, address holder, uint256 amount)
        internal
        view
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(d), coin, round, holder, amount))));
    }

    /// Builds the next round's tree for `holders` and `amounts`, without posting it.
    function _build(address coin, Currency asset, address[] memory holders, uint256[] memory amounts)
        internal
        view
        returns (Built memory b)
    {
        return _buildFor(distributor, distributor.roundCount() + 1, coin, asset, holders, amounts);
    }

    function _buildFor(
        Distributor d,
        uint256 round,
        address coin,
        Currency asset,
        address[] memory holders,
        uint256[] memory amounts
    ) internal view returns (Built memory b) {
        b.round = round;
        b.coin = coin;
        b.asset = asset;
        b.holders = holders;
        b.amounts = amounts;
        bytes32[] memory leaves = new bytes32[](holders.length);
        for (uint256 i; i < holders.length; i++) {
            leaves[i] = _leaf(d, coin, round, holders[i], amounts[i]);
            b.total += amounts[i];
        }
        Merkle.Tree memory tree = Merkle.build(leaves);
        b.root = Merkle.root(tree);
        b.proofs = new bytes32[][](holders.length);
        for (uint256 i; i < holders.length; i++) {
            b.proofs[i] = Merkle.proof(tree, i);
        }
    }

    /// Builds the next round and posts it as the round key, for exactly the sum it owes.
    function _post(address coin, Currency asset, address[] memory holders, uint256[] memory amounts)
        internal
        returns (Built memory b)
    {
        b = _build(coin, asset, holders, amounts);
        vm.prank(roundKey);
        distributor.postRoot(b.round, coin, asset, b.root, b.total);
    }

    /// Every holder's claim in a built round, in order.
    function _claims(Built memory b) internal pure returns (Distributor.Claim[] memory c) {
        c = new Distributor.Claim[](b.holders.length);
        for (uint256 i; i < b.holders.length; i++) {
            c[i] = _claimAt(b, i);
        }
    }

    function _claimAt(Built memory b, uint256 i) internal pure returns (Distributor.Claim memory) {
        return Distributor.Claim({round: b.round, holder: b.holders[i], amount: b.amounts[i], proof: b.proofs[i]});
    }

    function _one(Distributor.Claim memory c) internal pure returns (Distributor.Claim[] memory a) {
        a = new Distributor.Claim[](1);
        a[0] = c;
    }

    /// `n` fresh holders, named from `tag`, owed `base`, `2 * base`, ... in turn.
    function _holders(string memory tag, uint256 n, uint256 base)
        internal
        returns (address[] memory holders, uint256[] memory amounts)
    {
        holders = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; i++) {
            holders[i] = makeAddr(string.concat(tag, vm.toString(i)));
            amounts[i] = base * (i + 1);
        }
    }

    function _pair(address a, uint256 x, address b, uint256 y)
        internal
        pure
        returns (address[] memory holders, uint256[] memory amounts)
    {
        holders = new address[](2);
        amounts = new uint256[](2);
        (holders[0], holders[1], amounts[0], amounts[1]) = (a, b, x, y);
    }

    function _single(address a, uint256 x) internal pure returns (address[] memory holders, uint256[] memory amounts) {
        holders = new address[](1);
        amounts = new uint256[](1);
        (holders[0], amounts[0]) = (a, x);
    }

    function _balance(Currency asset, address who) internal view returns (uint256) {
        return asset.isAddressZero() ? who.balance : IERC20(Currency.unwrap(asset)).balanceOf(who);
    }

    function _payableAt(uint256 round) internal view returns (uint256) {
        return distributor.roundOf(round).postedAt + distributor.ROUND_DELAY();
    }

    function _warpPastDelay(uint256 round) internal {
        vm.warp(_payableAt(round));
    }
}
