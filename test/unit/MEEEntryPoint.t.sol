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
    uint256 constant PREMIUM_CALCULATION_BASE = 100_00000;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount();
        wallet = createAndFundWallet("wallet", 1 ether);
    }

    function test_handleOps_success() public {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);

        uint256 valueToSet = MEE_NODE_HEX;

        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(address(mockAccount), callData, wallet);

        uint128 pmValidationGasLimit = 5000;
        uint128 pmPostOpGasLimit = 3e6;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        uint256 meeNodePremium = 17*1e5;

        bytes memory pmAndData = abi.encodePacked(
            address(MEE_ENTRYPOINT), 
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            abi.encode(
                maxGasLimit, // MEE Node maxGasLimit
                meeNodePremium // MEE Node nodeOperatorPremium
            )
        );

        userOp.paymasterAndData = pmAndData;
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
        // To compensate what EP_NODE sent to MEE_EP, the userOp.sender sends maxGasCostWithPremium
        // to MEE_NODE in a separate node payment userOp included into superTx.
        // It compensates maxGasCostWithPremium part.
        
        // Then EP sends the `collected` part to the MEE_NODE which is set as `beneficiary` arg in EP.handleOps() call be MEE_EP. 
        // It compensates the actual gas cost which MEE_NODE has paid to submit txn on-chain.

        // So what is left to be compensated is maxGasCost + premium % of the actual gas
        // and it indeed is compensated in MEE EntryPoint handleOps method,'
        // when the whole MEE_EP's deposit that has left in EP is sent back to MEE_NODE

        // The refund sent by OG_EP to MEE_NODE will also include some extra on top of maxGasCost and premium
        // This extra is what MEE_EP has overcharged because of the not tight userOp verification gas limits
        // See here: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0

        // One issue here is that MEE_NODE sets the verification gas limits, and now it has an incentive to set them
        // as loose as possible to get refunded as much extra as possible.
        // To handle this, we need to check pmVerificationGasLimit and verificationGasLimit are tight enough.
        // The easiest and cheapest solution here will be checking how big this overcharge over premium is, and if it is too big,
        // network should slash the MEE NODE for it.
        uint256 valueToSendByMeeNode = maxGasCost + maxGasCostWithPremium;
        vm.prank(MEE_NODE_ADDRESS);
        MEE_ENTRYPOINT.handleOps{value: valueToSendByMeeNode}(userOps);

        assertEq(mockTarget.value(), valueToSet);   
    }

    // handleOps reverts with 0 value

    // handleOps reverts with low value

    // deposit is properly refunded to the node

}