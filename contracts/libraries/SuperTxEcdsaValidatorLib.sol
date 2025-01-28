// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {PermitValidatorLib} from "./fusion/PermitValidatorLib.sol";
import {TxValidatorLib} from "./fusion/TxValidatorLib.sol";
import {EcdsaValidatorLib} from "./fusion/EcdsaValidatorLib.sol";
import {UserOpValidatorLib} from "./fusion/UserOpValidatorLib.sol";
import {BytesLib} from "byteslib/BytesLib.sol";

import "forge-std/console2.sol";

/* enum SuperSignatureType {
    OFF_CHAIN,
    ON_CHAIN,
    ERC20_PERMIT,
    USEROP
}
 */
library SuperTxEcdsaValidatorLib {
    using BytesLib for bytes;

    uint8 constant SIG_TYPE_OFF_CHAIN = 0x00;
    uint8 constant SIG_TYPE_ON_CHAIN = 0x01;
    uint8 constant SIG_TYPE_ERC20_PERMIT = 0x02;
    // ...leave space for other sig types: ERC-7683, Permit2, etc
    uint8 constant SIG_TYPE_USEROP = 0xff;

/*     struct SuperSignature {
        SuperSignatureType signatureType;
        bytes signature;
    } */

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, address owner)
        internal
        returns (uint256)
    {
/*         SuperSignature memory decodedSig = decodeSignature(userOp.signature);

        // insert from previous code
        if (decodedSig.signatureType == SuperSignatureType.OFF_CHAIN) {
            return EcdsaValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.ON_CHAIN) {
            return TxValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.ERC20_PERMIT) {
            return PermitValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.USEROP) {
            return UserOpValidatorLib.validateUserOp(userOpHash, decodedSig.signature, owner);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        } */

        uint8 sigType = uint8(userOp.signature[0]);

        if (sigType == SIG_TYPE_OFF_CHAIN) {
            return EcdsaValidatorLib.validateUserOp(userOp, userOp.signature[1:], owner);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateUserOp(userOp, userOp.signature[1:], owner);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateUserOp(userOp, userOp.signature[1:], owner);
        } else if (sigType == SIG_TYPE_USEROP) {
            return UserOpValidatorLib.validateUserOp(userOpHash, userOp.signature[1:], owner);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        }
    }

    function validateSignatureForOwner(address owner, bytes32 hash, bytes calldata signature)
        internal
        pure
        returns (bool)
    {   
        uint8 sigType = uint8(signature[0]);

        if (sigType == SIG_TYPE_OFF_CHAIN) {
            return EcdsaValidatorLib.validateSignatureForOwner(owner, hash, signature[1:]);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateSignatureForOwner(owner, hash, signature[1:]);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateSignatureForOwner(owner, hash, signature[1:]);
        } else if (sigType == SIG_TYPE_USEROP) {
            return UserOpValidatorLib.validateSignatureForOwner(owner, hash, signature[1:]);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        }
        /* SuperSignature memory decodedSig = decodeSignature(signature);

        if (decodedSig.signatureType == SuperSignatureType.OFF_CHAIN) {
            return EcdsaValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.ON_CHAIN) {
            return TxValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.ERC20_PERMIT) {
            return PermitValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.USEROP) {
            return UserOpValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        } */
    }

}
