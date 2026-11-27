// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {DeploymentChecks} from "../../script/deployment/DeploymentChecks.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {Distributor} from "../../src/Distributor.sol";

/// The deployment's gate, tested as a gate (#251): the set deployed in order from the chain's settings passes
/// every check, and each mistake a deployment could carry for good is refused by the check that names it. A
/// check that could not fail would be decoration, so each test makes one mistake and reads the failure's name.
contract DeploymentGateTest is Test, DeploymentChecks {
    Settings internal s;
    Decided internal f;
    address internal admin = makeAddr("admin");
    address internal round = makeAddr("round");
    address internal ladder = makeAddr("ladder");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        s = _loadSettings("script/config/robinhood.json");
        f = _loadDecided("script/config/decided.json");
        // The two facts a local run cannot share with the chain: its PoolManager and its Admin.
        s.chainId = block.chainid;
        s.poolManager = address(new PoolManager(address(this)));
        s.admin = admin;
        _quietChecks = true;
    }

    function _failed(string memory what) internal view returns (bool) {
        for (uint256 i; i < _failures.length; i++) {
            if (keccak256(bytes(_failures[i])) == keccak256(bytes(what))) return true;
        }
        return false;
    }

    function _appoint(Deployment memory d, StokerKeys.Role role, address who) internal {
        vm.prank(admin);
        d.keys.proposeKey(role, who);
        vm.prank(who);
        d.keys.acceptKey(role);
    }

    function _run(Deployment memory d, KeysExpected keysExpected) internal returns (uint256) {
        return _runChecks(s, f, d, address(this), keysExpected);
    }

    // ---------------------------------------------------------------- the settings files

    /// Mainnet's file carries no Admin until the owner writes the hardware wallet's address there, and a
    /// deployment without one is refused before anything is created.
    function test_gate_noDeploymentWithoutAnAdmin() public {
        Settings memory fromFile = _loadSettings("script/config/robinhood.json");
        assertEq(fromFile.admin, address(0), "mainnet's Admin is the owner's to write");
        fromFile.poolManager = s.poolManager;
        vm.expectRevert(NoAdmin.selector);
        this.deployExternally(fromFile);
    }

    function deployExternally(Settings memory settings_) external returns (Deployment memory) {
        return _deployStokerSet(settings_, address(this));
    }

    /// The rehearsal deploys what mainnet will: the testnet's file carries the same figure for every setting,
    /// and both carry the figures the ADRs fix.
    function test_gate_theChainFilesCarryTheSameFigures_andTheDecidedOnes() public view {
        Settings memory main = _loadSettings("script/config/robinhood.json");
        Settings memory test = _loadSettings("script/config/robinhood-testnet.json");
        assertEq(main.chainId, 4663);
        assertEq(test.chainId, 46630);
        assertTrue(test.admin != address(0), "the rehearsal's test Admin");
        // Every setting but the chain's own facts.
        (main.chainId, main.name, main.admin) = (test.chainId, test.name, test.admin);
        assertEq(keccak256(abi.encode(main)), keccak256(abi.encode(test)), "the two files differ in a setting");
        assertEq(main.platformFeeBps, f.platformFeeBps);
        assertEq(main.creatorShareBps, f.creatorShareBps);
        assertEq(main.secondTierShareBps, f.secondTierShareBps);
        assertEq(main.topTierShareBps, f.topTierShareBps);
        assertEq(main.pieceBps, f.pieceBps);
        // The figures as they were reviewed (contracts/README.md): a change here is a change to say in a PR.
        assertEq(main.platformFeeBps, 100);
        assertEq(main.creatorShareBps, 5_000);
        assertEq(main.secondTierShareBps, 6_000);
        assertEq(main.topTierShareBps, 7_000);
        assertEq(main.pieceBps, 50);
        assertEq(main.pieceInterval, 60);
        assertEq(main.supportWidthSpacings, 10);
        assertEq(main.referenceRiseTicksPerMinute, 2);
        assertEq(main.referenceFallTicksPerMinute, 60_000);
        assertEq(main.buyBandTicks, 0);
        assertEq(main.openingFeeStartBps, 9_900);
        assertEq(main.openingFeeDuration, 20);
        assertEq(main.tickSpacing, 200);
        assertEq(f.roundDelay, 24 hours);
        assertEq(f.graduationHold, 1 hours);
    }

    // ---------------------------------------------------------------- the set as deployed

    function test_gate_theSetAsDeployedPassesEveryCheck() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertEq(_checksMade, 76);
        // Before the Admin has appointed them, the stricter check says which keys nobody holds.
        assertEq(_run(d, KeysExpected.AllAppointed), 3);
        assertTrue(_failed("the round key is held"));
        assertTrue(_failed("the ladder key is held"));
        assertTrue(_failed("the Keeper is held"));
        _appoint(d, StokerKeys.Role.RoundKey, round);
        _appoint(d, StokerKeys.Role.LadderKey, ladder);
        _appoint(d, StokerKeys.Role.Keeper, keeper);
        assertEq(_run(d, KeysExpected.AllAppointed), 0);
        assertEq(_checksMade, 79);
        _checkDeployment(s, f, d, address(this), KeysExpected.AllAppointed);
    }

    function test_gate_aFailureRevertsTheScript() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        d.hookSalt = bytes32(uint256(d.hookSalt) + 1);
        vm.expectRevert(abi.encodeWithSelector(DeploymentChecksFailed.selector, 1));
        this.checkExternally(d);
    }

    function checkExternally(Deployment memory d) external {
        _checkDeployment(s, f, d, address(this), KeysExpected.MayBeUnappointed);
    }

    // ---------------------------------------------------------------- what nothing in the contracts checks

    /// The Distributor is deployed before the Tax Vault, for an address computed ahead. One made for another
    /// address would refuse every deposit of the holders' part for good, and no constructor would say so.
    function test_gate_aDistributorMadeForAnotherVaultIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        d.distributor = new Distributor(d.keys, makeAddr("anotherVault"));
        assertGt(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertTrue(_failed("distributor.taxVault() is the real Tax Vault"));
        assertTrue(_failed("taxVault.distributor() is the real Distributor"));
    }

    /// The contracts refuse the Admin's own raise and post by name; the gate refuses the appointment itself.
    function test_gate_theAdminAsAServerKeyIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        _appoint(d, StokerKeys.Role.LadderKey, admin);
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the ladder key is not the Admin"));
        _appoint(d, StokerKeys.Role.LadderKey, ladder);
        _appoint(d, StokerKeys.Role.RoundKey, admin);
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the round key is not the Admin"));
        _appoint(d, StokerKeys.Role.RoundKey, round);
        _appoint(d, StokerKeys.Role.Keeper, admin);
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the Keeper is not the Admin"));
    }

    function test_gate_oneAddressInTwoRolesIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        _appoint(d, StokerKeys.Role.RoundKey, round);
        _appoint(d, StokerKeys.Role.LadderKey, round);
        _appoint(d, StokerKeys.Role.Keeper, keeper);
        assertEq(_run(d, KeysExpected.AllAppointed), 1);
        assertTrue(_failed("the round key holds no other role"));
        _appoint(d, StokerKeys.Role.LadderKey, keeper);
        assertEq(_run(d, KeysExpected.AllAppointed), 1);
        assertTrue(_failed("the ladder key holds no other role"));
    }

    function test_gate_theDeployerAsTheAdminOrAKeyIsRefused() public {
        s.admin = address(this);
        Deployment memory d = _deployStokerSet(s, address(this));
        assertGt(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertTrue(_failed("the Admin is not the deployer"));
        // This test contract has code, as a hardware wallet's address never does.
        assertTrue(_failed("the Admin's address has no code (ADR 0030: one hardware wallet)"));
    }

    function test_gate_anAdminOtherThanTheFilesIsRefused_andOneWaitingToTakeItsPlace() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        vm.prank(admin);
        d.keys.proposeAdmin(makeAddr("successor"));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("no address waits to take the Admin's place"));
        vm.prank(makeAddr("successor"));
        d.keys.acceptAdmin();
        assertGt(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertTrue(_failed("the Admin is the settings file's address"));
    }

    /// A piece of 100 basis points is inside the Tax Vault's own bound, and moves a price about as much as a
    /// round trip costs: the gate holds a deployment to the decided 50 whatever its chain's file says.
    function test_gate_aPieceOfAHundredIsRefused_evenWhenTheFileSaysSo() public {
        s.pieceBps = 100;
        Deployment memory d = _deployStokerSet(s, address(this));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("pieceBps is the decided figure (ADR 0025)"));
    }

    function test_gate_aLadderOffTheDecidedSharesIsRefused() public {
        s.topTierShareBps = 7_500;
        Deployment memory d = _deployStokerSet(s, address(this));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the top tier's share is the decided one"));
        s.topTierShareBps = 7_000;
        s.creatorShareBps = 6_000;
        d = _deployStokerSet(s, address(this));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the first tier's share is the decided one (ADR 0020)"));
    }

    /// A deployment that differs from its chain's file in any setting is refused, the opening figures among
    /// them: the file is what the owner read before signing.
    function test_gate_aSettingThatIsNotTheFilesIsRefused() public {
        Settings memory deployed = s;
        deployed.openingFeeDuration = 30;
        deployed.referenceRiseTicksPerMinute = 3;
        deployed.buyBandTicks = 200;
        Deployment memory d = _deployStokerSet(deployed, address(this));
        assertGt(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertTrue(_failed("the Opening Fee's duration"));
        assertTrue(_failed("the Reference Price's rise"));
        assertTrue(_failed("the buys' band above the Reference Price"));
        // The vault's runtime carries its settings, so its code is not this build's with the file's figures.
        assertTrue(_failed("TaxVault runs this build's code"));
    }

    /// A Destination serves one hook: one of another deployment's would strand every coin's earnings sent to it.
    function test_gate_aDestinationOfAnotherDeploymentIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        Deployment memory other = _deployStokerSet(s, address(this));
        d.burnDestination = other.burnDestination;
        assertGt(_run(d, KeysExpected.MayBeUnappointed), 0);
        assertTrue(_failed("the burn's Destination serves this hook"));
        assertTrue(_failed("and funds this Tax Vault"));
        assertTrue(_failed("BurnDestination runs this build's code"));
    }

    /// The hook's address commits to its creation code: a record whose salt does not give this build's hook at
    /// this factory is refused, so a hook of other code cannot stand in.
    function test_gate_aHookThatIsNotThisBuildsIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        d.hookSalt = bytes32(uint256(d.hookSalt) + 1);
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the hook is this build's creation code at the mined salt"));
    }

    function test_gate_otherCodeAtAContractsAddressIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        vm.etch(address(d.liquidityDestination), address(d.burnDestination).code);
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("LiquidityDestination runs this build's code"));
    }

    function test_gate_aMissingContractStopsTheRun() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        d.registry = QuoteRegistry(makeAddr("nothingHere"));
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("QuoteRegistry has code"));
    }

    function test_gate_theWrongChainIsRefused() public {
        Deployment memory d = _deployStokerSet(s, address(this));
        s.chainId = 4663;
        assertEq(_run(d, KeysExpected.MayBeUnappointed), 1);
        assertTrue(_failed("the chain is the settings file's chain"));
    }
}
