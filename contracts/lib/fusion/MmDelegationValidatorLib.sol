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
 * @dev This library contains the logic for validating the entries of the superTxn
 * which root hash is signed as a part of the MetaMask Delegation.
 * For more details on the MetaMask Delegation, please refer to the following docs:
 * https://docs.gator.metamask.io/
 *
 * @dev Current implementation expects the delegation to be restricted by the only caveat which is 
 * the `exactExecution` caveat, where `calldata` param has the superTxHash appended to it.
 * See https://docs.gator.metamask.io/how-to/create-delegation/restrict-delegation#exactexecution
 *
 * The flow is like this:
 * - EOA user creates a MM deleGator smart account, or injects it's code to EOA address via ERC-7702
 * - Gator SA issues the delegation to some session address or account, controlled by the MEE Node
 *   Gator owner (EOA) signs the delegation, which hash superTx hash injected
 * - This delegation only allows transferring assets required for the superTxn execution to the 
 *   Nexus orchestrator Smart Account
 * - Delegate redeems the delegation, tokens are sent to the Nexus orchestrator Smart Account
 * - Nexus orchestrator Smart Account executes the superTxn as usual.
 */

struct DecodedMmDelegationSig {
    address delegationManager;
    Delegation delegation;
    bool isRedeemTx;
    bytes32 executionMode;
    bytes executionCalldata;
    uint48 lowerBoundTimestamp;
    uint48 upperBoundTimestamp;
    bytes32[] proof;
}

struct DecodedMmDelegationSigShort {
    address delegationManager;
    Delegation delegation;
    bytes32[] proof;
}

error RedeemDelegationFailed();

library MmDelegationValidatorLib {
    
    /**
     * This function parses the given userOpSignature into a DecodedMmDelegationSig data structure.
     *
     * Once parsed, the function will check for two conditions:
     *      1. is the userOp part of the merkle tree
     *      2. is the recovered message signer equal to the expected signer?
     *
     * NOTES: This function will revert if either of following is met:
     *    1. the userOpSignature couldn't be abi.decoded into a valid DecodedMmDelegationSig struct as defined in this contract
     *    2. userOp is not part of the merkle tree
     *    3. recovered Delegation hash signer wasn't equal to the expected signer
     *
     * @param userOpHash UserOp hash being validated.
     * @param parsedSignature Signature provided as the userOp.signature parameter (minus the prepended tx type byte).
     * @param expectedSigner Signer expected to be recovered when decoding the ERC20OPermit signature.
     */
    function validateUserOp(bytes32 userOpHash, bytes calldata parsedSignature, address expectedSigner)
        internal
        returns (uint256)
    {
        DecodedMmDelegationSig calldata decodedSig = _decodeFullDelegationSig(parsedSignature);

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

        if (decodedSig.isRedeemTx) {
            Delegation[] memory _delegations = new Delegation[](1);
            _delegations[0] = decodedSig.delegation;

            bytes[] memory _permissionContexts = new bytes[](1);
            _permissionContexts[0] = abi.encode(_delegations);

            bytes32[] memory _modes = new bytes32[](1);
            _modes[0] = decodedSig.executionMode;

            bytes[] memory _executionCallDatas = new bytes[](1);
            _executionCallDatas[0] = decodedSig.executionCalldata;
            
            try IDelegationManager(decodedSig.delegationManager).redeemDelegations({
                    _permissionContexts: _permissionContexts, 
                    _modes: _modes, 
                    _executionCallDatas: _executionCallDatas
                }) {
                    // all good
                } catch {
                    revert RedeemDelegationFailed();
                }
        }

        return _packValidationData(false, decodedSig.upperBoundTimestamp, decodedSig.lowerBoundTimestamp);
    }

    /**
     * @dev Performs the full MM DTK Fusion type signature validation
     * It includes checking the Delegation hash was signed by the expected signer
     * and that the given msg hash was included into the superTxn Merkle tree
     * @param expectedSigner The expected signer of the delegation
     * @param dataHash The hash of the data to validate
     * @param parsedSignature The signature to validate
     * @return true if the signature is valid, false otherwise
     */
    function validateSignatureForOwner(address expectedSigner, bytes32 dataHash, bytes calldata parsedSignature)
        internal
        view
        returns (bool)
    {
        
        DecodedMmDelegationSigShort calldata decodedSig = _decodeShortDelegationSig(parsedSignature);

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

    /**
     * @dev Decodes the full data struct out of the MM DTK fusion type signature
     * @param parsedSignature The signature to decode
     * @return decodedSig The decoded signature
     */
    function _decodeFullDelegationSig(bytes calldata parsedSignature)
        private
        pure
        returns (DecodedMmDelegationSig calldata decodedSig)
    {
        assembly {
            decodedSig := add(parsedSignature.offset, 0x20)
        }
    }

    /**
     * @dev Decodes the short data struct out of the MM DTK fusion type signature
     * @param parsedSignature The signature to decode
     * @return decodedSig The decoded signature
     */
    function _decodeShortDelegationSig(bytes calldata parsedSignature)
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

    /**
     * @dev Prepares the Delegation data struct eip-712 hash for the delegation manager
     * @param delegation The delegation to hash
     * @param delegationManager The delegation manager to hash
     * @return The hash of the delegation and the delegation manager's domain separator
     */
    function _getSignedDataHash(Delegation calldata delegation, address delegationManager)
        private
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = IDelegationManager(delegationManager).getDomainHash();
        bytes32 structHash = MMDelegationHelpers._getDelegationHash(delegation);
        return _hashTypedData(structHash, domainSeparator);
    }

    /**
     * @dev Hashes the struct hash and the domain separator
     * @param structHash The struct hash to hash
     * @param domainSeparator The domain separator to hash
     * @return The hash of the struct hash and the domain separator
     */
    function _hashTypedData(bytes32 structHash, bytes32 domainSeparator) private pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }
}
