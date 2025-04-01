// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../../../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../../../mock/MockTarget.sol";
import {MockAccount} from "../../../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EmittingNodePaymaster} from "../../../mock/EmittingNodePaymaster.sol";
import "../../../../contracts/types/Constants.sol";

import "forge-std/console2.sol";

contract PercentagePremium_Paymaster_Test is BaseTest {
    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;
    uint256 _premiumPercentage;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount({validator: address(0), handler: address(0)});
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    // Node paymaster is owned by MEE_NODE_ADDRESS.
    // Every MEE Node should deploy its own NodePaymaster.
    // Then node uses it to sponsor userOps within a superTxn that this node is processing
    // by putting address of its NodePaymaster in the userOp.paymasterAndData field.
    // Native token flows here are as follows:
    // 1. Node paymaster has a deposit at ENTRYPOINT
    // 2. UserOp sponsor sends the sum of maxGasCost and premium for all the userOps
    //    within a superTxn to the node in a separate payment userOp.
    // 3. Node PM refunds the unused gas cost to the userOp sponsor (maxGasCost - actualGasCost)*premium
    // 4. EP refunds the actual gas cost to some Node EOA as it is used as a `beneficiary` in the handleOps call
    // Both of those amounts are deducted from the Node PM's deposit at ENTRYPOINT.

    // There are two known issues:
    
    // 1. Greedy node can increase postOpGasLimit to overcharge the userOp.sender by making the refund smaller.
    // For now we:
    // a) expect only proved nodes to be in the network with no intent to overcharge users
    // b) will slash malicious nodes as intentional increase of the limits can be easily detected

    // 2. Node can set higher gas fees to increase actualGasPrice compared to the one that was used 
    // to submit the handleOps call. This however will affect the maxGasCost reflected in the superTx quote
    // that user/dapp will take into account when choosing a node for the superTxn. So the nodes with 
    // non-reasonable gas fees will not be selected.

    function _percentage_single_base(
        bytes memory pmAndData,
        uint256 pmValidationGasLimit,
        uint256 pmPostOpGasLimit
    ) 
        internal
        returns (uint256 refund)
    {
        valueToSet = MEE_NODE_HEX;
        uint256 maxDiffPercentage = 0.10e18; // 10% difference
        
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData =
            abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: address(mockAccount),
            callData: callData,
            wallet: wallet,
            preVerificationGasLimit: 50e3,
            verificationGasLimit: 35e3,
            callGasLimit: 100e3
        });

        userOp.paymasterAndData = pmAndData;
        // account owner does not need to re-sign the userOp as mock account does not check the signature

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        uint256 refundReceiverBalanceBefore = userOps[0].sender.balance;

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        vm.recordLogs();

        uint256 gasLog = gasleft();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        gasLog -= gasleft();

        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);

        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        // When verification gas limits are tight, the difference is really small
        refund = assertFinancialStuffStrict({
            entries: entries, 
            meeNodePremiumPercentage: _premiumPercentage, 
            nodePMDepositBefore: nodePMDepositBefore, 
            maxGasLimit: maxGasLimit, 
            maxFeePerGas: unpackMaxFeePerGasMemory(userOp),
            gasSpentByExecutorEOA: gasLog,
            maxDiffPercentage: maxDiffPercentage
        });

    }

    // test percentage user single
    function test_percentage_user_single() public {
        _premiumPercentage = 17_00000;
        uint128 pmValidationGasLimit = 15_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 37_000;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_PERCENT,
            uint192(_premiumPercentage)
        );
        
        _percentage_single_base(pmAndData, pmValidationGasLimit, pmPostOpGasLimit);
    }

    // test percentage dApp single
    function test_percentage_dapp_single() public {
        Vm.Wallet memory dAppWallet = createAndFundWallet("dAppWallet", 1 ether);
        uint256 dAppBalanceBefore = dAppWallet.addr.balance;

        _premiumPercentage = 17_00000;
        uint128 pmValidationGasLimit = 20_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 38_000;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_DAPP,
            NODE_PM_PREMIUM_PERCENT,
            uint192(_premiumPercentage),
            dAppWallet.addr
        );
        
        uint256 refund = _percentage_single_base(pmAndData, pmValidationGasLimit, pmPostOpGasLimit);
        assertEq(dAppWallet.addr.balance, dAppBalanceBefore + refund, "dApp should receive the refund");
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_percentage_user_fuzz(
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
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 30e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 50e3, 5e6));

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        valueToSet = MEE_NODE_HEX;

        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData =
            abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: address(mockAccount),
            callData: callData,
            wallet: wallet,
            preVerificationGasLimit: preVerificationGasLimit,
            verificationGasLimit: verificationGasLimit,
            callGasLimit: callGasLimit
        });

        uint256 maxGasLimit = preVerificationGasLimit + verificationGasLimit + callGasLimit + pmValidationGasLimit + pmPostOpGasLimit;
        
        // refund mode = user
        // premium mode = percentage premium
        userOp.paymasterAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit,
            pmPostOpGasLimit,
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_PERCENT,
            uint192(premiumPercentage)
        );
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        vm.recordLogs();

        uint256 gasLog = gasleft();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        gasLog -= gasleft();
        
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);
         
        assertFinancialStuff({
            entries: entries, 
            meeNodePremiumPercentage: premiumPercentage, 
            nodePMDepositBefore: nodePMDepositBefore, 
            maxGasLimit: maxGasLimit, 
            maxFeePerGas: unpackMaxFeePerGasMemory(userOp),
            gasSpentByExecutorEOA: gasLog
        }); 
    }

    function test_premium_supports_fractions(uint256 meeNodePremium, uint256 approxGasCost) public {
        meeNodePremium = bound(meeNodePremium, 1e3, 200e5);
        approxGasCost = bound(approxGasCost, 50_000, 5e6);
        uint256 approxGasCostWithPremium =
            approxGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE;
        assertGt(approxGasCostWithPremium, approxGasCost, "premium should support fractions of %");
    }

    // ============ HELPERS ==============

    function assertFinancialStuff(
        Vm.Log[] memory entries,
        uint256 meeNodePremiumPercentage,
        uint256 nodePMDepositBefore,
        uint256 maxGasLimit,
        uint256 maxFeePerGas,
        uint256 gasSpentByExecutorEOA
    ) public returns (uint256 meeNodeEarnings, uint256 expectedNodeEarnings, uint256 actualRefund) {
        // parse UserOperationEvent
        (,, uint256 actualGasCostFromEP, uint256 actualGasUsedFromEP) =
            abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));
        
        // parse postOpGasEvent
        (uint256 gasCostPrePostOp, uint256 gasSpentInPostOp) =
            abi.decode(entries[entries.length - 2].data, (uint256, uint256));
        
        uint256 actualGasPrice = actualGasCostFromEP / actualGasUsedFromEP;
        
        uint256 maxGasCost = maxGasLimit * maxFeePerGas;

        // nodePM does not charge for the penalty however because it still goes to the node EOA
        uint256 actualGasCost = gasCostPrePostOp + gasSpentInPostOp * actualGasPrice;
        
        // NodePm doesn't charge for the penalty
        expectedNodeEarnings = getPremium(actualGasCost, meeNodePremiumPercentage);

        // deposit decrease = refund to sponsor (if any) + gas cost refund to beneficiary (EXECUTOR_EOA) =>
        actualRefund = (nodePMDepositBefore - getDeposit(address(EMITTING_NODE_PAYMASTER))) - actualGasCostFromEP;

        // earnings are (how much node receives in a payment userOp) minus (refund) minus (actual gas cost paid by executor EOA)
        meeNodeEarnings = applyPremium(maxGasCost, meeNodePremiumPercentage) - actualRefund - gasSpentByExecutorEOA * actualGasPrice;

        assertTrue(meeNodeEarnings > 0, "MEE_NODE should have earned something");
        assertTrue(
            meeNodeEarnings >= expectedNodeEarnings, "MEE_NODE should have earned more or equal to expectedNodeEarnings"
        );
    }

    function assertFinancialStuffStrict(
        Vm.Log[] memory entries,
        uint256 meeNodePremiumPercentage,
        uint256 nodePMDepositBefore,
        uint256 maxGasLimit,
        uint256 maxFeePerGas,
        uint256 gasSpentByExecutorEOA,
        uint256 maxDiffPercentage
    ) public returns (uint256) {
        (uint256 meeNodeEarnings, uint256 expectedNodeEarnings, uint256 refund) =
            assertFinancialStuff(entries, meeNodePremiumPercentage, nodePMDepositBefore, maxGasLimit, maxFeePerGas, gasSpentByExecutorEOA);

        // assert that MEE_NODE extra earnings are not too big
        assertApproxEqRel(expectedNodeEarnings, meeNodeEarnings, maxDiffPercentage, "MEE_NODE earnings are too big");

        return refund;
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
