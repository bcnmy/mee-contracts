// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./Storage.sol";

// Parameter type for composition
enum InputParamFetcherType {
    RAW_BYTES, // Already encoded bytes
    STORAGE_READ, // Read from storage
    STATIC_CALL // Perform a static call

}

enum OutputParamFetcherType {
    EXEC_RESULT,
    STORAGE_READ,
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

    function processInputs(InputParam[] calldata inputParams, bytes4 functionSig) internal view returns (bytes memory) {
        bytes memory composedCalldata = abi.encodePacked(functionSig);
        uint256 length = inputParams.length;
        for (uint256 i; i < length; i++) {
            composedCalldata = bytes.concat(composedCalldata, processInput(inputParams[i]));
        }
        return composedCalldata;
    }
    
    function processInput(InputParam calldata param) internal view returns (bytes memory) {
        if (param.fetcherType == InputParamFetcherType.RAW_BYTES) {
            return param.paramData;
        } else {
            bytes memory rawValue;
            if (param.fetcherType == InputParamFetcherType.STORAGE_READ) {
                (address storageContract, bytes32 storageSlot) = abi.decode(param.paramData, (address, bytes32));
                rawValue = abi.encodePacked(_getValueAt(storageContract, storageSlot));
            } else if (param.fetcherType == InputParamFetcherType.STATIC_CALL) {
                (address contractAddr, bytes memory callData) = abi.decode(param.paramData, (address, bytes));
                (bool success, bytes memory returnData) = contractAddr.staticcall(callData);
                if (!success) {
                    revert ExecutionFailed();
                }
                rawValue = returnData;
            } else {
                revert InvalidParameterEncoding();
            }

            if (param.valueType == ParamValueType.UINT256) {
                return abi.encodePacked(uint256(bytes32(rawValue)));
            } else if (param.valueType == ParamValueType.ADDRESS) {
                return abi.encodePacked(address(uint160(uint256(bytes32(rawValue)))));
            } else if (param.valueType == ParamValueType.BYTES32) {
                return rawValue;
            } else if (param.valueType == ParamValueType.BOOL) {
                return abi.encodePacked(uint256(bytes32(rawValue)) != 0);
            } else {
                revert InvalidParameterEncoding();
            }
        }
    }

    function processOutputs(OutputParam[] calldata outputParams, bytes memory returnData, address account) internal {
        uint256 length = outputParams.length;
        for (uint256 i; i < length; i++) {
            processOutput(outputParams[i], returnData, account);
        }
    }

    function processOutput(OutputParam calldata param, bytes memory returnData, address account) internal {
        if (param.fetcherType == OutputParamFetcherType.EXEC_RESULT) {
            (address targetStorageContract, bytes32 targetSlot) = abi.decode(param.paramData, (address, bytes32));
            Storage(targetStorageContract).writeStorage(targetSlot, abi.decode(returnData, (bytes32)), account);
        } else if (param.fetcherType == OutputParamFetcherType.STORAGE_READ) {
            (
                address sourceStorageContract,
                bytes32 sourceStorageSlot,
                address targetStorageContract,
                bytes32 targetStorageSlot
            ) = abi.decode(param.paramData, (address, bytes32, address, bytes32));
            Storage(targetStorageContract).writeStorage(
                targetStorageSlot, _getValueAt(sourceStorageContract, sourceStorageSlot), account
            );
        } else if (param.fetcherType == OutputParamFetcherType.STATIC_CALL) {
            (
                address targetStorageContract,
                bytes32 targetStorageSlot,
                address sourceContract,
                bytes memory sourceCallData
            ) = abi.decode(param.paramData, (address, bytes32, address, bytes));
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

    function _getValueAt(address contractAddr, bytes32 slot) private view returns (bytes32) {
        bytes32 value;
        assembly {
            // Switch context to read storage from contractAddr
            let success := staticcall(gas(), contractAddr, 0x00, 0x00, 0x00, 0x00)
            if iszero(success) { revert(0, 0) }
            // Read storage slot from the target contract
            value := sload(slot)
        }
        return value;
    }

}
