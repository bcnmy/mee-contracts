// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {EcdsaLib} from "../util/EcdsaLib.sol";
import {MEEUserOpHashLib} from "../util/MEEUserOpHashLib.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import "account-abstraction/core/Helpers.sol";

bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

struct DecodedErc20PermitSig {
    IERC20Permit token;
    address spender;
    bytes32 domainSeparator;
    uint256 amount;
    uint256 nonce;
    bool isPermitTx;
    bytes32 superTxHash;
    bytes32[] proof;
    uint48 lowerBoundTimestamp;
    uint48 upperBoundTimestamp;
    uint256 v;
    bytes32 r;
    bytes32 s;
}

struct DecodedErc20PermitSigShort {
    address spender;
    bytes32 domainSeparator;
    uint256 amount;
    uint256 nonce;
    bytes32 superTxHash;
    bytes32[] proof;
    uint256 v;
    bytes32 r;
    bytes32 s;
}

library PermitValidatorLib {
    uint8 constant EIP_155_MIN_V_VALUE = 37;

    using MessageHashUtils for bytes32;

    /**
     * This function parses the given userOpSignature into a DecodedErc20PermitSig data structure.
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the userOp part of the merkle tree
     *      2. is the recovered message signer equal to the expected signer?
     *
     * NOTES: This function will revert if either of following is met:
     *    1. the userOpSignature couldn't be abi.decoded into a valid DecodedErc20PermitSig struct as defined in this contract
     *    2. userOp is not part of the merkle tree
     *    3. recovered Permit message signer wasn't equal to the expected signer
     *
     * The function will also perform the Permit approval on the given token in case the
     * isPermitTx flag was set to true in the decoded signature struct.
     *
     * @param userOpHash UserOp hash being validated.
     * @param parsedSignature Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    function validateUserOp(bytes32 userOpHash, bytes calldata parsedSignature, address expectedSigner)
        internal
        returns (uint256)
    {   
        //TODO: try to squeeze some gas from both structs with calldata parsing if have time
        DecodedErc20PermitSig memory decodedSig = abi.decode(parsedSignature, (DecodedErc20PermitSig));

        bytes32 meeUserOpHash =
            MEEUserOpHashLib.getMEEUserOpHash(userOpHash, decodedSig.lowerBoundTimestamp, decodedSig.upperBoundTimestamp);

        uint8 vAdjusted = _adjustV(decodedSig.v);

        if (!EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(expectedSigner, decodedSig),
                abi.encodePacked(decodedSig.r, decodedSig.s, vAdjusted)
            )
        ) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.superTxHash, meeUserOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        if (decodedSig.isPermitTx) {
            decodedSig.token.permit(
                expectedSigner, decodedSig.spender, decodedSig.amount, uint256(decodedSig.superTxHash), vAdjusted, decodedSig.r, decodedSig.s
            );
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 dataHash, bytes memory parsedSignature)
        internal
        view
        returns (bool)
    {
        DecodedErc20PermitSigShort memory decodedSig = abi.decode(parsedSignature, (DecodedErc20PermitSigShort));
        uint8 vAdjusted = _adjustV(decodedSig.v);

        if (!EcdsaLib.isValidSignature(
                expectedSigner, 
                _getSignedDataHash(expectedSigner, decodedSig), 
                abi.encodePacked(decodedSig.r, decodedSig.s, vAdjusted)
            )
        ) {
            return false;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.superTxHash, dataHash)) {
            return false;
        }

        return true;
    }

    function _getSignedDataHash(address expectedSigner, DecodedErc20PermitSig memory decodedSig) private pure returns (bytes32) {
        uint256 deadline = uint256(decodedSig.superTxHash);

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, 
                expectedSigner,
                decodedSig.spender,
                decodedSig.amount,
                decodedSig.nonce,
                deadline
            )
        );
        return _hashTypedData(structHash, decodedSig.domainSeparator);
    }

    function _getSignedDataHash(address expectedSigner, DecodedErc20PermitSigShort memory decodedSig) private pure returns (bytes32) {
        uint256 deadline = uint256(decodedSig.superTxHash);

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, 
                expectedSigner,
                decodedSig.spender,
                decodedSig.amount,
                decodedSig.nonce,
                deadline
            )
        );
        return _hashTypedData(structHash, decodedSig.domainSeparator);
    }

    function _hashTypedData(bytes32 structHash, bytes32 domainSeparator) private pure returns (bytes32) {
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
