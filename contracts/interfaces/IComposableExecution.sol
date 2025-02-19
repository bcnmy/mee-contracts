// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.23;

import {InputParam, OutputParam} from "contracts/composability/ComposableExecutionLib.sol";

interface IComposableExecution {
    
    function executeComposable(
        address to,
        uint256 value,
        bytes4 functionSig,
        InputParam[] calldata inputParams,
        OutputParam[] calldata outputParams
    ) external payable;

}
