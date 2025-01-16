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

        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, MEE_NODE_HEX);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(address(mockAccount), callData, wallet);

        uint128 pmValidationGasLimit = 3e6;
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

        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp) * (MEE_ENTRYPOINT.PREMIUM_CALCULATION_BASE() + meeNodePremium) / MEE_ENTRYPOINT.PREMIUM_CALCULATION_BASE();
        console2.log("maxGasCost", maxGasCost);
        
        vm.prank(MEE_NODE_ADDRESS);
        // EP will send refund to MEE_NODE
        MEE_ENTRYPOINT.handleOps{value: maxGasCost}(userOps);

        assertEq(mockTarget.value(), MEE_NODE_HEX);  
    }

    // handleOps reverts with 0 value

    // handleOps reverts with low value

    // deposit is properly refunded to the node

}