// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../mock/MockTarget.sol";
import {MockAccount} from "../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {PMPerNode} from "contracts/PMPerNode.sol";

import "forge-std/console2.sol";

contract PMPerNodeTest is BaseTest {

    using UserOperationLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    PMPerNode pmPerNode;

    function setUp() public virtual override {
        super.setUp();
        mockAccount = deployMockAccount();
        wallet = createAndFundWallet("wallet", 1 ether);
        pmPerNode = new PMPerNode(ENTRYPOINT, MEE_NODE_ADDRESS, 17e5);
        vm.deal(address(pmPerNode), 100 ether);

        vm.prank(address(pmPerNode));
        ENTRYPOINT.depositTo{value: 10 ether}(address(pmPerNode));
    }

    function test_pm_per_node() public returns (PackedUserOperation[] memory userOps) {
        valueToSet = MEE_NODE_HEX;
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
        uint128 pmPostOpGasLimit = 3e6;
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;


        userOp.paymasterAndData = makePMAndDataForOwnPM(pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit);
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        
        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        uint256 preOpGas = gasleft();
        ENTRYPOINT.handleOps(userOps, payable(wallet.addr));
        uint256 postOpGas = gasleft();
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(mockTarget.value(), valueToSet);   

        (,,uint256 actualGasCost,uint256 acctualGasUsed) = abi.decode(entries[entries.length - 1].data, (uint256, bool, uint256, uint256));
        console2.log("actualGasCost", actualGasCost);
        console2.log("acctualGasUsed", acctualGasUsed);
        console2.log('call gas spent', preOpGas - postOpGas);
        return (userOps);
    }

        function makePMAndDataForOwnPM(uint128 pmValidationGasLimit, uint128 pmPostOpGasLimit, uint256 maxGasLimit) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pmPerNode), 
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit // pm post-op gas limit
        );
    }
//1_014_815
//1_011_014
//1_015_347
    
}
