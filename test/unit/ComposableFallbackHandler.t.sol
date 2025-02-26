// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "test/ComposabilityBase.t.sol";
import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";
import {Storage} from "contracts/composability/Storage.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import {ComposableExecution, InputParam, OutputParam, ParamValueType, OutputParamFetcherType, InputParamFetcherType} from "contracts/composability/ComposableExecutionLib.sol";
import { CONSTRAINT_TYPE_EQ, CONSTRAINT_TYPE_GTE, CONSTRAINT_TYPE_LTE, CONSTRAINT_TYPE_IN } from "contracts/types/Constants.sol";

contract DummyContract {
    function A() external pure returns (uint256) {
        return 42;
    }

    function B(uint256 value) external pure returns (uint256) {
        // Return the input value multiplied by 2
        return value * 2;
    }
}

contract ComposableFallbackHandlerTest is ComposabilityTestBase {
    
    Storage public storageContract;
    DummyContract public dummyContract;

    address public eoa = address(0x11ce);
    bytes32 public constant SLOT_A = keccak256("SLOT_A");
    bytes32 public constant SLOT_B = keccak256("SLOT_B");

    function setUp() public override {
        super.setUp();
        // Deploy contracts
        storageContract = new Storage(address(0));
        dummyContract = new DummyContract();
        // Fund EOA
        vm.deal(eoa, 100 ether);
    }

    function testComposableFlow() public {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Step 1: Call function A and store its result
        // Prepare return value config for function A
        InputParam[] memory inputParamsA = new InputParam[](0);

        OutputParam[] memory outputParamsA = new OutputParam[](1);
        outputParamsA[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, SLOT_A)
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.A.selector,
            inputParams: inputParamsA, // no input parameters needed
            outputParams: outputParamsA // store output of the function A() to the storage
        });
        // Call function A through mockAccountNonComposable=>handler
        IComposableExecution(address(mockAccountNonComposable)).executeComposable(executions);
        

        // Verify the result (42) was stored correctly
        bytes32 namespace = storageContract.getNamespace(address(mockAccountNonComposable), address(composabilityHandler));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");

        // Step 2: Call function B using the stored value from A
        InputParam[] memory inputParamsB = new InputParam[](1);
        inputParamsB[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_A))),
            constraints: ""
        });

        // Prepare return value config for function B
        OutputParam[] memory outputParamsB = new OutputParam[](1);
        outputParamsB[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, SLOT_B)
        });

        ComposableExecution[] memory executionsB = new ComposableExecution[](1);
        executionsB[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.B.selector,
            inputParams: inputParamsB,
            outputParams: outputParamsB
        });
        // Call function B through mockAccountNonComposable=>handler
        IComposableExecution(address(mockAccountNonComposable)).executeComposable(executionsB);

        // Verify the result (84 = 42 * 2) was stored correctly
        bytes32 storedValueB = storageContract.readStorage(namespace, SLOT_B);
        assertEq(uint256(storedValueB), 84, "Function B result not stored correctly");

        vm.stopPrank();
    }

    function testComposableFlowWithGtConstraint() public {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParamsA = new InputParam[](0);
        console2.logBytes(abi.encodePacked(CONSTRAINT_TYPE_GTE, bytes32(uint256(43))));
        inputParamsA[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encodeWithSelector(DummyContract.A.selector),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_GTE, bytes32(uint256(43)))
        }); // input param will call DummyContract.A() and use constraints to check if >= 43 (should fail)

        OutputParam[] memory outputParamsA = new OutputParam[](0); // no output params

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(0), // dont call any contract - just test the dynamic param injection
            value: 0, // no value sent
            functionSig: 0x0, // no function being called
            inputParams: inputParamsA,
            outputParams: outputParamsA
        });

        // Call function A through mockAccountNonComposable=>handler (should fail because of GT constraint not met)
        IComposableExecution(address(mockAccountNonComposable)).executeComposable(executions);

        vm.stopPrank();
    }
}
