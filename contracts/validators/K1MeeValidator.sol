// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {IValidator, MODULE_TYPE_VALIDATOR} from "erc7579/interfaces/IERC7579Module.sol";
import {ISessionValidator} from "contracts/interfaces/ISessionValidator.sol";
import {EnumerableSet} from "EnumerableSet4337/EnumerableSet4337.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_TYPE_SIMPLE, SIG_TYPE_ON_CHAIN, SIG_TYPE_ERC20_PERMIT, EIP1271_SUCCESS, EIP1271_FAILED} from "contracts/types/Constants.sol";
// Fusion libraries - validate userOp using on-chain tx or off-chain permit
import {PermitValidatorLib} from "contracts/lib/fusion/PermitValidatorLib.sol";
import {TxValidatorLib} from "contracts/lib/fusion/TxValidatorLib.sol";
import {SimpleValidatorLib} from "contracts/lib/fusion/SimpleValidatorLib.sol";
import {NoMeeFlowLib} from "contracts/lib/fusion/NoMeeFlowLib.sol";

import "forge-std/console2.sol";

contract K1MeeValidator is IValidator, ISessionValidator {
    // using SignatureCheckerLib for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mapping of smart account addresses to their respective owner addresses
    mapping(address => address) public smartAccountOwners;

    EnumerableSet.AddressSet private _safeSenders;

    /// @notice Error to indicate that no owner was provided during installation
    error NoOwnerProvided();

    /// @notice Error to indicate that the new owner cannot be the zero address
    error ZeroAddressNotAllowed();

    /// @notice Error to indicate the module is already initialized
    error ModuleAlreadyInitialized();

    /// @notice Error to indicate that the new owner cannot be a contract address
    error NewOwnerIsContract();

    /// @notice Error to indicate that the owner cannot be the zero address
    error OwnerCannotBeZeroAddress();

    /// @notice Error to indicate that the data length is invalid
    error InvalidDataLength();

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     *
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        require(data.length != 0, NoOwnerProvided());
        require(!_isInitialized(msg.sender), ModuleAlreadyInitialized());
        address newOwner = address(bytes20(data[:20]));
        require(newOwner != address(0), OwnerCannotBeZeroAddress());
        require(!_isContract(newOwner), NewOwnerIsContract());
        smartAccountOwners[msg.sender] = newOwner;
    }

    /**
     * De-initialize the module with the given data
     */
    function onUninstall(bytes calldata) external override {
        delete smartAccountOwners[msg.sender];
        _safeSenders.removeAll(msg.sender);
    }

    /// @notice Transfers ownership of the validator to a new owner
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external {
        require(newOwner != address(0), ZeroAddressNotAllowed());
        require(!_isContract(newOwner), NewOwnerIsContract());
        smartAccountOwners[msg.sender] = newOwner;
    }

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     *
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) external view returns (bool) {
        return _isInitialized(smartAccount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Validates PackedUserOperation
     *
     * @param userOp UserOperation to be validated
     * @param userOpHash Hash of the UserOperation to be validated
     *
     * @return uint256 the result of the signature validation, which can be:
     *  - 0 if the signature is valid
     *  - 1 if the signature is invalid
     *  - <20-byte> aggregatorOrSigFail, <6-byte> validUntil and <6-byte> validAfter (see ERC-4337
     * for more details)
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        override
        returns (uint256)
    {   
        bytes4 sigType = bytes4(userOp.signature[0:4]);
        address owner = smartAccountOwners[userOp.sender];

        if (sigType == SIG_TYPE_SIMPLE) {
            return SimpleValidatorLib.validateUserOp(userOpHash, userOp.signature[4:], owner);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateUserOp(userOpHash, userOp.signature[4:], owner);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateUserOp(userOpHash, userOp.signature[4:], owner);
        } else {
            // fallback flow => non MEE flow => no prefix
            return NoMeeFlowLib.validateUserOp(userOpHash, userOp.signature, owner);
        }
    }

    /**
     * Validates an ERC-1271 signature
     *
     * param sender The sender of the ERC-1271 call to the account
     * @param hash The hash of the message
     * @param signature The signature of the message
     *
     * @return sigValidationResult the result of the signature validation, which can be:
     *  - EIP1271_SUCCESS if the signature is valid
     *  - EIP1271_FAILED if the signature is invalid
     */
    function isValidSignatureWithSender(address, bytes32 hash, bytes calldata signature)
        external
        view
        virtual
        override
        returns (bytes4 sigValidationResult)
    {   
        // Then send the signature over hash itself to _erc1271IsValidSignatureWithSender 
        return _validateSignatureForOwner(
            smartAccountOwners[msg.sender], 
            hash,
            _erc1271UnwrapSignature(signature)
        ) ? EIP1271_SUCCESS : EIP1271_FAILED;
    }

    /// @notice ISessionValidator interface for smart session
    /// @param hash The hash of the data to validate
    /// @param sig The signature data
    /// @param data The data to validate against (owner address in this case)
    function validateSignatureWithData(bytes32 hash, bytes calldata sig, bytes calldata data)
        external
        view
        returns (bool validSig)
    {
        require(data.length >= 20, InvalidDataLength());
        return _validateSignatureForOwner(address(bytes20(data[:20])), hash, sig);
    }

    /**
     * Get the owner of the smart account
     * @param smartAccount The address of the smart account
     * @return The owner of the smart account
     */
    function getOwner(address smartAccount) external view returns (address) {
        return smartAccountOwners[smartAccount];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the name of the module
    /// @return The name of the module
    function name() external pure returns (string memory) {
        return "K1MeeValidator";
    }

    /// @notice Returns the version of the module
    /// @return The version of the module
    function version() external pure returns (string memory) {
        return "1.0.1";
    }

    /// @notice Checks if the module is of the specified type
    /// @param typeId The type ID to check
    /// @return True if the module is of the specified type, false otherwise
    function isModuleType(uint256 typeId) external pure returns (bool) {
        return typeId == MODULE_TYPE_VALIDATOR;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Internal method that does the job of validating the signature via ECDSA (secp256k1)
    /// @param owner The address of the owner
    /// @param hash The hash of the data to validate
    /// @param signature The signature data
    function _validateSignatureForOwner(address owner, bytes32 hash, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes4 sigType = bytes4(signature[0:4]);

        if (sigType == SIG_TYPE_SIMPLE) {
            return SimpleValidatorLib.validateSignatureForOwner(owner, hash, signature[4:]);
        } else if (sigType == SIG_TYPE_ON_CHAIN) {
            return TxValidatorLib.validateSignatureForOwner(owner, hash, signature[4:]);
        } else if (sigType == SIG_TYPE_ERC20_PERMIT) {
            return PermitValidatorLib.validateSignatureForOwner(owner, hash, signature[4:]);
        } else {
            // fallback flow => non MEE flow => no prefix
            return NoMeeFlowLib.validateSignatureForOwner(owner, hash, signature);
        } 
    }


    /// @notice Checks if the smart account is initialized with an owner
    /// @param smartAccount The address of the smart account
    /// @return True if the smart account has an owner, false otherwise
    function _isInitialized(address smartAccount) private view returns (bool) {
        return smartAccountOwners[smartAccount] != address(0);
    }

    /// @notice Checks if the address is a contract
    /// @param account The address to check
    /// @return True if the address is a contract, false otherwise
    function _isContract(address account) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /// @dev Unwraps and returns the signature.
    function _erc1271UnwrapSignature(bytes calldata signature)
        internal
        view
        virtual
        returns (bytes calldata result)
    {
        result = signature;
        /// @solidity memory-safe-assembly
        assembly {
            // Unwraps the ERC6492 wrapper if it exists.
            // See: https://eips.ethereum.org/EIPS/eip-6492
            if eq(
                calldataload(add(result.offset, sub(result.length, 0x20))),
                mul(0x6492, div(not(shr(address(), address())), 0xffff)) // `0x6492...6492`.
            ) {
                let o := add(result.offset, calldataload(add(result.offset, 0x40)))
                result.length := calldataload(o)
                result.offset := add(o, 0x20)
            }
        }
    }
}
