// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.23;

import {InputParam, OutputParam, ComposableExecution} from "contracts/composability/ComposableExecutionLib.sol";

interface IComposableExecution {
    
    function executeComposable(ComposableExecution[] calldata executions) external payable;

}
