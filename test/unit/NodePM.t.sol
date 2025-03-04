// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../mock/MockTarget.sol";
import {MockAccount} from "../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import "forge-std/console2.sol";

contract PMPerNodeTest is BaseTest {

    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount({
            validator: address(0)
        });
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    // Node paymaster is owned by MEE_NODE_ADDRESS.
    // Every MEE Node should deploy its own NodePaymaster.
    // Then node uses it to sponsor userOps within a superTxn that this node is processing
    // by putting address of its NodePaymaster in the userOp.paymasterAndData field.
    // Native token flows here are as follows:
    // 1. Node paymaster has a deposit at ENTRYPOINT
    // 2. UserOp.sender sends the sum of maxGasCost and premium for all the userOps
    //    within a superTxn to the node in a separate payment userOp.
    // 3. Node PM refunds the unused gas cost to the userOp.sender (maxGasCost - actualGasCost)*premium
    // 4. EP refunds the actual gas cost to the Node as it is used as a `beneficiary` in the handleOps call
    // Both of those amounts are deducted from the Node PM's deposit at ENTRYPOINT.

    // There is a knowm issue that a malicious MEE Node can intentionally set verificationGasLimit and pmVerificationGasLimit
    // not tight to overcharge the userOp.sender by makeing the refund smaller. 
    // See the details in the NodePaymaster.sol = _calculateRefund() method inline comments.
    // This will be fixed in the future by EP0.8 returning proper penalty for the unused gas.
    // For now we: 
    // a) expect only proved nodes to be in the network with no intent to overcharge users
    // b) will slash malicious nodes as intentional increase of the limits can be easily detected

    function test_pm_per_node_single() public returns (PackedUserOperation[] memory) {
        valueToSet = MEE_NODE_HEX;
        uint256 premiumPercentage = 17_00000;
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(
            {
                account: address(mockAccount), 
                callData: callData, 
                wallet: wallet, 
                preVerificationGasLimit: 3e5, 
                verificationGasLimit: 50e3, 
                callGasLimit: 3e6
            }
        );

        uint128 pmValidationGasLimit = 28_000;
        uint128 pmPostOpGasLimit = 50_000; //min to pass is 44k. we set 50k for non-standard stuff
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        userOp.paymasterAndData = makePMAndDataForOwnPM(address(NODE_PAYMASTER), pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, premiumPercentage);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = addNodeMasterSig(userOp, MEE_NODE);

        uint256 nodePMDepositBefore = getDeposit(address(NODE_PAYMASTER));

        vm.startPrank(MEE_NODE_EXECUTOR_EOA);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);   

        // When verification gas limits are tight, the difference is really small
        assertFinancialStuffStrict(entries, premiumPercentage, nodePMDepositBefore, maxGasLimit*unpackMaxFeePerGasMemory(userOp), 0.05e18); // 5% difference

        return (userOps);
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_pm_per_node_fuzz(
        uint256 preVerificationGasLimit, 
        uint128 verificationGasLimit, 
        uint128 callGasLimit,
        uint256 premiumPercentage,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit
    ) public {
        preVerificationGasLimit = bound(preVerificationGasLimit, 1e5, 5e6);
        verificationGasLimit = uint128(bound(verificationGasLimit, 50e3, 5e6));
        callGasLimit = uint128(bound(callGasLimit, 100e3, 5e6));
        premiumPercentage = bound(premiumPercentage, 0, 200e5);
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 28e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 50e3, 5e6));

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        valueToSet = MEE_NODE_HEX;

        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(
            {
                account: address(mockAccount), 
                callData: callData, 
                wallet: wallet, 
                preVerificationGasLimit: preVerificationGasLimit, 
                verificationGasLimit: verificationGasLimit, 
                callGasLimit: callGasLimit
            }
        );

        uint256 maxGasLimit = preVerificationGasLimit + verificationGasLimit + callGasLimit + pmValidationGasLimit + pmPostOpGasLimit;
        
        userOp.paymasterAndData = makePMAndDataForOwnPM(address(NODE_PAYMASTER), pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, premiumPercentage);
        userOps[0] = addNodeMasterSig(userOp, MEE_NODE);

        uint256 nodePMDepositBefore = getDeposit(address(NODE_PAYMASTER));
        vm.startPrank(MEE_NODE_EXECUTOR_EOA);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet); 
        assertFinancialStuff(entries, premiumPercentage, nodePMDepositBefore, maxGasLimit*unpackMaxFeePerGasMemory(userOp));
    }

    function test_bytecode_is_fixed_for_different_nodes() public {
        address otherNodeAddress = address(0xdeafbeef);
        vm.prank(otherNodeAddress);
        NodePaymaster nodePM = new NodePaymaster(ENTRYPOINT, otherNodeAddress);
        bytes32 OG_NODEPM_CODEHASH;
        bytes32 codeHash;
        assembly {
            OG_NODEPM_CODEHASH := extcodehash(sload(NODE_PAYMASTER.slot))
            codeHash := extcodehash(nodePM)
        }
        assertEq(codeHash, OG_NODEPM_CODEHASH, "NodePM bytecode should be fixed");
    }

    function test_MEE_Node_is_Owner() public {
        address payable receiver = payable(address(0xdeadbeef));
        
        vm.prank(MEE_NODE_ADDRESS);
        NODE_PAYMASTER.withdrawTo(receiver, 1 ether);
        assertEq(receiver.balance, 1 ether, "MEE_NODE should be the owner of the NodePM");
        
        // node pm is owned by MEE_NODE_ADDRESS
        assertEq(NODE_PAYMASTER.owner(), MEE_NODE_ADDRESS);
        
        vm.startPrank(address(nodePmDeployer));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(nodePmDeployer)));
        NODE_PAYMASTER.withdrawTo(receiver, 1 ether);
        vm.stopPrank();
        assertEq(receiver.balance, 1 ether, "Balance should not be changed");
    }

    function test_premium_suppots_fractions(uint256 meeNodePremium, uint256 approxGasCost  ) public {
        meeNodePremium = bound(meeNodePremium, 1e3, 200e5);
        approxGasCost = bound(approxGasCost, 50_000, 5e6);
        uint256 approxGasCostWithPremium = approxGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE;
        assertGt(approxGasCostWithPremium, approxGasCost, "premium should support fractions of %");
    }

    // Test it reverts for non-MEE Node superTxns
    function test_non_mee_node_superTxns_revert() public {
        PackedUserOperation[] memory userOps = test_pm_per_node_single();
        userOps[0].nonce = ENTRYPOINT.getNonce(userOps[0].sender, 0);
        //no need to re-sign the userOp as mock account does not check the signature
        bytes memory revertReason = abi.encodeWithSignature("FailedOpWithRevert(uint256,string,bytes)", 0, "AA33 reverted", abi.encodeWithSignature("OnlySponsorOwnStuff()"));
        vm.startPrank(address(0xdeadbeef));
        vm.expectRevert(revertReason);
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
    }

    // test executed userOps are logged properly
    function test_executed_userOps_logged_properly() public {
        PackedUserOperation[] memory userOps = test_pm_per_node_single();
        bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[0]);
        assertEq(NODE_PAYMASTER.wasUserOpExecuted(userOpHash), true);
    }

    // if the userOp.sender is malicious and spends too much gas, nodePM.postOp 
    // will revert on EP.withdrawTo as postOp is called with a gas limit
    
    // ============ HELPERS ==============

    function assertFinancialStuff(
        Vm.Log[] memory entries,
        uint256 meeNodePremium,
        uint256 nodePMDepositBefore,
        uint256 maxGasCost
    ) public returns (uint256 meeNodeEarnings, uint256 expectedNodePremium) {
        (,,uint256 actualGasCost,uint256 acctualGasUsed) = abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));

        uint256 expectedRefund =  applyPremium(maxGasCost, meeNodePremium) - applyPremium(actualGasCost, meeNodePremium);
        // we apply premium to the maxGasCost, because maxGasCost is wat is always sent by the userOp.sender to MEE Node in a payment userOp
        uint256 expectedRefundNoPremium = applyPremium(maxGasCost, meeNodePremium) - actualGasCost;

        // OG EP takes gas cost from the PM's deposit and sends it to the beneficiary, in this case MEE_NODE
        // in the postOp this PM refunds the unused gas cost to the userOp.sender
        // so the remaining deposit should be like this
        uint256 expectedNodeDepositAfter = nodePMDepositBefore - expectedRefund - actualGasCost;
        uint256 expectedNodeDepositAfterNoPremium = nodePMDepositBefore - expectedRefundNoPremium - actualGasCost;
        expectedNodePremium = getPremium(actualGasCost, meeNodePremium);

        meeNodeEarnings = getDeposit(address(NODE_PAYMASTER)) - expectedNodeDepositAfterNoPremium;
        
        assertTrue(meeNodeEarnings > 0, "MEE_NODE should have earned something");
        assertTrue(meeNodeEarnings >= expectedNodePremium, "MEE_NODE should have earned more or equal to expectedNodePremium");
    }

    function assertFinancialStuffStrict(
        Vm.Log[] memory entries,
        uint256 meeNodePremium,
        uint256 nodePMDepositBefore,
        uint256 maxGasCost,
        uint256 maxDiffPercentage
    ) public {
        (uint256 meeNodeEarnings, uint256 expectedNodePremium) = assertFinancialStuff(entries, meeNodePremium, nodePMDepositBefore, maxGasCost);
        // assert that MEE_NODE extra earnings are not too big
        assertApproxEqRel(meeNodeEarnings, expectedNodePremium, maxDiffPercentage);
    }


    function applyPremium(uint256 amount, uint256 premiumPercentage) internal pure returns (uint256) {
        return amount * (PREMIUM_CALCULATION_BASE + premiumPercentage) / PREMIUM_CALCULATION_BASE;
    }

    function getPremium(uint256 amount, uint256 premiumPercentage) internal pure returns (uint256) {
        return applyPremium(amount, premiumPercentage) - amount;
    }

    function getDeposit(address account) internal view returns (uint256) {
        return ENTRYPOINT.getDepositInfo(account).deposit;
    }
    
}
