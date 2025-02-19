// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// import lib
import {InputParam, OutputParam, ComposableExecutionLib} from "contracts/composability/ComposableExecutionLib.sol";
// import interface 
import {IComposableExecution} from "contracts/interfaces/IComposableExecution.sol";

contract ComposableExecutionBase is IComposableExecution {

    function executeComposable(
        address to,
        uint256 value,
        bytes4 functionSig,
        InputParam[] calldata inputParams,
        OutputParam[] calldata outputParams
    ) external payable {
        // check msg.value

    }


    // does it have to return the result?
    function _executeAction(
        address to, 
        uint256 value, 
        bytes calldata data
    ) internal virtual returns (bool success, bytes memory result) {
        (success, result) = to.call{value: value}(data);
    }


}


