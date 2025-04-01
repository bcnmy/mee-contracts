// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../../mock/MockTarget.sol";
import {MockAccount} from "../../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EmittingNodePaymaster} from "../../mock/EmittingNodePaymaster.sol";
import "../../../contracts/types/Constants.sol";

import "forge-std/console2.sol";

contract NodePMAccessControlTest is BaseTest {
    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount({validator: address(0), handler: address(0)});
        wallet = createAndFundWallet("wallet", 1 ether);
        mockTarget.setValue(0);
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

    // happy path => userOp passes if properly signed
    function test_passes_if_properly_signed() public {
        PackedUserOperation[] memory userOps = _prepareUserOps();

        userOps[0] = addNodeMasterSig(userOps[0], MEE_NODE, MEE_NODE_EXECUTOR_EOA);

        uint256 mockTargetValueBefore = mockTarget.value();

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA); 
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertFalse(mockTargetValueBefore == valueToSet);
        assertEq(mockTarget.value(), valueToSet);
    }

    // happy path => userOp passes if sent by owner()
    function test_passes_if_sent_by_owner() public {
        PackedUserOperation[] memory userOps = _prepareUserOps();

        // no extra sig needed

        uint256 mockTargetValueBefore = mockTarget.value();

        vm.startPrank(NODE_PAYMASTER.owner(), NODE_PAYMASTER.owner()); 
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertFalse(mockTargetValueBefore == valueToSet);
        assertEq(mockTarget.value(), valueToSet); 
    }

    function test_reverts_if_sent_by_non_approved_EOA() public {
        PackedUserOperation[] memory userOps = _prepareUserOps();

        userOps[0] = addNodeMasterSig(userOps[0], MEE_NODE, MEE_NODE_EXECUTOR_EOA);

        uint256 mockTargetValueBefore = mockTarget.value();

        vm.startPrank(address(0xdeadbeef)); // submitter is not an executor EOA signed above

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA34 signature error"));
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));

        vm.stopPrank();

        assertFalse(mockTargetValueBefore == valueToSet);
        assertEq(mockTargetValueBefore, mockTarget.value());
    }

    // test reverts if userOp hash was not signed
    function test_reverts_if_userOp_hash_was_not_signed() public {
        PackedUserOperation[] memory userOps = _prepareUserOps();
        userOps[0] = addNodeMasterSig(userOps[0], MEE_NODE, MEE_NODE_EXECUTOR_EOA); 
 
        userOps[0].preVerificationGas++; // change some data so the userOp hash changes
        // Do not re-sign with MEE Node EOA, so the userOp hash is not signed by the Node

        uint256 mockTargetValueBefore = mockTarget.value();

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA); // should revert despite of the correct tx.origin
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA34 signature error"));
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertFalse(mockTargetValueBefore == valueToSet);
        assertEq(mockTargetValueBefore, mockTarget.value());
    }

    function _prepareUserOps() public returns (PackedUserOperation[] memory) {
        valueToSet = MEE_NODE_HEX;
        uint256 premiumPercentage = 17_00000;
        
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

        uint128 pmValidationGasLimit = 25_000;
        uint128 pmPostOpGasLimit = 20_000;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        // refund mode = user
        // premium mode = percentage premium
        userOp.paymasterAndData = abi.encodePacked(
            address(NODE_PAYMASTER),
            pmValidationGasLimit,
            pmPostOpGasLimit,
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_PERCENT,
            uint192(premiumPercentage)
        );
        
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        return (userOps);
    }

}
