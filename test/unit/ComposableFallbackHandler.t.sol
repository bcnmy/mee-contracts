// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "contracts/composability/ComposableExecutionModule.sol";
import "contracts/composability/Storage.sol";
import "contracts/interfaces/IComposableExecution.sol";
import "contracts/composability/ComposableExecutionLib.sol";
import "test/mock/MockAccount.sol";

contract DummyContract {
    function A() external pure returns (uint256) {
        return 42;
    }

    function B(uint256 value) external pure returns (uint256) {
        // Return the input value multiplied by 2
        return value * 2;
    }
}

contract ComposableFallbackHandlerTest is Test {
    ComposableExecutionModule public handler;
    Storage public storageContract;
    DummyContract public dummyContract;
    MockAccount public mockAccount;

    address public eoa = address(0x11ce);
    bytes32 public constant SLOT_A = keccak256("SLOT_A");
    bytes32 public constant SLOT_B = keccak256("SLOT_B");

    function setUp() public {
        // Deploy contracts
        storageContract = new Storage(address(0));
        handler = new ComposableExecutionModule();
        dummyContract = new DummyContract();
        mockAccount = new MockAccount({
            _validator: address(0),
            _handler: address(handler)
        });
        // Fund EOA
        vm.deal(eoa, 100 ether);
    }

    function testComposableFlow() public {
        // msg.sender is this contract (emulate SA)
        // tx.origin is ENTRY_POINT_V07 as if it has called the contract
        vm.startPrank(ENTRY_POINT_V07);

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
        // Call function A through mockAccount=>handler
        mockAccount.executeComposable(executions);
        

        // Verify the result (42) was stored correctly
        bytes32 storedValueA = storageContract.readStorage(address(mockAccount), SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");

        // Step 2: Call function B using the stored value from A
        InputParam[] memory inputParamsB = new InputParam[](1);
        inputParamsB[0] = InputParam({
            fetcherType: InputParamFetcherType.STATIC_CALL,
            valueType: ParamValueType.UINT256,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (address(mockAccount), SLOT_A)))
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
        // Call function B through mockAccount=>handler
        mockAccount.executeComposable(executionsB);

        // Verify the result (84 = 42 * 2) was stored correctly
        bytes32 storedValueB = storageContract.readStorage(address(mockAccount), SLOT_B);
        assertEq(uint256(storedValueB), 84, "Function B result not stored correctly");

        //vm.stopPrank();
    }
}
