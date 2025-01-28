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
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import "forge-std/console2.sol";

contract K1MEEValidatorTest is BaseTest {

    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        wallet = createAndFundWallet("wallet", 1 ether);
        mockAccount = deployMockAccount({
            validator: address(k1MeeValidator)
        });
        vm.prank(address(mockAccount));
        k1MeeValidator.transferOwnership(wallet.addr);
    }

    function test_regular_userOp_flow_success() public returns (PackedUserOperation[] memory) {
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
                verificationGasLimit: 500e3, 
                callGasLimit: 3e6
            }
        );

        uint128 pmValidationGasLimit = 20_000;
        uint128 pmPostOpGasLimit = 40_000;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;

        userOp.paymasterAndData = makePMAndDataForOwnPM(address(NODE_PAYMASTER), pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, premiumPercentage);
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        
        userOp.signature = signUserOp(wallet, userOp);
        userOp.signature = abi.encodePacked(uint8(0xff), userOp.signature);
        
        userOps[0] = userOp;

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.value(), valueToSet);   

        return (userOps);
    }


    
}
