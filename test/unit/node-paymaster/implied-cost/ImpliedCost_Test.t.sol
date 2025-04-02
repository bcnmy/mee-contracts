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

contract ImpliedCost_Paymaster_Test is BaseTest {
    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;
    uint256 _impliedCost;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount({validator: address(0), handler: address(0)});
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    // test percentage user single
    function test_implied_cost_user_single() public {
        uint128 pmValidationGasLimit = 15_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 37_000;

        PackedUserOperation memory userOp = _implied_cost_single_prepareUserOp(pmValidationGasLimit, pmPostOpGasLimit);

        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        _impliedCost = maxGasCost * 3 / 4;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_IMPLIED,
            uint192(_impliedCost)
        );

        userOp.paymasterAndData = pmAndData;
        // account owner does not need to re-sign the userOp as mock account does not check the signature

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        uint256 refundReceiverBalanceBefore = userOps[0].sender.balance;

        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);

        // When verification gas limits are tight, the difference is really small
        assertFinancialStuff({
            entries: entries, 
            nodePMDepositBefore: nodePMDepositBefore, 
            refundReceiverBalanceBefore: refundReceiverBalanceBefore,
            refundReceiver: userOps[0].sender,
            maxGasCost: maxGasCost
        });
    }

     // test percentage dApp single
    function test_implied_cost_dapp_single() public {
        Vm.Wallet memory dAppWallet = createAndFundWallet("dAppWallet", 1 ether);
 
        uint128 pmValidationGasLimit = 20_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 38_000;

        PackedUserOperation memory userOp = _implied_cost_single_prepareUserOp(pmValidationGasLimit, pmPostOpGasLimit);

        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        _impliedCost = maxGasCost * 3 / 4;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_DAPP,
            NODE_PM_PREMIUM_IMPLIED,
            uint192(_impliedCost),
            dAppWallet.addr
        );
        
        userOp.paymasterAndData = pmAndData;
        // account owner does not need to re-sign the userOp as mock account does not check the signature

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        uint256 refundReceiverBalanceBefore = dAppWallet.addr.balance;

        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);

        // When verification gas limits are tight, the difference is really small
        assertFinancialStuff({
            entries: entries, 
            nodePMDepositBefore: nodePMDepositBefore, 
            refundReceiverBalanceBefore: refundReceiverBalanceBefore,
            refundReceiver: dAppWallet.addr,
            maxGasCost: maxGasCost
        });
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_implied_cost_user_fuzz(
        uint256 preVerificationGasLimit,
        uint128 verificationGasLimit,
        uint128 callGasLimit,
        uint256 premiumPercentage,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit,
        uint256 impliedCostRatio
    ) public {
        preVerificationGasLimit = bound(preVerificationGasLimit, 1e5, 5e6);
        verificationGasLimit = uint128(bound(verificationGasLimit, 50e3, 5e6));
        callGasLimit = uint128(bound(callGasLimit, 100e3, 5e6));
        premiumPercentage = bound(premiumPercentage, 0, 200e5);
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 35e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 50e3, 5e6));
        impliedCostRatio = bound(impliedCostRatio, 0, 100e5);

        uint128 pmValidationGasLimit = 15_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 37_000;

        PackedUserOperation memory userOp = _implied_cost_single_prepareUserOp(pmValidationGasLimit, pmPostOpGasLimit);

        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        
        _impliedCost = maxGasCost * impliedCostRatio / 100e5;
        
        bytes memory pmAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_IMPLIED,
            uint192(_impliedCost)
        );

        userOp.paymasterAndData = pmAndData;
        // account owner does not need to re-sign the userOp as mock account does not check the signature

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        uint256 refundReceiverBalanceBefore = userOps[0].sender.balance;

        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);

        // When verification gas limits are tight, the difference is really small
        assertFinancialStuff({
            entries: entries, 
            nodePMDepositBefore: nodePMDepositBefore, 
            refundReceiverBalanceBefore: refundReceiverBalanceBefore,
            refundReceiver: userOps[0].sender,
            maxGasCost: maxGasCost
        });
    } 

    // ============ HELPERS ==============

    function _implied_cost_single_prepareUserOp(
        uint256 pmValidationGasLimit,
        uint256 pmPostOpGasLimit
    ) 
        internal
        returns (PackedUserOperation memory)
    {
        valueToSet = MEE_NODE_HEX;
        
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

        return userOp;
    }

    function assertFinancialStuff(
        Vm.Log[] memory entries,
        uint256 nodePMDepositBefore,
        uint256 refundReceiverBalanceBefore,
        address refundReceiver,
        uint256 maxGasCost
    ) internal {
        // parse UserOperationEvent
        (,, uint256 actualGasCostFromEP, uint256 actualGasUsedFromEP) =
            abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));
        
        // parse postOpGasEvent
        (uint256 gasCostPrePostOp, uint256 gasSpentInPostOp) =
            abi.decode(entries[entries.length - 2].data, (uint256, uint256));

        uint256 expectedRefund = maxGasCost - _impliedCost;

        assertEq(
            expectedRefund,
            refundReceiver.balance - refundReceiverBalanceBefore,
            "refund should be equal to expected"
        );

        assertEq(
            getDeposit(address(EMITTING_NODE_PAYMASTER)),
            nodePMDepositBefore - (expectedRefund + actualGasCostFromEP),
            "PM deposit should decrease by expectedRefund - actualGasCostFromEP"
        );
    }

    function getDeposit(address account) internal view returns (uint256) {
        return ENTRYPOINT.getDepositInfo(account).deposit;
    }
}
