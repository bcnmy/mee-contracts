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

        uint128 pmValidationGasLimit = 20e3;
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

        // MEE should always charge user taking the premium in the account, otherwise MEE EP can be losing money
        // This maxGasCost is how much we should charge the user. 
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp) * (MEE_ENTRYPOINT.PREMIUM_CALCULATION_BASE() + meeNodePremium) / MEE_ENTRYPOINT.PREMIUM_CALCULATION_BASE();
        console2.log("maxGasCost with Premium", maxGasCost);
        
        // MEE_NODE should always send at least 2*maxGastCost to MEE_EP as MEE_EP has to have extra deposit at EP
        // at the time of _postOp to send refund to the userOp.sender. Coz the proper part of a deposit is locked by EP as a prefund.
        // To compensate this 2*maxGasCost, 
        // The userOp.sender sends maxGastCost to MEE_NODE in a separate node payment userOp included into superTx.
        // another maxGasCost is refunded to MEE_NODE by the OG EP as a refund to `beneficiary` which is handleOps arg.
        // The refund sent by OG EP to MEE_NODE will also include some extra on top of maxGasCost
        // This extra is MEE_NODE premium + what MEE_EP has overcharged because of the not tight userOp gas limits
        vm.prank(MEE_NODE_ADDRESS);
        MEE_ENTRYPOINT.handleOps{value: 2*maxGasCost}(userOps);

        assertEq(mockTarget.value(), valueToSet);   
    }

    // handleOps reverts with 0 value

    // handleOps reverts with low value

    // deposit is properly refunded to the node


/// Some veridfication taken from the logs
    // act gas used cost 986157000000000
    // 6420000000000000 maxGastCost

    // 1197500000000000 // we charged with premium
    //  986157000000000 // actual gas cost emitted by EP
    // 1153803000000000 this is what we should have charged with 17% node bonus
// 0.000043697000000000 this is what we overcharge , which is about 0.15usd on Ethereum Mainnet
    
// 0.000211343000000000 eth we overcharge here and the imits are not tight

    // 6631342680000000
    // 6420000000000000
// 0.000211342680000000 it includes the legit MEE_NODE premium and overcharge

}