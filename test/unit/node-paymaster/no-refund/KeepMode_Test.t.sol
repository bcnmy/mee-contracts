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

contract KeepMode_Paymaster_Test is BaseTest {
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

    function test_keep_mode_single() public {
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

        uint128 pmValidationGasLimit = 15_000;
        // ~ 12_000 is raw PM.postOp gas spent 
        // here we add more for emitting events in the wrapper + refunds etc in EP
        uint128 pmPostOpGasLimit = 37_000;
        
        userOp.paymasterAndData = abi.encodePacked(
            address(EMITTING_NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_KEEP
        );
        // account owner does not need to re-sign the userOp as mock account does not check the signature

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(EMITTING_NODE_PAYMASTER));
        uint256 refundReceiverBalanceBefore = userOps[0].sender.balance;

        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // parse UserOperationEvent
        (,, uint256 actualGasCostFromEP, ) =
            abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));

        assertEq(mockTarget.value(), valueToSet);
        // refund receiver balance is same as before
        assertEq(userOps[0].sender.balance, refundReceiverBalanceBefore);
        // nodePM deposit only decreased for a value of gas taken by EP and sent to beneficiary
        uint256 expectedNodePMDeposit = nodePMDepositBefore - actualGasCostFromEP;
        assertEq(getDeposit(address(EMITTING_NODE_PAYMASTER)), expectedNodePMDeposit);
    }

    // ============ HELPERS ==============

    function getDeposit(address account) internal view returns (uint256) {
        return ENTRYPOINT.getDepositInfo(account).deposit;
    }
}
