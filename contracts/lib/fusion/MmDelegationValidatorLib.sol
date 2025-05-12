// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {EcdsaLib} from "../util/EcdsaLib.sol";
import {MEEUserOpHashLib} from "../util/MEEUserOpHashLib.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import "account-abstraction/core/Helpers.sol";
import {Delegation, Caveat, MMDelegationHelpers, IDelegationManager} from "../util/MMDelegationHelpers.sol";

/**
 * @dev ...// TODO: add docs
 */

struct DecodedMmDelegationSig {
    address delegationManager;
    Delegation delegation;
    uint48 lowerBoundTimestamp;
    uint48 upperBoundTimestamp;
    bytes32[] proof;
}

struct DecodedMmDelegationSigShort {
    address delegationManager;
    Delegation delegation;
    bytes32[] proof;
}

library MmDelegationValidatorLib {
    
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
        DecodedMmDelegationSig calldata decodedSig = _decodeFullPermitSig(parsedSignature);

        // check that the owner has signed the delegation that includes the injected superTxnHash 
        if (
            !EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(decodedSig.delegation, decodedSig.delegationManager),
                decodedSig.delegation.signature)
        ) {
            return SIG_VALIDATION_FAILED;
        }
        
        // extract the superTxHash from the delegation
        // make the meeUserOpHash
        // verify the meeUserOpHash against the proof
        bytes32 superTxHash = _getSuperTxHashFromDelegation(decodedSig.delegation);

        bytes32 meeUserOpHash = MEEUserOpHashLib.getMEEUserOpHash(
            userOpHash, decodedSig.lowerBoundTimestamp, decodedSig.upperBoundTimestamp
        );

        if (!MerkleProof.verify(decodedSig.proof, superTxHash, meeUserOpHash)) {
            return SIG_VALIDATION_FAILED;
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 dataHash, bytes calldata parsedSignature)
        internal
        view
        returns (bool)
    {
        
        DecodedMmDelegationSigShort calldata decodedSig = _decodeShortPermitSig(parsedSignature);

        if (
            !EcdsaLib.isValidSignature(
                expectedSigner,
                _getSignedDataHash(decodedSig.delegation, decodedSig.delegationManager),
                decodedSig.delegation.signature
            )
        ) {
            return false;
        }

        bytes32 superTxHash = _getSuperTxHashFromDelegation(decodedSig.delegation);
        
        if (!MerkleProof.verify(decodedSig.proof, superTxHash, dataHash)) {
            return false;
        }

        return true;
    }

    function _decodeFullPermitSig(bytes calldata parsedSignature)
        private
        pure
        returns (DecodedMmDelegationSig calldata decodedSig)
    {
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
        }
    }

    function _decodeShortPermitSig(bytes calldata parsedSignature)
        private
        pure
        returns (DecodedMmDelegationSigShort calldata decodedSig)
    {
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
        }
    }

    /**
     * @dev Extracts the superTxHash from the first caveat of the delegation
     * It expects the delegation to be restricted by the only caveat which is 
     * the `exactExecution` caveat, where `calldata` param has the superTxHash appended to it.
     * See https://docs.gator.metamask.io/how-to/create-delegation/restrict-delegation#exactexecution
     * @param delegation The delegation to extract the superTxHash from
     * @return The superTxHash
     */
    function _getSuperTxHashFromDelegation(Delegation calldata delegation)
        private
        pure
        returns (bytes32)
    {
        bytes calldata terms = delegation.caveats[0].terms;
        bytes32 superTxHash;
        superTxHash = bytes32(terms[terms.length - 0x20 :]);
        return superTxHash;
    }
        
    function _getSignedDataHash(Delegation calldata delegation, address delegationManager)
        private
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = IDelegationManager(delegationManager).getDomainHash();
        bytes32 structHash = MMDelegationHelpers._getDelegationHash(delegation);
        return _hashTypedData(structHash, domainSeparator);
    }

    function _hashTypedData(bytes32 structHash, bytes32 domainSeparator) private pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }
}
