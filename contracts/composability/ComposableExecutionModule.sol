// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// TODO: USE IT AS DEPENDENCY INSTEAD
import {IExecutor} from "erc7579/interfaces/IERC7579Module.sol";
import {IERC7579Account} from "erc7579/interfaces/IERC7579Account.sol";
import {ModeLib} from "erc7579/lib/ModeLib.sol";
import {ExecutionLib} from "erc7579/lib/ExecutionLib.sol";
import {ERC7579FallbackBase} from "@rhinestone/module-bases/src/ERC7579FallbackBase.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";
import {ComposableExecutionLib, InputParam, OutputParam, ComposableExecution} from "contracts/composability/ComposableExecutionLib.sol";
import {IGetEntryPoint} from "contracts/interfaces/IGetEntryPoint.sol";

address constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

/**
 * @title Composable Execution Module: Executor and Fallback
 * @dev A module for ERC-7579 accounts that enables composable transactions execution
 */

contract ComposableExecutionModule is IComposableExecution, IExecutor, ERC7579FallbackBase {
    
    using ComposableExecutionLib for InputParam[];
    using ComposableExecutionLib for OutputParam[];

    error ModuleAlreadyInitialized();    
    error ExecutionFailed();
    error OnlyEntryPointOrAccount();
    error InsufficientMsgValue();
    /// @notice Mapping of smart account addresses to their respective module installation
    mapping(address => bool) public override isInitialized;

    /**
     * @notice Executes a composable transaction with dynamic parameter composition and return value handling
     * @dev As per ERC-7579 account MUST append original msg.sender address to the calldata as per ERC-2771
     */
    function executeComposable(ComposableExecution[] calldata executions) external payable {
        // access control
        address sender = _msgSender();
        require(sender == _getEntryPoint() || sender == msg.sender, OnlyEntryPointOrAccount());

        // we can not use erc-7579 batch mode here because we may need to compose 
        // the next call in the batch based on the execution result of the previous call
        uint256 length = executions.length;
        uint256 aggregateValue = 0;
        for (uint256 i; i < length; i++) {
            ComposableExecution calldata execution = executions[i];
            aggregateValue += execution.value;
            require(msg.value >= aggregateValue, InsufficientMsgValue());
            bytes memory composedCalldata = execution.inputParams.processInputs(execution.functionSig);
            bytes[] memory returnData = IERC7579Account(msg.sender).executeFromExecutor(
                ModeLib.encodeSimpleSingle(), 
                ExecutionLib.encodeSingle(execution.to, execution.value, composedCalldata)
            );
            execution.outputParams.processOutputs(returnData[0], msg.sender);
        }
    }

    /// @dev reverts if msg.sender is an EOA which is expected
    function _getEntryPoint() internal view returns (address) {
        try IGetEntryPoint(msg.sender).entryPoint() returns (address ep) {
            return ep;
        } catch {
            return ENTRY_POINT_V07;
        }
    }

    function onInstall(bytes calldata data) external override {
        require(!isInitialized[msg.sender], ModuleAlreadyInitialized());
        isInitialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata data) external override {}

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == TYPE_EXECUTOR || moduleTypeId == TYPE_FALLBACK;
    }


}
