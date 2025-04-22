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

contract FixedPremium_Paymaster_Test is BaseTest {
    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    uint256 _premium;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount({validator: address(0), handler: address(0)});
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    function _fixed_premium_single_base(
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

        vm.recordLogs();

        uint256 gasLog = gasleft();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        gasLog -= gasleft();

        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);

        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        // When verification gas limits are tight, the difference is really small
        refund = assertFinancialStuffStrict({
            entries: entries, 
            nodePMDepositBefore: nodePMDepositBefore, 
            maxGasLimit: maxGasLimit, 
            maxFeePerGas: unpackMaxFeePerGasMemory(userOp),
            gasSpentByExecutorEOA: gasLog,
            maxDiffPercentage: maxDiffPercentage
        });

    }

    // test percentage user single
    function test_fixed_premium_user_single() public {
        _premium = 5e16; // 0.05 ETH

        uint128 pmValidationGasLimit = 15_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 45_000;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_FIXED
        );
        
        _fixed_premium_single_base(pmAndData, pmValidationGasLimit, pmPostOpGasLimit);
    }

    // test percentage dApp single
    function test_fixed_premium_dapp_single() public {
        _premium = 5e16; // 0.05 ETH

        Vm.Wallet memory dAppWallet = createAndFundWallet("dAppWallet", 1 ether);
        uint256 dAppBalanceBefore = dAppWallet.addr.balance;

        uint128 pmValidationGasLimit = 20_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 55_000;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_DAPP,
            NODE_PM_PREMIUM_FIXED,
            dAppWallet.addr
        );
        
        uint256 refund = _fixed_premium_single_base(pmAndData, pmValidationGasLimit, pmPostOpGasLimit);
        assertEq(dAppWallet.addr.balance, dAppBalanceBefore + refund, "dApp should receive the refund");
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_fixed_premium_user_fuzz(
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
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 30e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 45e3, 5e6));

        _premium = bound(_premium, 0, 1e18);

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
            NODE_PM_PREMIUM_FIXED
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
            nodePMDepositBefore: nodePMDepositBefore, 
            maxGasLimit: maxGasLimit, 
            maxFeePerGas: unpackMaxFeePerGasMemory(userOp),
            gasSpentByExecutorEOA: gasLog
        }); 
    }

    // ============ HELPERS ==============

    function assertFinancialStuff(
        Vm.Log[] memory entries,
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
        expectedNodeEarnings = _premium;

        // deposit decrease = refund to sponsor (if any) + gas cost refund to beneficiary (EXECUTOR_EOA) =>
        actualRefund = (nodePMDepositBefore - getDeposit(address(EMITTING_NODE_PAYMASTER))) - actualGasCostFromEP;

        // earnings are (how much node receives in a payment userOp) minus (refund) minus (actual gas cost paid by executor EOA)
        meeNodeEarnings = (maxGasCost + _premium) - (actualRefund + gasSpentByExecutorEOA * actualGasPrice);

        assertTrue(meeNodeEarnings > 0, "MEE_NODE should have earned something");
        assertGe(meeNodeEarnings, expectedNodeEarnings, "MEE_NODE should have earned more or equal to expected");
    }

    function assertFinancialStuffStrict(
        Vm.Log[] memory entries,
        uint256 nodePMDepositBefore,
        uint256 maxGasLimit,
        uint256 maxFeePerGas,
        uint256 gasSpentByExecutorEOA,
        uint256 maxDiffPercentage
    ) public returns (uint256) {
        (uint256 meeNodeEarnings, uint256 expectedNodeEarnings, uint256 refund) =
            assertFinancialStuff(entries, nodePMDepositBefore, maxGasLimit, maxFeePerGas, gasSpentByExecutorEOA);

        // assert that MEE_NODE extra earnings are not too big
        assertApproxEqRel(expectedNodeEarnings, meeNodeEarnings, maxDiffPercentage, "MEE_NODE earnings are too big");

        return refund;
    }

    function getDeposit(address account) internal view returns (uint256) {
        return ENTRYPOINT.getDepositInfo(account).deposit;
    }
}
