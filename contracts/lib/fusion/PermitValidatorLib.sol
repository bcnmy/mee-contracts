// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {EcdsaLib} from "../util/EcdsaLib.sol";
import {MEEUserOpHashLib} from "../util/MEEUserOpHashLib.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import "account-abstraction/core/Helpers.sol";

import "forge-std/console2.sol";

/**
 * @dev Library to validate the signature for MEE ERC-2612 Permit mode
 *      This is the mode where superTx hash is pasted into deadline field of the ERC-2612 Permit
 *      So the whole permit is signed along with the superTx hash
 *      For more details see Fusion docs: 
 *      - https://ethresear.ch/t/fusion-module-7702-alternative-with-no-protocol-changes/20949    
 *      - https://docs.biconomy.io/explained/eoa#fusion-module
 * 
 *      Important: since ERC20 permit token knows nothing about the MEE, it will treat the superTx hash as a deadline:
 *      -  if (very unlikely) the superTx hash being converted to uint256 is a timestamp in the past, the permit will fail
 *      -  the deadline with most superTx hashes will be very far in the future
 */

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
    uint48 lowerBoundTimestamp;
    uint48 upperBoundTimestamp;
    uint8 v;
    bytes32 r;
    bytes32 s;
    bytes32[] proof;
}

struct DecodedErc20PermitSigShort {
    address spender;
    bytes32 domainSeparator;
    uint256 amount;
    uint256 nonce;
    bytes32 superTxHash;
    uint8 v;
    bytes32 r;
    bytes32 s;
    bytes32[] proof;
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
        DecodedErc20PermitSig memory decodedSig = _decodeFullPermitSig(parsedSignature);

        bytes32 meeUserOpHash =
            MEEUserOpHashLib.getMEEUserOpHash(userOpHash, decodedSig.lowerBoundTimestamp, decodedSig.upperBoundTimestamp);

        if (!EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(expectedSigner, decodedSig),
                abi.encodePacked(decodedSig.r, decodedSig.s, uint8(decodedSig.v))
            )
        ) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.superTxHash, meeUserOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        if (decodedSig.isPermitTx) {
            decodedSig.token.permit(
                expectedSigner, decodedSig.spender, decodedSig.amount, uint256(decodedSig.superTxHash), uint8(decodedSig.v), decodedSig.r, decodedSig.s
            );
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 dataHash, bytes calldata parsedSignature)
        internal
        view
        returns (bool)
    {
        DecodedErc20PermitSigShort calldata decodedSig = _decodeShortPermitSig(parsedSignature);

        if (!EcdsaLib.isValidSignature(
                expectedSigner, 
                _getSignedDataHash(expectedSigner, decodedSig), 
                abi.encodePacked(decodedSig.r, decodedSig.s, uint8(decodedSig.v))
            )
        ) {
            return false;
        }

        if (!MerkleProof.verify(decodedSig.proof, decodedSig.superTxHash, dataHash)) {
            return false;
        }

        return true;
    }

    function _decodeFullPermitSig(bytes calldata parsedSignature) private pure returns (DecodedErc20PermitSig calldata decodedSig) {
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)

            let o := calldataload(parsedSignature.offset) //offset of the struct
            let t := add(parsedSignature.offset, o) // full offset of the struct
            let s := calldataload(add(t, 0x180)) // load the array offset within the struct. 0x180 is fixed because of the struct layout
            let u := mul(calldataload(add(t, s)), 0x20) // load the length of the array
            let l := add(add(add(o, s), u), 0x20)  // full expected length of the struct. 0x20 is to account for the length of the array itself
            if or(
                or(
                    gt(parsedSignature.length, l), 
                    iszero(eq(o, 0x20)) // something is put b/w struct offset and struct
                ),
                iszero(eq(s, 0x1a0)) // something is put b/w array offset and array length
             ) {
                mstore(0x00, 0xba597e7e) // `DecodingError()`.
                revert(0x1c, 0x04)
            }
        }
    }

    function _decodeShortPermitSig(bytes calldata parsedSignature) private pure returns (DecodedErc20PermitSigShort calldata) {
        DecodedErc20PermitSigShort calldata decodedSig;
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
            let u := mul(calldataload(add(parsedSignature.offset, 0x140)), 0x20)
            let l := add(0x160, u) 
            if gt(parsedSignature.length, l) {
                mstore(0x00, 0xba597e7e) // `DecodingError()`.
                revert(0x1c, 0x04)
            }
        }
        return decodedSig;
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
}
