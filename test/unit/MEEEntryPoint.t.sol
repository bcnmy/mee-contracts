// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../mock/MockTarget.sol";
import {MockAccount} from "../mock/MockAccount.sol";

import "forge-std/console2.sol";

contract MEEEntryPointTest is BaseTest {

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

    function test_handleOps_success() public returns (PackedUserOperation[] memory userOps, uint256 valueToSendByMeeNode) {
        valueToSet = MEE_NODE_HEX;
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(
            {
                account: address(mockAccount), 
                callData: callData, 
                wallet: wallet, 
                preVerificationGasLimit: 3e5, 
                verificationGasLimit: 40e3, 
                callGasLimit: 3e6
            }
        );

        uint128 pmValidationGasLimit = 5000;
        uint128 pmPostOpGasLimit = 3e6;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        uint256 meeNodePremium = 17*1e5;

        userOp.paymasterAndData = makePMAndDataForMeeEP(pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, meeNodePremium);
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // This maxGasCostWithPremium is how much we should charge the user. 
        // MEE should always charge user taking the premium in the account, otherwise MEE EP can be losing money.
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        uint256 maxGasCostWithPremium = maxGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE;
        //console2.log("maxGasCost", maxGasCost);
        //console2.log("maxGasCost with Premium", maxGasCostWithPremium);
        
        // MEE_NODE should always send at least maxGasCost + maxGasCostWithPremium to MEE_EP as MEE_EP has to have extra deposit at EP
        // at the time of _postOp to send refund to the userOp.sender. 
        // maxGasCost is locked by EP as a prefund.
        // The refund to userOp.sender can in theory be up to maxGasCostWithPremium so MEE_EP has to have it on deposit.
        // To compensate what MEE_NODE sent to MEE_EP, the userOp.sender sends maxGasCostWithPremium
        // to MEE_NODE in a separate node payment userOp included into superTx.
        // It compensates maxGasCostWithPremium part.
        
        // Then EP sends the `collected` part to the MEE_NODE which is set as `beneficiary` arg in EP.handleOps() call be MEE_EP. 
        // It compensates the actual gas cost which MEE_NODE has paid to submit txn on-chain.

        // So what is left to be compensated is maxGasCost + premium % of the actual gas
        // and it indeed is compensated in MEE EntryPoint handleOps method,
        // when the whole MEE_EP's deposit that has left in EP is sent back to MEE_NODE

        // The refund sent by OG_EP to MEE_NODE will also include some extra on top of maxGasCost and premium
        // This extra is what MEE_EP has overcharged because of the not tight userOp verification gas limits
        // See here: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0
        // This overcharge also depends on the POSTOP_GAS constant, which is set in MEE_EP.
        // So MEE_NODE should carefully estimate postop gas and set thism value as tight as possible.

        // One issue here is that MEE_NODE sets the verification gas limits, and now it has an incentive to set them
        // as loose as possible to get refunded as much extra as possible.
        // To handle this, we need to check pmVerificationGasLimit and verificationGasLimit are tight enough.
        // The easiest and cheapest solution here will be checking how big this overcharge over premium is, and if it is too big,
        // network should slash the MEE NODE for it.
        uint256 valueToSendByMeeNode = maxGasCost + maxGasCostWithPremium;
        uint256 meeNodeBalanceBefore = MEE_NODE_ADDRESS.balance;
        vm.startPrank(MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps{value: valueToSendByMeeNode}(userOps);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);   

        // refund the MEE_NODE with maxGasCostWithPremium, which in the wild will be sent by Op.sender to MEE_NODE
        MEE_NODE_ADDRESS.call{value: maxGasCostWithPremium}(""); 

        assertFinancialStuffStrict(entries, meeNodePremium, meeNodeBalanceBefore, 0.15e18);
        return (userOps, valueToSendByMeeNode);
    }

    // fuzz tests with different gas values =>
    // check all the charges and refunds are handled properly
    function test_handleOps_fuzz(
        uint256 preVerificationGasLimit, 
        uint128 verificationGasLimit, 
        uint128 callGasLimit,
        uint256 meeNodePremium,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit
    ) public {

        preVerificationGasLimit = bound(preVerificationGasLimit, 1e5, 5e6);
        verificationGasLimit = uint128(bound(verificationGasLimit, 40e3, 5e6));
        callGasLimit = uint128(bound(callGasLimit, 100e3, 5e6));
        meeNodePremium = bound(meeNodePremium, 0, 200e5);
        pmValidationGasLimit = uint128(bound(pmValidationGasLimit, 5e3, 5e6));
        pmPostOpGasLimit = uint128(bound(pmPostOpGasLimit, 20e3, 5e6));

        console2.log("preVerificationGasLimit", preVerificationGasLimit);
        console2.log("verificationGasLimit", verificationGasLimit);
        console2.log("callGasLimit", callGasLimit);
        console2.log("meeNodePremium", meeNodePremium);
        console2.log("pmValidationGasLimit", pmValidationGasLimit);
        console2.log("pmPostOpGasLimit", pmPostOpGasLimit);

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
        
        bytes memory pmAndData = makePMAndDataForMeeEP(pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, meeNodePremium);

        userOp.paymasterAndData = pmAndData;
        userOps[0] = userOp;

        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        uint256 maxGasCostWithPremium = maxGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE;

        uint256 valueToSendByMeeNode = maxGasCost + maxGasCostWithPremium;
        uint256 meeNodeBalanceBefore = MEE_NODE_ADDRESS.balance;
        vm.startPrank(MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps{value: valueToSendByMeeNode}(userOps);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet); 

        // refund the MEE_NODE with maxGasCostWithPremium, which in the wild will be sent by Op.sender to MEE_NODE
        MEE_NODE_ADDRESS.call{value: maxGasCostWithPremium}(""); 

        // now assert financial stuff 
        assertFinancialStuff(entries, meeNodePremium, meeNodeBalanceBefore);
    }

    // handleOps reverts with 0 value
    function test_handleOps_reverts_with_0_value() public {
        (PackedUserOperation[] memory userOps, ) = test_handleOps_success();
        userOps[0].nonce = ENTRYPOINT.getNonce(userOps[0].sender, 0);
        //no need to re-sign the userOp as mock account does not check the signature
        vm.startPrank(MEE_NODE_ADDRESS);
        vm.expectRevert(abi.encodeWithSignature("EmptyMessageValue()"));
        // send 0 value
        MEE_ENTRYPOINT.handleOps{value: 0}(userOps);
        vm.stopPrank();
    }

    // handleOps reverts with low value
    function test_handleOps_reverts_with_low_value() public {
        
        (PackedUserOperation[] memory userOps, uint256 valueToSendByMeeNode) = test_handleOps_success();

        // reset the value to 0
        mockTarget.setValue(0);
        
        userOps[0].nonce = ENTRYPOINT.getNonce(userOps[0].sender, 0);
        //no need to re-sign the userOp as mock account does not check the signature
        vm.startPrank(MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps{value: valueToSendByMeeNode/2}(userOps);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, bool userOpSuccess, ,) = abi.decode(entries[5].data, (uint256, bool, uint256, uint256));
        assertFalse(userOpSuccess, "userOp should not be successful");
        // assert that the userOp was not executed
        assertEq(mockTarget.value(), 0);
    }

    function test_premium_suppots_fractions(uint256 meeNodePremium) public {
        meeNodePremium = bound(meeNodePremium, 1, 200e5);
        (, uint256 valueToSendByMeeNode) = test_handleOps_success();
        uint256 approxGasCost = valueToSendByMeeNode / 2;
        uint256 approxGasCostWithPremium = approxGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE;
        assertGt(approxGasCostWithPremium, approxGasCost, "premium should support fractions of %");
    }


    function assertFinancialStuffStrict(
        Vm.Log[] memory entries,
        uint256 meeNodePremium,
        uint256 meeNodeBalanceBefore,
        uint256 maxDiffPercentage
    ) public {
        (uint256 meeNodeEarnings, uint256 expectedNodePremium) = assertFinancialStuff(entries, meeNodePremium, meeNodeBalanceBefore);
        // assert that MEE_NODE extra earnings are not too big
        assertApproxEqRel(meeNodeEarnings, expectedNodePremium, maxDiffPercentage);
    }

    function assertFinancialStuff(
        Vm.Log[] memory entries,
        uint256 meeNodePremium,
        uint256 meeNodeBalanceBefore
    ) public returns (uint256 meeNodeEarnings, uint256 expectedNodePremium) {
        (,,uint256 actualGasCost,) = abi.decode(entries[6].data, (uint256, bool, uint256, uint256));
        expectedNodePremium = (actualGasCost * (PREMIUM_CALCULATION_BASE + meeNodePremium) / PREMIUM_CALCULATION_BASE) - actualGasCost;

        // we have to subtract actualGasCost from the balance because it was refunded by OG_EP to MEE_NODE
        // but in this test it was not spent as Foundry doesn't charge for gas
        meeNodeEarnings = MEE_NODE_ADDRESS.balance - meeNodeBalanceBefore - actualGasCost;
        
        assertTrue(meeNodeEarnings > 0, "MEE_NODE should have earned something");
        assertTrue(meeNodeEarnings >= expectedNodePremium, "MEE_NODE should have earned more than expectedNodePremium");
    }
}
