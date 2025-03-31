// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {BaseNodePaymaster} from "../../contracts/BaseNodePaymaster.sol";

contract EmittingNodePaymaster is BaseNodePaymaster {

    event postOpGasEvent(uint256 gasCostPrePostOp, uint256 gasSpentInPostOp);
    
    constructor(IEntryPoint _entryPoint, address _meeNodeAddress) BaseNodePaymaster(_entryPoint, _meeNodeAddress) {}

    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 gasPrice) internal virtual override {
        uint256 preGas = gasleft();
        super._postOp(mode, context, actualGasCost, gasPrice);
        // emit event
        emit postOpGasEvent(actualGasCost, preGas - gasleft());
    }
}