// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IExecutor} from "erc7579/interfaces/IERC7579Module.sol";
import {IERC7579Account} from "erc7579/interfaces/IERC7579Account.sol";
import {ModeLib} from "erc7579/lib/ModeLib.sol";
import {ExecutionLib} from "erc7579/lib/ExecutionLib.sol";
import {ERC7579FallbackBase} from "@rhinestone/module-bases/src/ERC7579FallbackBase.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import {
    ComposableExecutionLib,
    InputParam,
    OutputParam,
    ComposableExecution
} from "contracts/composability/ComposableExecutionLib.sol";

/**
 * @title Composable Execution Module: Executor and Fallback
 * @dev A module for ERC-7579 accounts that enables composable transactions execution
 */
contract ComposableExecutionModule is IComposableExecution, IExecutor, ERC7579FallbackBase {

    address public constant ENTRY_POINT_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    using ComposableExecutionLib for InputParam[];
    using ComposableExecutionLib for OutputParam[];

    error OnlyEntryPointOrAccount();
    error InsufficientMsgValue();
    error ZeroAddressNotAllowed();
    /// @notice Mapping of smart account addresses to the EP address
    mapping(address => address) private entryPoints;

    /**
     * @notice Executes a composable transaction with dynamic parameter composition and return value handling
     * @dev As per ERC-7579 account MUST append original msg.sender address to the calldata in a way specified by ERC-2771
     */
    function executeComposable(ComposableExecution[] calldata executions) external payable {
        // access control
        address sender = _msgSender();
        // in most cases, only first condition (against constant) will be checked
        // so no extra sloads
        require(sender == ENTRY_POINT_V07_ADDRESS || 
                sender == entryPoints[msg.sender] || 
                sender == msg.sender, OnlyEntryPointOrAccount());

        // we can not use erc-7579 batch mode here because we may need to compose
        // the next call in the batch based on the execution result of the previous call
        uint256 length = executions.length;
        uint256 aggregateValue;
        for (uint256 i; i < length; i++) {
            ComposableExecution calldata execution = executions[i];
            bytes memory composedCalldata = execution.inputParams.processInputs(execution.functionSig);
            bytes[] memory returnData; 
            if (execution.to != address(0)) {
                aggregateValue += execution.value;
                require(msg.value >= aggregateValue, InsufficientMsgValue());
                returnData = IERC7579Account(msg.sender).executeFromExecutor{value: execution.value}({
                    mode: ModeLib.encodeSimpleSingle(),
                    executionCalldata: ExecutionLib.encodeSingle(execution.to, execution.value, composedCalldata)
                });
            } else {
                returnData = new bytes[](1);
                returnData[0] = "";
            }
            execution.outputParams.processOutputs(returnData[0], msg.sender);
        }
        // Return any excess msg.value to the Smart Account
        assembly {
            if gt(callvalue(), aggregateValue) {
                let ptr := mload(0x40)
                let excess := sub(callvalue(), aggregateValue)
                let success := call(gas(), caller(), excess, 0, 0, ptr, returndatasize())
                if iszero(success) {
                    revert(ptr, returndatasize())
                }
                mstore(0x40, add(ptr, returndatasize()))
            }
        }
    }

    /// @dev sets the entry point for the account
    function setEntryPoint(address _entryPoint) external {
        require(_entryPoint != address(0), ZeroAddressNotAllowed());
        entryPoints[msg.sender] = _entryPoint;
    }
        
    /// @dev returns the entry point address
    function getEntryPoint(address account) external view returns (address) {
        return entryPoints[account] == address(0) ? ENTRY_POINT_V07_ADDRESS : entryPoints[account];
    }

    /// @dev called when the module is installed
    function onInstall(bytes calldata data) external override {
        require(entryPoints[msg.sender] == address(0), AlreadyInitialized(msg.sender));
        if (data.length >= 20) {
            entryPoints[msg.sender] = address(bytes20(data[0:20]));
        }
    }

    /// @dev returns true if the module is initialized for the given account
    function isInitialized(address account) external view returns (bool) {
        return entryPoints[account] != address(0);
    }

    /// @dev called when the module is uninstalled
    function onUninstall(bytes calldata data) external override {
        delete entryPoints[msg.sender];
    }

    /// @dev Reports that this module is an executor and a fallback module
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == TYPE_EXECUTOR || moduleTypeId == TYPE_FALLBACK;
    }
}
