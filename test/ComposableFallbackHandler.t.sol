// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/composability/ComposableFallbackHandler.sol";
import "../contracts/composability/Storage.sol";

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
    ComposableFallbackHandler public handler;
    Storage public storageContract;
    DummyContract public dummyContract;

    address public eoa = address(0x1);
    bytes32 public constant SLOT_A = keccak256("SLOT_A");
    bytes32 public constant SLOT_B = keccak256("SLOT_B");

    function setUp() public {
        // Deploy contracts
        storageContract = new Storage(address(0));
        handler = new ComposableFallbackHandler();
        dummyContract = new DummyContract();

        // Fund EOA
        vm.deal(eoa, 100 ether);
    }

    function testComposableFlow() public {
        vm.startPrank(eoa);
        
        // Step 1: Call function A and store its result
        // Prepare return value config for function A
        ComposableFallbackHandler.InputParam[] memory inputParamsA = new ComposableFallbackHandler.InputParam[](0);

        ComposableFallbackHandler.OutputParam[] memory outputParamsA = new ComposableFallbackHandler.OutputParam[](1);
        outputParamsA[0] = ComposableFallbackHandler.OutputParam({
            fetcherType: ComposableFallbackHandler.OutputParamFetcherType.EXEC_RESULT,
            valueType: ComposableFallbackHandler.ParamValueType.UINT256,
            paramData: abi.encode(storageContract, SLOT_A)
        });

        // Call function A through handler
        handler.executeComposable(
            address(dummyContract),
            0, // no value sent
            DummyContract.A.selector,
            inputParamsA, // no input parameters needed
            outputParamsA // store output of the function A() to the storage
        );

        // Verify the result (42) was stored correctly
        bytes32 storedValueA = storageContract.readStorage(address(handler), SLOT_A);
        assertEq(uint256(storedValueA), 42, "Function A result not stored correctly");

        // Step 2: Call function B using the stored value from A
        ComposableFallbackHandler.InputParam[] memory inputParamsB = new ComposableFallbackHandler.InputParam[](1);
        inputParamsB[0] = ComposableFallbackHandler.InputParam({
            fetcherType: ComposableFallbackHandler.InputParamFetcherType.STATIC_CALL,
            valueType: ComposableFallbackHandler.ParamValueType.UINT256,
            paramData: abi.encode(storageContract, abi.encodeCall(Storage.readStorage, (address(handler), SLOT_A)))
        });

        // Prepare return value config for function B
        ComposableFallbackHandler.OutputParam[] memory outputParamsB = new ComposableFallbackHandler.OutputParam[](1);
        outputParamsB[0] = ComposableFallbackHandler.OutputParam({
            fetcherType: ComposableFallbackHandler.OutputParamFetcherType.EXEC_RESULT,
            valueType: ComposableFallbackHandler.ParamValueType.UINT256,
            paramData: abi.encode(storageContract, SLOT_B)
        });

        // Call function B through handler
        handler.executeComposable(
            address(dummyContract),
            0, // no value sent
            DummyContract.B.selector,
            inputParamsB,
            outputParamsB
        );

        // Verify the result (84 = 42 * 2) was stored correctly
        bytes32 storedValueB = storageContract.readStorage(address(handler), SLOT_B);
        assertEq(uint256(storedValueB), 84, "Function B result not stored correctly");

        vm.stopPrank();
    }
}
