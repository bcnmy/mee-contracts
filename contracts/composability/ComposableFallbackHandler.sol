// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// TODO: USE IT AS DEPENDENCY INSTEAD
import {IFallback} from "../interfaces/IERC7579Module.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import {ComposableExecutionLib, InputParam, OutputParam} from "contracts/composability/ComposableExecutionLib.sol";

/**
 * @title ComposableFallbackHandler
 * @dev A fallback handler module for Biconomy Nexus smart accounts that enables composable transactions
 */

// TODO: MAKE IT AN EXECUTOR AS WELL
contract ComposableFallbackHandler is IFallback, IComposableExecution {
    
    using ComposableExecutionLib for InputParam[];
    using ComposableExecutionLib for OutputParam[];
    
    // TODO: do we have this error in the dependencies somewhere?
    error ModuleAlreadyInitialized();
    
    error ExecutionFailed();

    /// @notice Mapping of smart account addresses to their respective module installation
    mapping(address => bool) public override isInitialized;

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
        bytes memory composedCalldata = inputParams.processInputs(functionSig);

        // 2) Execute the call with the fully built calldata
        // TODO: SHOULD USE msg.sender.executeFromExecutor()
        (bool success, bytes memory returnData) = to.call{value: value}(composedCalldata);
        if (!success) {
            revert ExecutionFailed();
        }

        // 3) Process outputs
        outputParams.processOutputs(returnData);
    }    

    function onInstall(bytes calldata data) external override {
        require(!isInitialized[msg.sender], ModuleAlreadyInitialized());
        isInitialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata data) external override {}

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        // TOODO: IMPORT AND USE CONSTANTS, FOR EXECUTOR AS WELL => TRUE
        return moduleTypeId == 3;
    }


}
