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
    bytes32[] proof;
    uint48 lowerBoundTimestamp;
    uint48 upperBoundTimestamp;
    uint8 v;
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
    uint8 v;
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

        console2.logBytes(parsedSignature);

        /*

        0x
        0000000000000000000000000000000000000000000000000000000000000020 // struct offset
        000000000000000000000000a0cb889707d426a7a386870a03bc70d1b0697598 // erc20 permit token
        000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb1 // spender
        89848d8aec21b6fe4e1bd063781397bf555ab8f53c286b1e5358436281b1ec86 // domain separator
        0000000000000000000000000000000000000000000000007ce66c50e2840000 // value
        0000000000000000000000000000000000000000000000000000000000000000 // nonce
        0000000000000000000000000000000000000000000000000000000000000000 // is permit tx
        a458e2fb01140fe4a64294565036824bae8205bd363c1b83bf5f0e0a5b03734b // deadline / superTx hash
        00000000000000000000000000000000000000000000000000000000000001a0 // proof offset
        0000000000000000000000000000000000000000000000000000000000000001 // lower bound timestamp
        00000000000000000000000000000000000000000000000000000000000003e9 // upper bound timestamp
        000000000000000000000000000000000000000000000000000000000000001c // signature offset
        e1a812730bab84581947ad426486bcc5637b8ea8dd50862dee9dd0b8665d1f0a
        160fb0000c24d7c820ab28f83c32c11977bb7a3ed61c4cde9c0825be9420e472
        0000000000000000000000000000000000000000000000000000000000000004
        601163fb105e5fe9a76c7484ada9e984db32f423f306e7d1ec272d0895300190
        86388f3adbb81b84158d93964b47acce2ab3b78be636da35ee5084cfd81ed953
        da05c3ede43f7912e161ef9bdad56a506f79f69224982e4591ca685bf802778d
        eeef48e397cf771fd02e56efcc87c6ffef88d3fe21c0b416ac140598d68bef1c

        */

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

    function validateSignatureForOwner(address expectedSigner, bytes32 dataHash, bytes memory parsedSignature)
        internal
        view
        returns (bool)
    {
        DecodedErc20PermitSigShort memory decodedSig = abi.decode(parsedSignature, (DecodedErc20PermitSigShort));

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
