// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { EcdsaLib } from "../util/EcdsaLib.sol";
import { MEEUserOpHashLib } from "../util/MEEUserOpHashLib.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { EfficientHashLib } from "solady/utils/EfficientHashLib.sol";
import { SIG_VALIDATION_FAILED, _packValidationData } from "account-abstraction/core/Helpers.sol";

/**
 * @dev Library to validate the signature for MEE ERC-2612 Permit mode
 *      This is the mode where superTx hash is pasted into deadline field of the ERC-2612 Permit
 *      So the whole permit is signed along with the superTx hash
 *      For more details see Fusion docs:
 *      - https://ethresear.ch/t/fusion-module-7702-alternative-with-no-protocol-changes/20949
 *      - https://docs.biconomy.io/explained/eoa#fusion-module
 *
 *      @dev Important: since ERC20 permit token knows nothing about the MEE, it will treat the superTx hash as a deadline:
 *      -  if (very unlikely) the superTx hash being converted to uint256 is a timestamp in the past, the permit will fail
 *      -  the deadline with most superTx hashes will be very far in the future
 *
 *      @dev Since at this point bytes32 superTx hash is a blind hash, users and wallets should pay attention if
 *           the permit2 deadline field does not make sense as the timestamp. In this case, it can be a sign of a
 *           phishing attempt (injecting super txn hash as the deadline) and the user should not sign the permit.
 *           This is going to be mitigated in the future by making superTx hash a EIP-712 hash.
 */

//keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
bytes32 constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

struct DecodedErc20PermitSig {
    ERC20 token;
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
    error PermitFailed();

    uint8 internal constant EIP_155_MIN_V_VALUE = 37;

    using EcdsaLib for bytes32;

    /**
     * This function parses the given userOpSignature into a DecodedErc20PermitSig data structure.
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the userOp part of the merkle tree
     *      2. is the recovered message signer equal to the expected signer?
     *
     * NOTES: This function will revert if either of following is met:
     *    1. the userOpSignature couldn't be abi.decoded into a valid DecodedErc20PermitSig struct as defined in this
     * contract
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
    function validateUserOp(
        bytes32 userOpHash,
        bytes calldata parsedSignature,
        address expectedSigner
    )
        internal
        returns (uint256)
    {
        DecodedErc20PermitSig memory decodedSig = _decodeFullPermitSig(parsedSignature);

        bytes32 meeUserOpHash =
            MEEUserOpHashLib.getMEEUserOpHash(userOpHash, decodedSig.lowerBoundTimestamp, decodedSig.upperBoundTimestamp);

        if (
            !EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(expectedSigner, decodedSig),
                abi.encodePacked(decodedSig.r, decodedSig.s, uint8(decodedSig.v))
            )
        ) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProofLib.verify(decodedSig.proof, decodedSig.superTxHash, meeUserOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        if (decodedSig.isPermitTx) {
            try decodedSig.token.permit(
                expectedSigner,
                decodedSig.spender,
                decodedSig.amount,
                uint256(decodedSig.superTxHash),
                uint8(decodedSig.v),
                decodedSig.r,
                decodedSig.s
            ) {
                // all good
            } catch {
                // check if by some reason this permit was already successfully used (and not spent yet)
                if (ERC20(address(decodedSig.token)).allowance(expectedSigner, decodedSig.spender) < decodedSig.amount) {
                    // if the above expectationis not true, revert
                    revert PermitFailed();
                }
            }
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(
        address expectedSigner,
        bytes32 dataHash,
        bytes calldata parsedSignature
    )
        internal
        view
        returns (bool)
    {
        DecodedErc20PermitSigShort calldata decodedSig = _decodeShortPermitSig(parsedSignature);

        if (
            !EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(expectedSigner, decodedSig),
                abi.encodePacked(decodedSig.r, decodedSig.s, uint8(decodedSig.v))
            )
        ) {
            return false;
        }

        if (!MerkleProofLib.verify(decodedSig.proof, decodedSig.superTxHash, dataHash)) {
            return false;
        }

        return true;
    }

    function _decodeFullPermitSig(bytes calldata parsedSignature)
        private
        pure
        returns (DecodedErc20PermitSig calldata decodedSig)
    {
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
        }
    }

    function _decodeShortPermitSig(bytes calldata parsedSignature)
        private
        pure
        returns (DecodedErc20PermitSigShort calldata)
    {
        DecodedErc20PermitSigShort calldata decodedSig;
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
        }
        return decodedSig;
    }

    function _getSignedDataHash(
        address expectedSigner,
        DecodedErc20PermitSig memory decodedSig
    )
        private
        pure
        returns (bytes32)
    {
        return _hashTypedData(
            _hashPermitDataStruct(
                expectedSigner, decodedSig.spender, decodedSig.amount, decodedSig.nonce, decodedSig.superTxHash
            ),
            decodedSig.domainSeparator
        );
    }

    function _getSignedDataHash(
        address expectedSigner,
        DecodedErc20PermitSigShort memory decodedSig
    )
        private
        pure
        returns (bytes32)
    {
        return _hashTypedData(
            _hashPermitDataStruct(
                expectedSigner, decodedSig.spender, decodedSig.amount, decodedSig.nonce, decodedSig.superTxHash
            ),
            decodedSig.domainSeparator
        );
    }

    function _hashPermitDataStruct(
        address expectedSigner,
        address spender,
        uint256 amount,
        uint256 nonce,
        bytes32 superTxHash
    )
        private
        pure
        returns (bytes32)
    {
        return EfficientHashLib.hash(
            uint256(PERMIT_TYPEHASH),
            uint256(uint160(expectedSigner)),
            uint256(uint160(spender)),
            amount,
            nonce,
            uint256(superTxHash)
        );
    }

    function _hashTypedData(bytes32 structHash, bytes32 domainSeparator) private pure returns (bytes32) {
        return EcdsaLib.toTypedDataHash(domainSeparator, structHash);
    }
}
