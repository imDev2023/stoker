// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeploymentChecks} from "../../script/deployment/DeploymentChecks.sol";

/// The deployment and its gate against Robinhood Chain itself (#251): the set deployed in order from the
/// chain's own settings file, against the chain's real PoolManager at the pinned block, passes every check. The
/// file's Admin is the owner's to write, so a test address stands in for it here and nowhere else.
contract ForkDeploymentGateTest is Test, DeploymentChecks {
    /// L2 block 120,800,000, as every fork test.
    uint256 internal constant FORK_BLOCK = 120_800_000;

    function test_fork_gate_theSetDeploysFromTheChainsFileAndPassesEveryCheck() public {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        Settings memory s = _loadSettings("script/config/robinhood.json");
        assertEq(s.chainId, block.chainid, "the file is this chain's");
        assertGt(s.poolManager.code.length, 0, "the file's PoolManager is deployed on the chain");
        s.admin = makeAddr("a test Admin");
        _quietChecks = true;
        Deployment memory d = _deployStokerSet(s, address(this));
        _checkDeployment(s, _loadDecided("script/config/decided.json"), d, address(this), KeysExpected.MayBeUnappointed);
        assertEq(_checksMade, 76);
        assertEq(address(d.hook.poolManager()), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
    }
}
