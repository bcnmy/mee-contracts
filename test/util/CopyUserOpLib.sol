// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";

/*
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
*/

library CopyUserOpLib {
    function deepCopy(PackedUserOperation memory userOp) internal view returns (PackedUserOperation memory newUserOp) {
        // copy every field of packedUserOp
        newUserOp.sender = userOp.sender;
        newUserOp.nonce = userOp.nonce;
        newUserOp.initCode = userOp.initCode;
        newUserOp.callData = userOp.callData;
        newUserOp.accountGasLimits = userOp.accountGasLimits;
        newUserOp.preVerificationGas = userOp.preVerificationGas;
        newUserOp.gasFees = userOp.gasFees;
        newUserOp.paymasterAndData = userOp.paymasterAndData;
        newUserOp.signature = userOp.signature;
    }
}
