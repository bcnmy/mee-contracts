// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "solady/utils/ECDSA.sol";

library EcdsaLib {
    using ECDSA for bytes32;

    function isValidSignature(address expectedSigner, bytes32 hash, bytes memory signature)
        internal
        view
        returns (bool)
    {
        if (hash.tryRecover(signature) == expectedSigner) return true;
        if (hash.toEthSignedMessageHash().tryRecover(signature) == expectedSigner) return true;
        return false;
    }
}
