// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@account-abstraction/interfaces/PackedUserOperation.sol";
import "@account-abstraction/core/Helpers.sol";
import "../util/EcdsaLib.sol";
import "../util/UserOpLib.sol";

library EcdsaValidatorLib {
    /**
     * This function parses the given userOpSignature into a Supertransaction signature
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the root supertransaction hash signed by the account owner's EOA
     *      2. is the userOp actually a part of the given supertransaction
     *
     * If both conditions are met - outside contract can be sure that the expected signer has indeed
     * approved the given userOp - and the userOp is successfully validate.
     *
     * @param userOp UserOp being validated.
     * @param parsedSignature Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes memory parsedSignature, address expectedSigner)
        internal
        view
        returns (uint256)
    {
        (
            bytes32 appendedHash,
            bytes32[] memory proof,
            uint48 lowerBoundTimestamp,
            uint48 upperBoundTimestamp,
            bytes memory userEcdsaSignature
        ) = abi.decode(parsedSignature, (bytes32, bytes32[], uint48, uint48, bytes));

        bytes32 calculatedUserOpHash = UserOpLib.getUserOpHash(userOp, lowerBoundTimestamp, upperBoundTimestamp);
        if (!EcdsaLib.isValidSignature(expectedSigner, appendedHash, userEcdsaSignature)) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(proof, appendedHash, calculatedUserOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        return _packValidationData(false, upperBoundTimestamp, lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address owner, bytes32 hash, bytes memory parsedSignature)
        internal
        pure
        returns (bool)
    {
        return EcdsaLib.isValidSignature(owner, hash, parsedSignature);
    }
}
