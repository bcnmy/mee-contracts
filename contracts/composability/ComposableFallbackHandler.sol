// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IFallback} from "../interfaces/IERC7579Module.sol";
import "./Storage.sol";

/**
 * @title ComposableFallbackHandler
 * @dev A fallback handler module for Biconomy Nexus smart accounts that enables composable transactions
 */
contract ComposableFallbackHandler is IFallback {
    error InvalidComposerInstructions();
    error ExecutionFailed();
    error InvalidParameterEncoding();
    error StorageReadFailed();
    error InvalidReturnDataHandling();
    error ModuleAlreadyInitialized();
    error InvalidOutputParamFetcherType();

    /// @notice Mapping of smart account addresses to their respective module installation
    mapping(address => bool) public override isInitialized;

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

    /**
     * @notice Executes a composable transaction with dynamic parameter composition and return value handling
     * @param to The target address for the transaction
     * @param value The amount of native tokens to send
     * @param functionSig The 4-byte function signature
     * @param inputParams Array of InputParam structs defining how to compose the calldata
     * @param outputParams Array of OutputParam structs defining how to store the outputs after the execution
     */
    function executeComposable(
        address to,
        uint256 value,
        bytes4 functionSig,
        InputParam[] calldata inputParams,
        OutputParam[] calldata outputParams
    ) external payable {
        bytes memory composedCalldata = abi.encodePacked(functionSig);

        // 1) Process inputs (dynamic param injection)
        for (uint256 i = 0; i < inputParams.length; i++) {
            bytes memory paramData = processInput(inputParams[i]);
            composedCalldata = bytes.concat(composedCalldata, paramData);
        }

        // 2) Execute the call with the fully built calldata
        (bool success, bytes memory returnData) = to.call{value: value}(composedCalldata);
        if (!success) {
            revert ExecutionFailed();
        }

        // 3) Process outputs
        for (uint256 i = 0; i < outputParams.length; i++) {
            processOutput(outputParams[i], returnData);
        }
    }

    /**
     * @dev Composes a single parameter based on its type and source
     * @param param The Parameter struct containing composition instructions
     * @return The encoded parameter bytes
     */
    function processInput(InputParam calldata param) internal view returns (bytes memory) {
        if (param.fetcherType == InputParamFetcherType.RAW_BYTES) {
            return param.paramData;
        } else {
            bytes memory rawValue;
            if (param.fetcherType == InputParamFetcherType.STORAGE_READ) {
            (
                address storageContract,
                bytes32 storageSlot
            ) = abi.decode(param.paramData, (address, bytes32));
            rawValue = abi.encodePacked(getValueAt(storageContract, storageSlot));
            } else if (param.fetcherType == InputParamFetcherType.STATIC_CALL) {
                (
                    address contractAddr,
                    bytes memory callData
                ) = abi.decode(param.paramData, (address, bytes));
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

    function processOutput(OutputParam calldata param, bytes memory returnData) internal {
        if (param.fetcherType == OutputParamFetcherType.EXEC_RESULT) {
            (
                address targetStorageContract,
                bytes32 targetSlot
            ) = abi.decode(param.paramData, (address, bytes32));
            Storage(targetStorageContract).writeStorage(targetSlot, abi.decode(returnData, (bytes32)));
        } else if (param.fetcherType == OutputParamFetcherType.STORAGE_READ) {
            (
                address sourceStorageContract,
                bytes32 sourceStorageSlot,
                address targetStorageContract,
                bytes32 targetStorageSlot
            ) = abi.decode(param.paramData, (address, bytes32, address, bytes32));
            Storage(targetStorageContract).writeStorage(targetStorageSlot, getValueAt(sourceStorageContract, sourceStorageSlot));
        } else if (param.fetcherType == OutputParamFetcherType.STATIC_CALL) {
            (
                address targetStorageContract,
                bytes32 targetStorageSlot,
                address sourceContract,
                bytes memory sourceCallData
            ) = abi.decode(param.paramData, (address, bytes32, address, bytes));
            (bool outputSuccess, bytes memory outputReturnData) = sourceContract.staticcall(sourceCallData);
            if (!outputSuccess) {
                revert ExecutionFailed();
            }
            Storage(targetStorageContract).writeStorage(targetStorageSlot, abi.decode(outputReturnData, (bytes32)));
        } else {
            revert InvalidOutputParamFetcherType();
        }
    }

    function onInstall(bytes calldata data) external override {
        require(!isInitialized[msg.sender], ModuleAlreadyInitialized());
        isInitialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata data) external override {}

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 3;
    }

     function getValueAt(address contractAddr, bytes32 slot) internal view returns (bytes32) {
        bytes32 value;
        assembly {
            // Switch context to read storage from contractAddr
            let success := staticcall(gas(), contractAddr, 0x00, 0x00, 0x00, 0x00)
            if iszero(success) {
                revert(0, 0)
            }
            // Read storage slot from the target contract
            value := sload(slot)
        }
        return value;
    }
}
