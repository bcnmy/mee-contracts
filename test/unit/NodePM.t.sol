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

import "forge-std/console2.sol";

contract PMPerNodeTest is BaseTest {

    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount();
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    function test_pm_per_node() public returns (PackedUserOperation[] memory userOps) {
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
                verificationGasLimit: 45e3, 
                callGasLimit: 3e6
            }
        );

        uint128 pmValidationGasLimit = 20_000;
        uint128 pmPostOpGasLimit = 40_000;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        userOp.paymasterAndData = makePMAndDataForOwnPM(address(NODE_PAYMASTER), pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, premiumPercentage);
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(NODE_PAYMASTER));

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);   

        // When verification gas limits are tight, the difference is really small
        assertFinancialStuffStrict(entries, premiumPercentage, nodePMDepositBefore, maxGasLimit*unpackMaxFeePerGasMemory(userOp), 0.05e18); // 5% difference

        return (userOps);
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_handleOps_fuzz(
        uint256 preVerificationGasLimit, 
        uint128 verificationGasLimit, 
        uint128 callGasLimit,
        uint256 premiumPercentage,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit
    ) public {
        preVerificationGasLimit = bound(preVerificationGasLimit, 1e5, 5e6);
        verificationGasLimit = uint128(bound(verificationGasLimit, 45e3, 5e6));
        callGasLimit = uint128(bound(callGasLimit, 100e3, 5e6));
        premiumPercentage = bound(premiumPercentage, 0, 200e5);
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 20e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 40e3, 5e6));

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
        userOps[0] = userOp;

        uint256 nodePMDepositBefore = getDeposit(address(NODE_PAYMASTER));
        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet); 

        // now assert financial stuff 
        assertFinancialStuff(entries, premiumPercentage, nodePMDepositBefore, maxGasLimit*unpackMaxFeePerGasMemory(userOp));
    }

    function assertFinancialStuff(
        Vm.Log[] memory entries,
        uint256 meeNodePremium,
        uint256 nodePMDepositBefore,
        uint256 maxGasCost
    ) public returns (uint256 meeNodeEarnings, uint256 expectedNodePremium) {
        (,,uint256 actualGasCost,uint256 acctualGasUsed) = abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));

        uint256 expectedRefund =  applyPremium(maxGasCost, meeNodePremium) - applyPremium(actualGasCost, meeNodePremium);
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

    function makePMAndDataForOwnPM(
        address nodePM, 
        uint128 pmValidationGasLimit, 
        uint128 pmPostOpGasLimit, 
        uint256 maxGasLimit, 
        uint256 premiumPercentage
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            nodePM, 
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            premiumPercentage
        );
    }

    function getDeposit(address account) internal view returns (uint256) {
        return ENTRYPOINT.getDepositInfo(account).deposit;
    }

// test bytecode is fixed

// test mee node is owner, not the factory
    
}
