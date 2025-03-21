// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {NodePaymaster} from "../../contracts/NodePaymaster.sol";

contract EmittingNodePaymaster is NodePaymaster {
    
    constructor(address _entryPoint, address _meeNodeAddress) NodePaymaster(_entryPoint, _meeNodeAddress) {}

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 gasPrice) external {
        uint256 preGas = gasleft();
        super.postOp(mode, context, actualGasCost, gasPrice);
        uint256 postGas = gasleft();
        // emit
    }
}