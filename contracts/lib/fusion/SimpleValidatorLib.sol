// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { EcdsaLib } from "../util/EcdsaLib.sol";
import { MEEUserOpHashLib } from "../util/MEEUserOpHashLib.sol";
import { SIG_VALIDATION_FAILED, _packValidationData } from "account-abstraction/core/Helpers.sol";
import { UserOperationLib } from "account-abstraction/core/UserOperationLib.sol";
// solhint-disable-next-line no-unused-import
import { HashLib, STATIC_HEAD_LENGTH } from "../util/HashLib.sol";

/**
 * @dev Library to validate the signature for MEE Simple mode
 *      In this mode, Fusion is not involved and just the superTx hash is signed
 */
library SimpleValidatorLib {
    /**
     * This function validates the signature for the MEE Simple mode
     * 1. Parse the signature data
     * 2. Compare the current item (mee user op) hash with the item hash at the index in the itemHashes array
     * 3. Get the superTx hash as per EIP-712
     * 4. Validate the signature against the superTx hash
     *
     * @param userOpHash UserOp hash being validated.
     * @param signatureData Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    // solhint-disable-next-line gas-named-return-values
    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata signatureData,
        address expectedSigner
    )
        internal
        view
        returns (uint256)
    {
        /*
         * packedSignatureData layout :
         * ======== static head part : 0x61 (97) bytes========
         * ... static head part ...
         * ======== static tail for simple mode =====
         * uint256 = 32 bytes : packedTimestamps
         * packedTimestamps is expected to be in the following format:
         * lowerBoundTimestamp in the most significant 128 bits (left)
         * upperBoundTimestamp in the least significant 128 bits (right)
         * ======== dynamic tail  ==========
         * ... dynamic tail ...
         */
        (bytes32 outerTypeHash, uint256 itemIndex, bytes32[] calldata itemHashes, bytes calldata signature) =
            HashLib.parsePackedSigDataHead(signatureData);

        bytes32 packedTimestamps;
        assembly {
            packedTimestamps := calldataload(add(signatureData.offset, STATIC_HEAD_LENGTH))
        }
        (uint256 lowerBoundTimestamp, uint256 upperBoundTimestamp) = UserOperationLib.unpackUints(packedTimestamps);

        bytes32 currentItemHash =
            MEEUserOpHashLib.getMeeUserOpEip712Hash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);

        bytes32 superTxEip712Hash = HashLib.compareAndGetFinalHash(outerTypeHash, currentItemHash, itemIndex, itemHashes);
        if (superTxEip712Hash == bytes32(0)) {
            return SIG_VALIDATION_FAILED;
        }

        if (!EcdsaLib.isValidSignature(expectedSigner, superTxEip712Hash, signature)) {
            return SIG_VALIDATION_FAILED;
        }

        return _packValidationData(false, uint48(upperBoundTimestamp), uint48(lowerBoundTimestamp));
    }

    /**
     * @notice Validates the signature against the expected signer (owner)
     * @dev In this case everything is even simpler, as this interface expects
     * a ready hash to be provided as dataHash, we do not need to rehash
     * Task to rehash data and provide the dataHash lies on the protocol,
     * that requests isValidSignature/validateSignatureWithData
     *
     * @dev What we expect is that dataHash is a properly made in according to
     * the algorithm of getting the superTxEip712Hash.
     * Since this is the hash of the superTx entry, and superTx is a struct,
     * and the entry is a struct as well, according to EIP-712,
     * "the struct values are encoded recursively as hashStruct(value)".
     * So when the SuperTx data struct is hashed as per eip-712 on front-end,
     * the inner structs are also hashed as hashStruct(s : 𝕊) = keccak256(typeHash ‖ encodeData(s))
     * So this function expects protocol to build `dataHash` as describe above.
     * Which will be true for most cases.
     *
     * @param owner Signer expected to be recovered
     * @param dataHash the hash of the superTx entry that is being validated
     * @param signatureData Signature
     */
    // solhint-disable-next-line gas-named-return-values
    function validateSignatureForOwner(
        address owner,
        bytes32 dataHash,
        bytes calldata signatureData
    )
        internal
        view
        returns (bool)
    {
        (bytes32 outerTypeHash, uint256 itemIndex, bytes32[] calldata itemHashes, bytes calldata signature) =
            HashLib.parsePackedSigDataHead(signatureData);

        bytes32 superTxEip712Hash = HashLib.compareAndGetFinalHash(outerTypeHash, dataHash, itemIndex, itemHashes);
        if (superTxEip712Hash == bytes32(0)) {
            return false;
        }

        if (!EcdsaLib.isValidSignature(owner, superTxEip712Hash, signature)) {
            return false;
        }

        return true;
    }
}
