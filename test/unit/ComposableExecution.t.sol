// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "test/ComposabilityBase.t.sol";
import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";
import {Storage} from "contracts/composability/Storage.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import {
    ComposableExecution,
    InputParam,
    OutputParam,
    ParamValueType,
    OutputParamFetcherType,
    InputParamFetcherType
} from "contracts/composability/ComposableExecutionLib.sol";
import {
    CONSTRAINT_TYPE_EQ,
    CONSTRAINT_TYPE_GTE,
    CONSTRAINT_TYPE_LTE,
    CONSTRAINT_TYPE_IN
} from "contracts/types/Constants.sol";

event Uint256Emitted(uint256 value);

event Uint256Emitted2(uint256 value1, uint256 value2);

contract DummyContract {
    uint256 internal foo;

    function A() external pure returns (uint256) {
        return 42;
    }

    function B(uint256 value) external pure returns (uint256) {
        // Return the input value multiplied by 2
        return value * 2;
    }

    function getFoo() external view returns (uint256) {
        return foo;
    }

    function setFoo(uint256 value) external {
        foo = value;
    }

    function emitUint256(uint256 value) external {
        emit Uint256Emitted(value);
    }

    function swap(uint256 exactInput, uint256 minOutput) external returns (uint256 output1) {
        emit Uint256Emitted2(exactInput, minOutput);
        output1 = exactInput + 1;
        emit Uint256Emitted(output1);
    }

    function stake(uint256 toStake, uint256 foo) external {
        emit Uint256Emitted2(toStake, foo);
    }

    function getAddress() external view returns (address) {
        return address(this);
    }
}

