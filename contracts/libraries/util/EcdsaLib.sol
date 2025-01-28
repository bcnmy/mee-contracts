// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

library EcdsaLib {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    // TODO: change OZ to solady

    function isValidSignature(address expectedSigner, bytes32 hash, bytes memory signature)
        internal
        pure
        returns (bool)
    {
        if (_recoverSigner(hash, signature) == expectedSigner) return true;
        if (_recoverSigner(hash.toEthSignedMessageHash(), signature) == expectedSigner) return true;
        return false;
    }

    function _recoverSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address owner,,) = hash.tryRecover(signature);
        return owner;
    }
}
