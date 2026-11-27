// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerHook} from "../../src/StokerHook.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// @notice A fourth kind of Creator Earnings Destination that exists only in the tests (#248): each coin's
///         earnings are paid on to one fixed address, a charity, and counted per coin. It is here to show
///         that a new kind is one small contract over `EarningsDestination`, added with no change to the
///         factory or the hook.
contract CharityDestination is EarningsDestination {
    address public immutable charity;
    mapping(PoolId => uint256) public givenOf;

    constructor(StokerHook hook_, address charity_) EarningsDestination(hook_) {
        charity = charity_;
    }

    function _apply(PoolKey calldata key, Currency asset, uint256 amount) internal override {
        givenOf[key.toId()] += amount;
        if (asset.isAddressZero()) {
            (bool ok,) = charity.call{value: amount}("");
            require(ok, "charity refused");
        } else {
            require(IERC20(Currency.unwrap(asset)).transfer(charity, amount), "transfer");
        }
    }
}

/// @notice Takes half of what it is approved for.
contract HalfTaker {
    function take(IERC20 token, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount / 2), "transferFrom");
    }
}

/// @notice A Destination that hands a coin's earnings to a contract that takes only half: the base's own
///         check refuses a hand-over that did not leave whole.
contract ShortHandOverDestination is EarningsDestination {
    HalfTaker public immutable taker = new HalfTaker();

    constructor(StokerHook hook_) EarningsDestination(hook_) {}

    function _apply(PoolKey calldata, Currency asset, uint256 amount) internal override {
        uint256 before = _approve(asset, address(taker), amount);
        taker.take(IERC20(Currency.unwrap(asset)), amount);
        _settled(asset, address(taker), amount, before);
    }
}

/// @notice A Destination whose work calls `applyEarnings` again, for the same coin or another, and records
///         what it met.
contract ReenteringDestination is EarningsDestination {
    PoolKey internal other;
    bool public tried;
    bytes4 public met;

    constructor(StokerHook hook_) EarningsDestination(hook_) {}

    function aim(PoolKey calldata other_) external {
        other = other_;
    }

    function _apply(PoolKey calldata, Currency, uint256) internal override {
        tried = true;
        try this.applyEarnings(other) {}
        catch (bytes memory err) {
            met = bytes4(err);
        }
    }
}

/// @notice A Credit owner that, from inside its own native payment, calls a Destination's `applyEarnings`
///         and records what the call met; then takes its payment.
contract ApplyingRecipient {
    EarningsDestination internal destination;
    PoolKey internal key;
    uint256 public attempts;
    bytes4 public met;

    function aim(EarningsDestination destination_, PoolKey calldata key_) external {
        destination = destination_;
        key = key_;
    }

    receive() external payable {
        attempts++;
        try destination.applyEarnings(key) {}
        catch (bytes memory err) {
            met = bytes4(err);
        }
    }
}
