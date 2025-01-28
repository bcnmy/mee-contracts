// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "account-abstraction/interfaces/PackedUserOperation.sol";
import "account-abstraction/core/Helpers.sol";
import "../../interfaces/IERC20Permit.sol";
import "../util/EcdsaLib.sol";
import "../util/UserOpLib.sol";

library PermitValidatorLib {
    uint8 constant EIP_155_MIN_V_VALUE = 37;

    using MessageHashUtils for bytes32;

    struct DecodedErc20PermitSig {
        IERC20Permit token;
        address spender;
        bytes32 permitTypehash;
        bytes32 domainSeparator;
        uint256 amount;
        uint256 chainId;
        uint256 nonce;
        bool isPermitTx;
        bytes32 appendedHash;
        bytes32[] proof;
        uint48 lowerBoundTimestamp;
        uint48 upperBoundTimestamp;
        uint256 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * This function parses the given userOpSignature into a DecodedErc20PermitSig data structure.
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the expected hash found in the signed Permit message's deadline field?
     *      2. is the recovered message signer equal to the expected signer?
     *
     * If both conditions are met - outside contract can be sure that the expected signer has indeed
     * approved the given hash by signing a given Permit message.
     *
     * NOTES: This function will revert if either of following is met:
     *    1. the userOpSignature couldn't be abi.decoded into a valid DecodedErc20PermitSig struct as defined in this contract
     *    2. extracted hash wasn't equal to the provided expected hash
     *    3. recovered Permit message signer wasn't equal to the expected signer
     *
     * Returns true if the expected signer did indeed approve the given expectedHash by signing an on-chain transaction.
     * In that case, the function will also perform the Permit approval on the given token in case the
     * isPermitTx flag was set to true in the decoded signature struct.
     *
     * @param userOp UserOp being validated.
     * @param parsedSignature Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes memory parsedSignature, address expectedSigner)
        internal
        returns (uint256)
    {
        DecodedErc20PermitSig memory decodedSig = abi.decode(parsedSignature, (DecodedErc20PermitSig));

        bytes32 userOpHash =
            UserOpLib.getUserOpHash(userOp, decodedSig.lowerBoundTimestamp, decodedSig.upperBoundTimestamp);

        uint8 vAdjusted = _adjustV(decodedSig.v);
        uint256 deadline = uint256(decodedSig.appendedHash);

        bytes32 structHash = keccak256(
            abi.encode(
                decodedSig.permitTypehash,
                expectedSigner,
                decodedSig.spender,
                decodedSig.amount,
                decodedSig.nonce,
                deadline
            )
        );

        bytes32 signedDataHash = _hashTypedDataV4(structHash, decodedSig.domainSeparator);
        bytes memory signature = abi.encodePacked(decodedSig.r, decodedSig.s, vAdjusted);

        if (!EcdsaLib.isValidSignature(expectedSigner, signedDataHash, signature)) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.appendedHash, userOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        if (decodedSig.isPermitTx) {
            decodedSig.token.permit(
                expectedSigner, userOp.sender, decodedSig.amount, deadline, vAdjusted, decodedSig.r, decodedSig.s
            );
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 hash, bytes memory parsedSignature)
        internal
        view
        returns (bool)
    {
        DecodedErc20PermitSig memory decodedSig = abi.decode(parsedSignature, (DecodedErc20PermitSig));

        uint8 vAdjusted = _adjustV(decodedSig.v);
        uint256 deadline = uint256(decodedSig.appendedHash);

        bytes32 structHash = keccak256(
            abi.encode(
                decodedSig.permitTypehash,
                expectedSigner,
                decodedSig.spender,
                decodedSig.amount,
                decodedSig.nonce,
                deadline
            )
        );

        bytes32 signedDataHash = _hashTypedDataV4(structHash, decodedSig.domainSeparator);
        bytes memory signature = abi.encodePacked(decodedSig.r, decodedSig.s, vAdjusted);

        if (!EcdsaLib.isValidSignature(expectedSigner, signedDataHash, signature)) {
            return false;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.appendedHash, hash)) {
            return false;
        }

        return true;
    }

    function _hashTypedDataV4(bytes32 structHash, bytes32 domainSeparator) private pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    function _adjustV(uint256 v) private pure returns (uint8) {
        if (v >= EIP_155_MIN_V_VALUE) {
            return uint8((v - 2 * _extractChainIdFromV(v) - 35) + 27);
        } else if (v <= 1) {
            return uint8(v + 27);
        } else {
            return uint8(v);
        }
    }

    function _extractChainIdFromV(uint256 v) private pure returns (uint256 chainId) {
        chainId = (v - 35) / 2;
    }
}
