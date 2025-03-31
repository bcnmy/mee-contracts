// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {BaseNodePaymaster} from "../../contracts/BaseNodePaymaster.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * @dev Allows handleOps calls by any address allowed by owner().
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
contract MockNodePaymaster is BaseNodePaymaster {

    constructor(
        IEntryPoint _entryPoint,
        address _meeNodeAddress
    ) 
        payable 
        BaseNodePaymaster(_entryPoint, _meeNodeAddress)
    {}

    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {   
        // no access control
        return _validate(userOp, userOpHash, maxCost);
    }

}