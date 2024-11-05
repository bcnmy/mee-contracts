// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@account-abstraction/interfaces/PackedUserOperation.sol";
import "@account-abstraction/core/Helpers.sol";
import "../util/EcdsaLib.sol";

library UserOpValidatorLib {

    /**
     * Standard userOp validator - validates by simply checking if the userOpHash was signed by the account's EOA owner. 
     *
     * @param userOpHash userOpHash being validated.
     * @param parsedSignature Signature
     * @param expectedSigner Signer expected to be recovered
     */
    function validateUserOp(bytes32 userOpHash, bytes memory parsedSignature, address expectedSigner) internal pure returns (uint256) {
        if (!EcdsaLib.isValidSignature(expectedSigner, userOpHash, parsedSignature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 hash, bytes memory parsedSignature) internal pure returns (bool) {
        return EcdsaLib.isValidSignature(expectedSigner, hash, parsedSignature);
    }
}
