// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./Storage.sol";
import { CONSTRAINT_TYPE_EQ, CONSTRAINT_TYPE_GTE, CONSTRAINT_TYPE_LTE, CONSTRAINT_TYPE_IN } from "../types/Constants.sol";

import {console2} from "forge-std/console2.sol";

// Parameter type for composition
enum InputParamFetcherType {
    RAW_BYTES, // Already encoded bytes
    STATIC_CALL // Perform a static call

}

enum OutputParamFetcherType {
    EXEC_RESULT,
    STATIC_CALL
}

// Return value handling configuration
enum ParamValueType {
    UINT256,
    ADDRESS,
    BYTES32,
    BOOL
}

// Structure to define parameter composition
struct InputParam {
    InputParamFetcherType fetcherType; // How to fetch the parameter
    ParamValueType valueType; // What type of parameter to fetch
    bytes paramData;
    bytes constraints;
}

struct OutputParam {
    OutputParamFetcherType fetcherType; // How to fetch the parameter
    ParamValueType valueType; // What type of parameter to fetch
    bytes paramData;
}

struct ComposableExecution {
    address to;
    uint256 value;
    bytes4 functionSig;
    InputParam[] inputParams;
    OutputParam[] outputParams;
}

library ComposableExecutionLib {

    error InvalidComposerInstructions();
    error InvalidParameterEncoding();
    error StorageReadFailed();
    error InvalidReturnDataHandling();
    error InvalidOutputParamFetcherType();
    error ExecutionFailed();
    error InvalidConstraintType();

    function processInputs(InputParam[] calldata inputParams, bytes4 functionSig) internal view returns (bytes memory) {
        bytes memory composedCalldata = abi.encodePacked(functionSig);
        uint256 length = inputParams.length;
        for (uint256 i; i < length; i++) {
            composedCalldata = bytes.concat(composedCalldata, processInput(inputParams[i]));
        }
        return composedCalldata;
    }

    // TODO: change all abi.decodes to calldata slicing
    function processInput(InputParam calldata param) internal view returns (bytes memory) {
        if (param.fetcherType == InputParamFetcherType.RAW_BYTES) {
            return _validateConstraints(param.paramData, param.constraints);
        } else if (param.fetcherType == InputParamFetcherType.STATIC_CALL) {
            (address contractAddr, bytes memory callData) = abi.decode(param.paramData, (address, bytes));
            (bool success, bytes memory returnData) = contractAddr.staticcall(callData);
            if (!success) {
                revert ExecutionFailed();
            }
            return _validateConstraints(returnData, param.constraints);
        } else {
            revert InvalidParameterEncoding();
        }
    }

    function processOutputs(OutputParam[] calldata outputParams, bytes memory returnData, address account) internal {
        uint256 length = outputParams.length;
        for (uint256 i; i < length; i++) {
            processOutput(outputParams[i], returnData, account);
        }
    }

    function processOutput(OutputParam calldata param, bytes memory returnData, address account) internal {
        // TODO: What if function returns multiple values?
        // Or something that is not bytes32
        // Then returnData is not decodable as bytes32
        if (param.fetcherType == OutputParamFetcherType.EXEC_RESULT) {
            (address targetStorageContract, bytes32 targetSlot) = abi.decode(param.paramData, (address, bytes32));
            Storage(targetStorageContract).writeStorage({
                slot: targetSlot,
                value: abi.decode(returnData, (bytes32)),
                account: account
            });
        } else if (param.fetcherType == OutputParamFetcherType.STATIC_CALL) {
            (
                address sourceContract,
                bytes memory sourceCallData,
                address targetStorageContract,
                bytes32 targetStorageSlot
            ) = abi.decode(param.paramData, (address, bytes, address, bytes32));
            (bool outputSuccess, bytes memory outputReturnData) = sourceContract.staticcall(sourceCallData);
            if (!outputSuccess) {
                // TODO : USE OTHER ERROR
                revert ExecutionFailed();
            }
            Storage(targetStorageContract).writeStorage(targetStorageSlot, abi.decode(outputReturnData, (bytes32)), account);
        } else {
            revert InvalidOutputParamFetcherType();
        }
    }

    function _validateConstraints(bytes memory rawValue, bytes calldata constraints) private pure returns (bytes memory) {
        if (constraints.length == 0) { return rawValue; }
        bytes1 constraintType = bytes1(constraints[0:1]);
        bytes32 rawValueBytes32 = bytes32(rawValue);
        
        if (constraintType == CONSTRAINT_TYPE_EQ) {
            bytes32 constraintValue = bytes32(constraints[1:]);
            require (rawValueBytes32 == constraintValue, "EQ constraint not met.");
        } else if (constraintType == CONSTRAINT_TYPE_GTE) {
            bytes32 constraintValue = bytes32(constraints[1:]);
            require (rawValueBytes32 >= constraintValue, "GTE constraint not met.");
        }
        else if (constraintType == CONSTRAINT_TYPE_LTE) {
            bytes32 constraintValue = bytes32(constraints[1:]);
            require (rawValueBytes32 <= constraintValue, "LTE constraint not met.");
        }
        else if (constraintType == CONSTRAINT_TYPE_IN) {
            (bytes32 lowerBound, bytes32 upperBound) = abi.decode(constraints[1:], (bytes32, bytes32));
            require(rawValueBytes32 >= lowerBound && rawValueBytes32 <= upperBound, "IN constraint not met");
        }
        else {
            revert InvalidConstraintType();
        }

        return rawValue;
    }

}
