// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {NodePaymaster} from "../../contracts/NodePaymaster.sol";

contract EmittingNodePaymaster is NodePaymaster {
    
    constructor(IEntryPoint _entryPoint, address _meeNodeAddress) NodePaymaster(_entryPoint, _meeNodeAddress) {}

    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 gasPrice) internal virtual override {
        uint256 preGas = gasleft();
        super._postOp(mode, context, actualGasCost, gasPrice);
        uint256 postGas = gasleft();
        // emit
    }
}