// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {EcdsaLib} from "../util/EcdsaLib.sol";
import {MEEUserOpLib} from "../util/MEEUserOpLib.sol";
import "account-abstraction/core/Helpers.sol";

library SimpleValidatorLib {
    /**
     * This function parses the given userOpSignature into a Supertransaction signature
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the root supertransaction hash signed by the account owner's EOA
     *      2. is the userOp actually a part of the given supertransaction 
     *      by checking the leaf based on this userOpHash is a part of the merkle tree represented by root hash = superTxHash
     *
     * If both conditions are met - outside contract can be sure that the expected signer has indeed
     * approved the given userOp - and the userOp is successfully validate.
     *
     * @param userOpHash UserOp hash being validated.
     * @param signatureData Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    function validateUserOp(bytes32 userOpHash, bytes memory signatureData, address expectedSigner)
        internal
        view
        returns (uint256)
    {
        (
            bytes32 superTxHash,
            bytes32[] memory proof,
            uint48 lowerBoundTimestamp,
            uint48 upperBoundTimestamp,
            bytes memory secp256k1Signature
        ) = abi.decode(signatureData, (bytes32, bytes32[], uint48, uint48, bytes));

        bytes32 leaf  = MEEUserOpLib.getMEEUserOpHash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
        if (!EcdsaLib.isValidSignature(expectedSigner, superTxHash, secp256k1Signature)) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(proof, superTxHash, leaf)) {
            return SIG_VALIDATION_FAILED;
        }

        return _packValidationData(false, upperBoundTimestamp, lowerBoundTimestamp);
    }


    /**
     * @notice Validates the signature against the expected signer (owner)
     * @param owner Signer expected to be recovered
     * @param dataHash data hash being validated.
     * @param signatureData Signature
     */
    function validateSignatureForOwner(address owner, bytes32 dataHash, bytes memory signatureData)
        internal
        view 
        returns (bool)
    {
        (
            bytes32 superTxHash,
            bytes32[] memory proof,
            bytes memory secp256k1Signature
        ) = abi.decode(signatureData, (bytes32, bytes32[], bytes));
        
        if (!EcdsaLib.isValidSignature(owner, superTxHash, secp256k1Signature)) {
            return false;
        }

        if (!MerkleProof.verify(proof, superTxHash, dataHash)) {
            return false;
        }

        return true;
    }
}
