// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    InputParam,
    OutputParam,
    ComposableExecution,
    ComposableExecutionLib
} from "contracts/composability/ComposableExecutionLib.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";

abstract contract ComposableExecutionBase is IComposableExecution {
    using ComposableExecutionLib for InputParam[];
    using ComposableExecutionLib for OutputParam[];

    error InsufficientMsgValue();

    // Feel free to override it to introduce additional access control or other checks
    function executeComposable(ComposableExecution[] calldata executions) external payable virtual;

    function _executeComposable(ComposableExecution[] calldata executions) internal {
        uint256 length = executions.length;
        uint256 aggregateValue;
        for (uint256 i; i < length; i++) {
            ComposableExecution calldata execution = executions[i];
            bytes memory composedCalldata = execution.inputParams.processInputs(execution.functionSig);
            bytes memory returnData;
            if (execution.to != address(0)) {
                aggregateValue += execution.value;
                require(msg.value >= aggregateValue, InsufficientMsgValue());
                returnData = _executeAction(execution.to, execution.value, composedCalldata);
            } else {
                returnData = new bytes(0);
            }
            execution.outputParams.processOutputs(returnData, address(this));
        }
    }

    // Override this in the account
    // using account's native execution approach
    function _executeAction(address to, uint256 value, bytes memory data)
        internal
        virtual
        returns (bytes memory returnData);
}
