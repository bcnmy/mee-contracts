// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {InputParam, OutputParam, ComposableExecution, ComposableExecutionLib} from "contracts/composability/ComposableExecutionLib.sol";
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";

contract ComposableExecutionBase is IComposableExecution {

    using ComposableExecutionLib for InputParam[];
    using ComposableExecutionLib for OutputParam[];

    error InsufficientMsgValue();

    function executeComposable(ComposableExecution[] calldata executions) external payable {
        // we can not use erc-7579 batch mode here because we may need to compose 
        // the next call in the batch based on the execution result of the previous call
        uint256 length = executions.length;
        uint256 aggregateValue = 0;
        for (uint256 i; i < length; i++) {
            ComposableExecution calldata execution = executions[i];
            aggregateValue += execution.value;
            require(msg.value >= aggregateValue, InsufficientMsgValue());
            bytes memory composedCalldata = execution.inputParams.processInputs(execution.functionSig);
            bytes memory returnData = _executeAction(execution.to, execution.value, composedCalldata);
            execution.outputParams.processOutputs(returnData);
        }
    }

    // Override this in the account
    // using account's native execution approach
    function _executeAction(
        address to, 
        uint256 value, 
        bytes memory data
    ) internal virtual returns (bytes memory returnData) {}

}


