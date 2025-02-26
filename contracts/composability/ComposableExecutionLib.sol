// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./Storage.sol";

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

enum ConstraintType {
    EQ,
    GTE,
    LTE,
    IN
}

struct Constraint {
    ConstraintType constraintType;
    bytes referenceData;
}

// Structure to define parameter composition
struct InputParam {
    InputParamFetcherType fetcherType; // How to fetch the parameter
    ParamValueType valueType; // What type of parameter to fetch
    bytes paramData;
    Constraint[] constraints;
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

error ConstraintNotMet(ConstraintType constraintType);
error Output_StaticCallFailed();

library ComposableExecutionLib {
    error InvalidComposerInstructions();
    error InvalidParameterEncoding();
    error StorageReadFailed();
    error InvalidReturnDataHandling();
    error InvalidOutputParamFetcherType();
    error ExecutionFailed();
    error InvalidConstraintType();

    function processInputs(InputParam[] calldata inputParams, bytes4 functionSig)
        internal
        view
        returns (bytes memory)
    {
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
            _validateConstraints(param.paramData, param.constraints);
            return param.paramData;
        } else if (param.fetcherType == InputParamFetcherType.STATIC_CALL) {
            (address contractAddr, bytes memory callData) = abi.decode(param.paramData, (address, bytes));
            (bool success, bytes memory returnData) = contractAddr.staticcall(callData);
            if (!success) {
                revert ExecutionFailed();
            }
            _validateConstraints(returnData, param.constraints);
            return returnData;
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
        // only static types are supported for now as return values
        // can also process all the static return values which are before the first dynamic return value in the returnData
        if (param.fetcherType == OutputParamFetcherType.EXEC_RESULT) {
            (uint256 returnValues, address targetStorageContract, bytes32 targetStorageSlot) = abi.decode(param.paramData, (uint256, address, bytes32));
            _parseReturnDataAndWriteToStorage(returnValues, returnData, targetStorageContract, targetStorageSlot, account);
        // same for static calls
        } else if (param.fetcherType == OutputParamFetcherType.STATIC_CALL) {
            (   
                uint256 returnValues,
                address sourceContract,
                bytes memory sourceCallData,
                address targetStorageContract,
                bytes32 targetStorageSlot
            ) = abi.decode(param.paramData, (uint256, address, bytes, address, bytes32));
            (bool outputSuccess, bytes memory outputReturnData) = sourceContract.staticcall(sourceCallData);
            if (!outputSuccess) {
                revert Output_StaticCallFailed();
            }
            _parseReturnDataAndWriteToStorage(returnValues, outputReturnData, targetStorageContract, targetStorageSlot, account);
        } else {
            revert InvalidOutputParamFetcherType();
        }
    }

    function _validateConstraints(bytes memory rawValue, Constraint[] calldata constraints)
        private
        pure
    {
        if (constraints.length > 0) {
            for (uint256 i; i < constraints.length; i++) {
                Constraint memory constraint = constraints[i];
                bytes32 returnValue;
                assembly {
                    returnValue := mload(add(rawValue, add(0x20, mul(i, 0x20))))
                }
                if (constraint.constraintType == ConstraintType.EQ) {
                    require(returnValue == bytes32(constraint.referenceData), ConstraintNotMet(ConstraintType.EQ));
                } else if (constraint.constraintType == ConstraintType.GTE) {
                    require(returnValue >= bytes32(constraint.referenceData), ConstraintNotMet(ConstraintType.GTE));
                } else if (constraint.constraintType == ConstraintType.LTE) {
                    require(returnValue <= bytes32(constraint.referenceData), ConstraintNotMet(ConstraintType.LTE));
                } else if (constraint.constraintType == ConstraintType.IN) {
                    (bytes32 lowerBound, bytes32 upperBound) = abi.decode(constraint.referenceData, (bytes32, bytes32));
                    require(returnValue >= lowerBound && returnValue <= upperBound, ConstraintNotMet(ConstraintType.IN));
                } else {
                    revert InvalidConstraintType();
                }
            }
        }
    }

    function _parseReturnDataAndWriteToStorage(uint256 returnValues, bytes memory returnData, address targetStorageContract, bytes32 targetStorageSlot, address account) internal {
        for (uint256 i; i < returnValues; i++) {
            bytes32 value;
            assembly {
                value := mload(add(returnData, add(0x20, mul(i, 0x20))))
            }
            Storage(targetStorageContract).writeStorage({
                slot: keccak256(abi.encodePacked(targetStorageSlot, i)),
                value: value,
                account: account
            });
        }
    }
}
