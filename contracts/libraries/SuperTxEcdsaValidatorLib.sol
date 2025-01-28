// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {PermitValidatorLib} from "./fusion/PermitValidatorLib.sol";
import {TxValidatorLib} from "./fusion/TxValidatorLib.sol";
import {EcdsaValidatorLib} from "./fusion/EcdsaValidatorLib.sol";
import {UserOpValidatorLib} from "./fusion/UserOpValidatorLib.sol";
import {BytesLib} from "byteslib/BytesLib.sol";

library SuperTxEcdsaValidatorLib {
    using BytesLib for bytes;

    bytes4 constant SIG_TYPE_OFF_CHAIN = 0x177eee00;
    bytes4 constant SIG_TYPE_ON_CHAIN = 0x177eee01;
    bytes4 constant SIG_TYPE_ERC20_PERMIT = 0x177eee02;
    // ...other sig types: ERC-7683, Permit2, etc

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, address owner)
        internal
        returns (uint256)
    {
        bytes4 sigType = bytes4(userOp.signature[0:4]);


        if (sigType == SIG_TYPE_OFF_CHAIN) {
            return EcdsaValidatorLib.validateUserOp(userOp, userOp.signature[5:], owner);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateUserOp(userOp, userOp.signature[5:], owner);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateUserOp(userOp, userOp.signature[5:], owner);
        } else {
            // fallback flow => non MEE flow => no prefix
            return UserOpValidatorLib.validateUserOp(userOpHash, userOp.signature, owner);
        }
    }

    function validateSignatureForOwner(address owner, bytes32 hash, bytes calldata signature)
        internal
        pure
        returns (bool)
    {   
        bytes4 sigType = bytes4(signature[0:4]);

        if (sigType == SIG_TYPE_OFF_CHAIN) {
            return EcdsaValidatorLib.validateSignatureForOwner(owner, hash, signature[5:]);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateSignatureForOwner(owner, hash, signature[5:]);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateSignatureForOwner(owner, hash, signature[5:]);
        } else {
            // fallback flow => non MEE flow => no prefix
            return UserOpValidatorLib.validateSignatureForOwner(owner, hash, signature);
        } 
    }

}
