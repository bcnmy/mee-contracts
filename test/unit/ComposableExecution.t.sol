// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "test/ComposabilityBase.t.sol";
import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";
import {Storage} from "contracts/composability/Storage.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import "contracts/composability/ComposableExecutionLib.sol";
import "test/mock/DummyContract.sol";

contract ComposableExecutionTest is ComposabilityTestBase {

    event MockAccountReceive(uint256 amount);
    Storage public storageContract;
    DummyContract public dummyContract;

    address public eoa = address(0x11ce);
    bytes32 public constant SLOT_A = keccak256("SLOT_A");
    bytes32 public constant SLOT_B = keccak256("SLOT_B");

    Constraint[] internal emptyConstraints = new Constraint[](0);

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

    function test_inputs_With_Gte_Constraints() public {
        _inputParamUsingGteConstraints(address(mockAccount), address(mockAccount));     
        _inputParamUsingGteConstraints(address(mockAccountNonComposable), address(composabilityHandler));
    }

    function test_inputs_With_Lte_Constraints() public {
        _inputParamUsingLteConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingLteConstraints(address(mockAccountNonComposable), address(composabilityHandler));
    }

    function test_inputs_With_In_Constraints() public {
        _inputParamUsingInConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingInConstraints(address(mockAccountNonComposable), address(composabilityHandler));
    }

    function test_inputs_With_Eq_Constraints() public {
        _inputParamUsingEqConstraints(address(mockAccount), address(mockAccount));
        _inputParamUsingEqConstraints(address(mockAccountNonComposable), address(composabilityHandler));
    }

    function test_outputExecResultBool_Success() public {
        // via composability module
        _outputExecResultBool(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _outputExecResultBool(address(mockAccount), address(mockAccount));
    }

    function test_outputExecResultMultipleValues_Success() public {
        // via composability module
        _outputExecResultMultipleValues(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _outputExecResultMultipleValues(address(mockAccount), address(mockAccount));
    }

    function test_outputStaticCallMultipleValues_Success() public {
        // via composability module
        _outputStaticCallMultipleValues(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _outputStaticCallMultipleValues(address(mockAccount), address(mockAccount));
    }

    function test_inputStaticCallMultipleValues_Success() public {
        // via composability module
        _inputStaticCallMultipleValues(address(mockAccountNonComposable), address(composabilityHandler));

        // via native executeComposable
        _inputStaticCallMultipleValues(address(mockAccount), address(mockAccount));
    }

    function test_inputDynamicBytesArrayAsRawBytes_Success() public {
        _inputDynamicBytesArrayAsRawBytes(address(mockAccountNonComposable), address(composabilityHandler));
        _inputDynamicBytesArrayAsRawBytes(address(mockAccount), address(mockAccount));
    }

    function test_structInjection_Success() public {
        _structInjection(address(mockAccountNonComposable), address(composabilityHandler));
        _structInjection(address(mockAccount), address(mockAccount));
    }
    
    // =================================================================================
    // ================================ TEST SCENARIOS ================================
    // =================================================================================

    function _inputParamUsingGteConstraints(address account, address caller) internal {
        Constraint[] memory constraints = new Constraint[](1);
        constraints[0] = Constraint({
            constraintType: ConstraintType.GTE,
            referenceData: abi.encode(bytes32(uint256(43)))
        });

        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(42),
            constraints: constraints
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(43),
            constraints: constraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        bytes memory expectedRevertData = abi.encodeWithSelector(ConstraintNotMet.selector, ConstraintType.GTE);
        vm.expectRevert(expectedRevertData);
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
    }

    function _inputParamUsingLteConstraints(address account, address caller) internal {
        Constraint[] memory constraints = new Constraint[](1);
        constraints[0] = Constraint({
            constraintType: ConstraintType.LTE,
            referenceData: abi.encode(bytes32(uint256(41)))
        });
        
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(42),
            //constraints: abi.encodePacked(ConstraintType.LTE, bytes32(uint256(41))) // value must be <= 41 but 42 provided
            constraints: constraints
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(41),
            //constraints: abi.encodePacked(ConstraintType.LTE, bytes32(uint256(41))) // value must be <= 41
            constraints: constraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(abi.encodeWithSelector(ConstraintNotMet.selector, ConstraintType.LTE));
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
    }

    function _inputParamUsingInConstraints(address account, address caller) internal {
        Constraint[] memory constraints = new Constraint[](1);
        constraints[0] = Constraint({
            constraintType: ConstraintType.IN,
            referenceData: abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))
        });

        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert (param value below lowerBound)
        InputParam[] memory invalidInputParamsA = new InputParam[](1);
        invalidInputParamsA[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(40),
            //constraints: abi.encodePacked(ConstraintType.IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
            constraints: constraints
        });

        // Prepare invalid input param - call should revert (param value above upperBound)
        InputParam[] memory invalidInputParamsB = new InputParam[](1);
        invalidInputParamsB[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(44),
            //constraints: abi.encodePacked(ConstraintType.IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
            constraints: constraints
        });

        // Prepare valid input param - call should succeed (param value in bounds)
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(42),
            //constraints: abi.encodePacked(ConstraintType.IN, abi.encode(bytes32(uint256(41)), bytes32(uint256(43)))) // value must be between 41 & 43
            constraints: constraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        // Call empty function and it should revert because dynamic param value doesnt meet constraints (value below lower bound)
        ComposableExecution[] memory failingExecutionsA = new ComposableExecution[](1);
        failingExecutionsA[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParamsA, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(abi.encodeWithSelector(ConstraintNotMet.selector, ConstraintType.IN));
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
        vm.expectRevert(abi.encodeWithSelector(ConstraintNotMet.selector, ConstraintType.IN));
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
    }

    function _inputParamUsingEqConstraints(address account, address caller) internal {
        Constraint[] memory constraints = new Constraint[](1);
        constraints[0] = Constraint({
            constraintType: ConstraintType.EQ,
            referenceData: abi.encode(bytes32(uint256(42)))
        });

        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Prepare invalid input param - call should revert
        InputParam[] memory invalidInputParams = new InputParam[](1);
        invalidInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(43),
            //constraints: abi.encodePacked(ConstraintType.EQ, bytes32(uint256(42))) // value must be exactly 42
            constraints: constraints
        });

        // Prepare valid input param - call should succeed
        InputParam[] memory validInputParams = new InputParam[](1);
        validInputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(42),
            //constraints: abi.encodePacked(ConstraintType.EQ, bytes32(uint256(42))) // value must be exactly 42
            constraints: constraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        // Call empty function and it should revert because dynamic param value doesnt meet constraints
        ComposableExecution[] memory failingExecutions = new ComposableExecution[](1);
        failingExecutions[0] = ComposableExecution({
            to: address(0), // no function call
            value: 0, // no value sent
            functionSig: "", // no calldata encoded
            inputParams: invalidInputParams, // use constrainted input parameter that's going to fail
            outputParams: outputParams
        });
        vm.expectRevert(abi.encodeWithSelector(ConstraintNotMet.selector, ConstraintType.EQ));
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
    }

    function _inputStaticCallOutputExecResult(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        // Step 1: Call function A and store its result
        // Prepare return value config for function A
        InputParam[] memory inputParamsA = new InputParam[](0);

        OutputParam[] memory outputParamsA = new OutputParam[](1);
        outputParamsA[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            paramData: abi.encode(1, storageContract, SLOT_A)
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
        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A_0);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");

        // Step 2: Call function B using the stored value from A
        InputParam[] memory inputParamsB = new InputParam[](1);
        inputParamsB[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_A_0))),
            constraints: emptyConstraints
        });

        // Prepare return value config for function B
        OutputParam[] memory outputParamsB = new OutputParam[](1);
        outputParamsB[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            paramData: abi.encode(1, storageContract, SLOT_B)
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
        bytes32 SLOT_B_0 = keccak256(abi.encodePacked(SLOT_B, uint256(0)));
        bytes32 storedValueB = storageContract.readStorage(namespace, SLOT_B_0);
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
            paramData: abi.encode(1),
            constraints: emptyConstraints
        });

        // Prepare return value config for function B
        OutputParam[] memory outputParams = new OutputParam[](0);

        uint256 valueToSendExecution;
        uint256 valueToSendToComposableModule;
        if (address(account) == address(mockAccountNonComposable)) {
            valueToSendExecution = 1e15;
            valueToSendToComposableModule = 2 * valueToSendExecution;
        }

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: valueToSendExecution,
            functionSig: DummyContract.emitUint256.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        vm.expectEmit(address(dummyContract));
        emit Uint256Emitted(1);
        if (address(account) == address(mockAccountNonComposable)) {
            emit Received(valueToSendExecution);
            vm.expectEmit(address(mockAccountNonComposable));
            emit MockAccountReceive(valueToSendExecution);
        }
        IComposableExecution(address(account)).executeComposable{value: valueToSendToComposableModule}(executions);

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
            paramData: abi.encode(
                1,
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
        bytes32 SLOT_B_0 = keccak256(abi.encodePacked(SLOT_B, uint256(0)));
        bytes32 storedValue = storageContract.readStorage(namespace, SLOT_B_0);
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
            paramData: abi.encode(input1),
            constraints: emptyConstraints
        });
        inputParams_execution1[1] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(input2),
            constraints: emptyConstraints
        });

        OutputParam[] memory outputParams_execution1 = new OutputParam[](2);
        outputParams_execution1[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            paramData: abi.encode(1, address(storageContract), SLOT_A)
        });
        outputParams_execution1[1] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(
                1,
                address(dummyContract),
                abi.encodeWithSelector(DummyContract.getFoo.selector),
                address(storageContract),
                SLOT_B
            )
        });

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));

        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 SLOT_B_0 = keccak256(abi.encodePacked(SLOT_B, uint256(0)));
        // second execution => call stake with the result of the first execution
        InputParam[] memory inputParams_execution2 = new InputParam[](2);
        inputParams_execution2[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_A_0))),
            constraints: emptyConstraints
        });
        inputParams_execution2[1] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (namespace, SLOT_B_0))),
            constraints: emptyConstraints
        });
        OutputParam[] memory outputParams_execution2 = new OutputParam[](0);

        uint256 valueToSend = 1e15;

        ComposableExecution[] memory executions = new ComposableExecution[](2);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: valueToSend,
            functionSig: DummyContract.swap.selector,
            inputParams: inputParams_execution1,
            outputParams: outputParams_execution1
        });
        executions[1] = ComposableExecution({
            to: address(dummyContract),
            value: valueToSend,
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
        emit Received(valueToSend);
        IComposableExecution(address(account)).executeComposable{value: 2 * valueToSend}(executions);

        //check storage slots
        bytes32 storedValueA = storageContract.readStorage(namespace, SLOT_A_0);
        assertEq(uint256(storedValueA), expectedToStake, "Value not stored correctly in the composability storage");
        bytes32 storedValueB = storageContract.readStorage(namespace, SLOT_B_0);
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
            paramData: abi.encode(1, address(storageContract), SLOT_A)
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
        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 storedValue = storageContract.readStorage(namespace, SLOT_A_0);
        assertEq(address(uint160(uint256(storedValue))), address(dummyContract), "Value not stored correctly in the composability storage");
    }

    function _outputExecResultBool(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](0);

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            paramData: abi.encode(1, address(storageContract), SLOT_A)
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.getBool.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 storedValue = storageContract.readStorage(namespace, SLOT_A_0);
        assertTrue(uint8(uint256(storedValue)) == 1, "Value not stored correctly in the composability storage");
    }

    function _outputExecResultMultipleValues(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](0);
        
        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.EXEC_RESULT,
            paramData: abi.encode(4, address(storageContract), SLOT_A)
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.returnMultipleValues.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 SLOT_A_1 = keccak256(abi.encodePacked(SLOT_A, uint256(1)));
        bytes32 SLOT_A_2 = keccak256(abi.encodePacked(SLOT_A, uint256(2)));
        bytes32 SLOT_A_3 = keccak256(abi.encodePacked(SLOT_A, uint256(3)));
        bytes32 storedValue0 = storageContract.readStorage(namespace, SLOT_A_0);
        bytes32 storedValue1 = storageContract.readStorage(namespace, SLOT_A_1);
        bytes32 storedValue2 = storageContract.readStorage(namespace, SLOT_A_2);
        bytes32 storedValue3 = storageContract.readStorage(namespace, SLOT_A_3);
        assertEq(uint256(storedValue0), 2517, "Value 0 not stored correctly in the composability storage");
        assertEq(address(uint160(uint256(storedValue1))), address(dummyContract), "Value 1 not stored correctly in the composability storage");
        assertEq(storedValue2, keccak256("DUMMY"), "Value 2 not stored correctly in the composability storage");
        assertEq(uint8(uint256(storedValue3)), 1, "Value 3 not stored correctly in the composability storage");
    }

    // test outputStaticCall with multiple return values
    function _outputStaticCallMultipleValues(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](0);

        OutputParam[] memory outputParams = new OutputParam[](1);
        outputParams[0] = OutputParam({
            fetcherType: OutputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(4, address(dummyContract), abi.encodeWithSelector(DummyContract.returnMultipleValues.selector), address(storageContract), SLOT_A)
        });

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.A.selector, // can be any function here in fact
            inputParams: inputParams,
            outputParams: outputParams
        });

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();

        bytes32 namespace = storageContract.getNamespace(address(account), address(caller));
        bytes32 SLOT_A_0 = keccak256(abi.encodePacked(SLOT_A, uint256(0)));
        bytes32 SLOT_A_1 = keccak256(abi.encodePacked(SLOT_A, uint256(1)));
        bytes32 SLOT_A_2 = keccak256(abi.encodePacked(SLOT_A, uint256(2)));
        bytes32 SLOT_A_3 = keccak256(abi.encodePacked(SLOT_A, uint256(3)));
        bytes32 storedValue0 = storageContract.readStorage(namespace, SLOT_A_0);
        bytes32 storedValue1 = storageContract.readStorage(namespace, SLOT_A_1);
        bytes32 storedValue2 = storageContract.readStorage(namespace, SLOT_A_2);
        bytes32 storedValue3 = storageContract.readStorage(namespace, SLOT_A_3);
        assertEq(uint256(storedValue0), 2517, "Value 0 not stored correctly in the composability storage");
        assertEq(address(uint160(uint256(storedValue1))), address(dummyContract), "Value 1 not stored correctly in the composability storage");
        assertEq(storedValue2, keccak256("DUMMY"), "Value 2 not stored correctly in the composability storage");
        assertEq(uint8(uint256(storedValue3)), 1, "Value 3 not stored correctly in the composability storage");
    }

    // test inputStaticCall with multiple return values
    function _inputStaticCallMultipleValues(address account, address caller) internal {
        Constraint[] memory constraints = new Constraint[](4);
        constraints[0] = Constraint({
            constraintType: ConstraintType.EQ,
            referenceData: abi.encode(bytes32(uint256(2517)))
        });
        constraints[1] = Constraint({
            constraintType: ConstraintType.EQ,
            referenceData: abi.encode(bytes32(uint256(uint160(address(dummyContract)))))
        });
        constraints[2] = Constraint({
            constraintType: ConstraintType.EQ,
            referenceData: abi.encode(bytes32(uint256(keccak256("DUMMY"))))
        });
        constraints[3] = Constraint({
            constraintType: ConstraintType.EQ,
            referenceData: abi.encode(bytes32(uint256(1)))
        });

        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        InputParam[] memory inputParams = new InputParam[](1);
        inputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(address(dummyContract), abi.encodeWithSelector(DummyContract.returnMultipleValues.selector)),
            constraints: constraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.acceptMultipleValues.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        vm.expectEmit(address(dummyContract));
        emit Uint256Emitted(2517);
        emit AddressEmitted(address(dummyContract));
        emit Bytes32Emitted(keccak256("DUMMY"));
        emit BoolEmitted(true);

        IComposableExecution(address(account)).executeComposable(executions);
        vm.stopPrank();
    }

    function _inputDynamicBytesArrayAsRawBytes(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        uint256 someStaticValue = 2517;
        uint256 expectedUint256 = 2517*2;
        bytes memory expectedBytes = bytes("Hello, world!");
        address expectedAddress = address(0xa11cedecaf);

        // encode function call as per https://docs.soliditylang.org/en/develop/abi-spec.html 
        // function is : function acceptStaticAndDynamicValues(uint256 staticValue, bytes calldata dynamicValue, address addr)

        // static arg
        InputParam[] memory inputParams = new InputParam[](4);
        inputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(address(dummyContract), abi.encodeWithSelector(DummyContract.B.selector, someStaticValue)),
            constraints: emptyConstraints
        });

        // dynamic arg => here only offset is pasted
        inputParams[1] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(uint256(0x60)),
            constraints: emptyConstraints
        });

        // static arg
        inputParams[2] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(expectedAddress),
            constraints: emptyConstraints
        });
        
        // the payload  of the dynamic arg
        inputParams[3] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encodePacked(expectedBytes.length, expectedBytes),
            constraints: emptyConstraints
        });

        // Prepare return value config for function B
        OutputParam[] memory outputParams = new OutputParam[](0);

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.acceptStaticAndDynamicValues.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        vm.expectEmit(address(dummyContract));
        emit Uint256Emitted(expectedUint256);
        emit AddressEmitted(expectedAddress);
        emit BytesEmitted(expectedBytes);
        IComposableExecution(address(account)).executeComposable(executions);

        vm.stopPrank();
    }

    function _structInjection(address account, address caller) internal {
        vm.startPrank(ENTRYPOINT_V07_ADDRESS);

        uint256 someStaticValue = 2517;

        address tokenIn = address(0xa11ce70c3170);
        address tokenOut = address(0xb0b70c3170);
        uint256 amountOutMin = 999;
        uint256 deadline = block.timestamp + 1000;
        uint256 fee = 500;

        Constraint[] memory constraints = new Constraint[](1);
        constraints[0] = Constraint({
            constraintType: ConstraintType.LTE,
            referenceData: abi.encode(bytes32(uint256(10_000)))
        });

        // represent the encoded call to acceptStruct() 
        // as per abi encoding rules
        InputParam[] memory inputParams = new InputParam[](8);

        // static param
        inputParams[0] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(someStaticValue),
            constraints: emptyConstraints
        });

        // offset, as per struct encoding
        inputParams[1] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(uint256(0x40)),
            constraints: emptyConstraints
        });

        // tokenIn
        inputParams[2] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(tokenIn),
            constraints: emptyConstraints
        });

        // tokenOut
        inputParams[3] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(tokenOut),
            constraints: emptyConstraints
        });

        // amountIn
        inputParams[4] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            paramData: abi.encode(address(dummyContract), abi.encodeWithSelector(DummyContract.B.selector, someStaticValue)),
            constraints: constraints
        });

        // amountOutMin
        inputParams[5] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(amountOutMin),
            constraints: emptyConstraints
        });


        // deadline
        inputParams[6] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(deadline),
            constraints: emptyConstraints
        });

        // fee
        inputParams[7] = InputParam({
            fetcherType: InputParamFetcherType.RAW_BYTES,
            paramData: abi.encode(fee),
            constraints: emptyConstraints
        });

        OutputParam[] memory outputParams = new OutputParam[](0);

        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(dummyContract),
            value: 0, // no value sent
            functionSig: DummyContract.acceptStruct.selector,
            inputParams: inputParams,
            outputParams: outputParams
        });

        vm.expectEmit(address(dummyContract));
        emit Uint256Emitted(someStaticValue*2); //amountIn
        emit Uint256Emitted(amountOutMin); //amountOutMin
        emit Uint256Emitted(deadline);
        emit Uint256Emitted(fee);
        emit AddressEmitted(tokenIn);
        emit AddressEmitted(tokenOut);
        IComposableExecution(address(account)).executeComposable(executions);

        vm.stopPrank();
    }
}