contract ComposableExecutionTest is ComposabilityTestBase {
    Storage public storageContract;
    DummyContract public dummyContract;

    address public eoa = address(0x11ce);
    bytes32 public constant SLOT_A = keccak256("SLOT_A");
    bytes32 public constant SLOT_B = keccak256("SLOT_B");

    function setUp() public override {
        super.setUp();
        // Deploy contracts
        storageContract = new Storage();
        dummyContract = new DummyContract();
        // Fund EOA
        vm.deal(eoa, 100 ether);
    }

    function test_inputStaticCall_OutputExecResult_Success() public {
        // via composability module
        _inputStaticCallOutputExecResult(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _inputStaticCallOutputExecResult(address(mockAccount), address(mockAccount));
    }

    function test_inputRawBytes_Success() public {
        // via composability module
        _inputRawBytes(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _inputRawBytes(address(mockAccount), address(mockAccount));
    }

    function test_outputStaticCall_Success() public {
        // via composability module
        _outputStaticCall(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _outputStaticCall(address(mockAccount), address(mockAccount));
    }

    // test actual composability => call executeComposable with multiple executions
    function test_useOutputAsInput_Success() public {
        // via composability module
        _useOutputAsInput(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _useOutputAsInput(address(mockAccount), address(mockAccount));
    }

    function test_outputExecResultAddress_Success() public {
        // via composability module
        _outputExecResultAddress(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _outputExecResultAddress(address(mockAccount), address(mockAccount));
    }

    function test_inputsWithConstraints() public {
        _inputParamUsingGteConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingLteConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingInConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingEqConstraints(address(mockAccount), address(mockAccount));
    }

    // TODO:
    // test that input value works correctly with all types: address, bool.

    // ================================ TEST SCENARIOS ================================

    function _inputParamUsingGteConstraints(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(42),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_GTE, bytes32(uint256(43))) // value must be >= 43 but 42 provided
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(43),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_GTE, bytes32(uint256(43))) // value must be >= 42
        });

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract), abi.encodeWithSelector(DummyContract.A.selector), address(storageContract), SLOT_A
            )
        });

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(bytes("GTE constraint not met."));
        IComposableExecution(address(account)).executeComposable(failingExecutions);

        // Call empty function and it should NOT revert because dynamic param value meets constraints
        ComposableExecution[] memory validExecutions = new ComposableExecution[](1);
        validExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: validInputParams, // use valid input params
            outputParams: outputParams
        });
        IComposableExecution(address(account)).executeComposable(validExecutions);

        // Expect valid composable execution to store result as per given output params
        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");
    }

    function _inputParamUsingLteConstraints(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(42),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_LTE, bytes32(uint256(41))) // value must be <= 41 but 42 provided
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(41),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_LTE, bytes32(uint256(41))) // value must be <= 41
        });

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract), abi.encodeWithSelector(DummyContract.A.selector), address(storageContract), SLOT_A
            )
        });

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(bytes("LTE constraint not met."));
        IComposableExecution(address(account)).executeComposable(failingExecutions);

        // Call empty function and it should NOT revert because dynamic param value meets constraints
        ComposableExecution[] memory validExecutions = new ComposableExecution[](1);
        validExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: validInputParams, // use valid input params
            outputParams: outputParams
        });
        IComposableExecution(address(account)).executeComposable(validExecutions);

        // Expect valid composable execution to store result as per given output params
        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");
    }

    function _inputParamUsingInConstraints(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert (param value below lowerBound)
        InputParam[] memory invalidInputParamsA = new InputParam[](1);
        invalidInputParamsA[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(40),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
        });

        // Prepare invalid input param - call should revert (param value above upperBound)
        InputParam[] memory invalidInputParamsB = new InputParam[](1);
        invalidInputParamsB[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(44),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
        });

        // Prepare valid input param - call should succeed (param value in bounds)
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(42),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
        });

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract), abi.encodeWithSelector(DummyContract.A.selector), address(storageContract), SLOT_A
            )
        });

        // Call empty function and it should revert because dynamic param value doesnt meet constraints (value below lower bound)
        ComposableExecution[] memory failingExecutionsA = new ComposableExecution[](1);
        failingExecutionsA[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParamsA, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(bytes("IN constraint not met"));
        IComposableExecution(address(account)).executeComposable(failingExecutionsA);

        // Call empty function and it should revert because dynamic param value doesnt meet constraints (value below lower bound)
        ComposableExecution[] memory failingExecutionsB = new ComposableExecution[](1);
        failingExecutionsB[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParamsB, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(bytes("IN constraint not met"));
        IComposableExecution(address(account)).executeComposable(failingExecutionsB);

        // Call empty function and it should NOT revert because dynamic param value meets constraints
        ComposableExecution[] memory validExecutions = new ComposableExecution[](1);
        validExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: validInputParams, // use valid input params
            outputParams: outputParams
        });
        IComposableExecution(address(account)).executeComposable(validExecutions);

        // Expect valid composable execution to store result as per given output params
        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");
    }

    function _inputParamUsingEqConstraints(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(43),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_EQ, bytes32(uint256(42))) // value must be exactly 42
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(42),
            constraints: abi.encodePacked(CONSTRAINT_TYPE_EQ, bytes32(uint256(42))) // value must be exactly 42
        });

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract), abi.encodeWithSelector(DummyContract.A.selector), address(storageContract), SLOT_A
            )
        });

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(bytes("EQ constraint not met."));
        IComposableExecution(address(account)).executeComposable(failingExecutions);

        // Call empty function and it should NOT revert because dynamic param value meets constraints
        ComposableExecution[] memory validExecutions = new ComposableExecution[](1);
        validExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: validInputParams, // use valid input params
            outputParams: outputParams
        });
        IComposableExecution(address(account)).executeComposable(validExecutions);

        // Expect valid composable execution to store result as per given output params
        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");
    }

    function _inputStaticCallOutputExecResult(address account, address caller) internal {
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

        // Call function A through native executeComposable
        IComposableExecution(address(account)).executeComposable(executions);

        // Verify the result (42) was stored correctly
        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
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
        IComposableExecution(address(account)).executeComposable(executionsB);

        // Verify the result (84 = 42 * 2) was stored correctly
        bytes32 storedValueB = storageContract.readStorage(namespace, SLOT_B);
        assertEq(uint256(storedValueB), 84, "Function B result not stored correctly");

        vm.stopPrank();
    }

    // use 1 as input for emitUint256
    // so 1 should be emitted
    function _inputRawBytes(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](1);
        inputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(1),
            constraints: ""
        });

        // Prepare return value config for function B
        OutputParam[] memory outputParams = new OutputParam[](0);

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.emitUint256.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        vm.expectEmit(address(dummyContract));
        emit Uint256Emitted(1);
        IComposableExecution(address(account)).executeComposable(executions);

        vm.stopPrank();
    }

    // test static call output fetcher.
    // call getFoo() on dummyContract
    // store the result in the composability storage
    // and check that the result is stored correctly
    function _outputStaticCall(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](0);

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract),
                abi.encodeWithSelector(DummyContract.getFoo.selector),
                address(storageContract),
                SLOT_B
            )
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.getFoo.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        uint256 expectedValue = 2517;
        dummyContract.setFoo(expectedValue);
        assertEq(dummyContract.getFoo(), expectedValue, "Value not stored correctly in the contract itself");

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValue = storageContract.readStorage(namespace, SLOT_B);
        assertEq(uint256(storedValue), expectedValue, "Value not stored correctly in the composability storage");
    }

    function _useOutputAsInput(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        uint256 input1 = 2517;
        uint256 input2 = 7579;
        dummyContract.setFoo(input1);

        // first execution => call swap and store the result in the composability storage
        InputParam[] memory inputParams_execution1 = new InputParam[](2);
        inputParams_execution1[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(input1),
            constraints: ""
        });
        inputParams_execution1[1] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(input2),
            constraints: ""
        });

        OutputParam[] memory outputParams_execution1 = new OutputParam[](2);
        outputParams_execution1[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(address(storageContract), SLOT_A)
        });
        outputParams_execution1[1] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(
                address(dummyContract),
                abi.encodeWithSelector(DummyContract.getFoo.selector),
                address(storageContract),
                SLOT_B
            )
        });

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));

        // second execution => call stake with the result of the first execution
        InputParam[] memory inputParams_execution2 = new InputParam[](2);
        inputParams_execution2[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_A))),
            constraints: ""
        });
        inputParams_execution2[1] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_B))),
            constraints: ""
        });
        OutputParam[] memory outputParams_execution2 = new OutputParam[](0);

        ComposableExecution[] memory executions = new ComposableExecution[](2);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.swap.selector,
            inputParams: inputParams_execution1,
            outputParams: outputParams_execution1
        });
        executions[1] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.stake.selector,
            inputParams: inputParams_execution2,
            outputParams: outputParams_execution2
        });

        uint256 expectedToStake = input1 + 1;
        vm.expectEmit(address(dummyContract));
        // swap emits input params
        emit Uint256Emitted2(input1, input2);
        // swap emits output param
        emit Uint256Emitted(expectedToStake);
        // stake emits input params: first param is from swap, second param is from getFoo which is just input1
        emit Uint256Emitted2(expectedToStake, input1);
        IComposableExecution(address(account)).executeComposable(executions);

        //check storage slots
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A);
        assertEq(uint256(storedValueA), expectedToStake, "Value not stored correctly in the composability storage");
        bytes32 storedValueB = storageContract.readStorage(namespace, SLOT_B);
        assertEq(uint256(storedValueB), input1, "Value not stored correctly in the composability storage");

        vm.stopPrank();
    }

    // test that outputExecResultAddress works correctly with address
    // call getAddress() on dummyContract
    // store the result in the composability storage
    // and check that the result is stored correctly
    function _outputExecResultAddress(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](0);

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            valueType: ParamValueType.ADDRESS,
            paramData: abi.encode(address(storageContract), SLOT_A)
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.getAddress.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 storedValue = storageContract.readStorage(namespace, SLOT_A);
        assertEq(
            address(uint160(uint256(storedValue))),
            address(dummyContract),
            "Value not stored correctly in the composability storage"
        );
    }
}
