// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ECDSA } from "solady/utils/ECDSA.sol";

library EcdsaLib {
    using ECDSA for bytes32;

    /**
     * @dev Solady ECDSA does not revert on incorrect signatures.
     *      Instead, it returns address(0) as the recovered address.
     *      Make sure to never pass address(0) as expectedSigner to this function.
     */
    function isValidSignature(address expectedSigner, bytes32 hash, bytes memory signature) internal view returns (bool) {
        if (hash.tryRecover(signature) == expectedSigner) return true;
        if (hash.toEthSignedMessageHash().tryRecover(signature) == expectedSigner) return true;
        return false;
    }

    /**
     * @dev Returns the keccak256 digest of an EIP-712 typed data (EIP-191 version `0x01`).
     *
     * The digest is calculated from a `domainSeparator` and a `structHash`, by prefixing them with
     * `\x19\x01` and hashing the result. It corresponds to the hash signed by the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`] JSON-RPC method as part of EIP-712.
     *
     * See {ECDSA-recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32 digest) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, hex"1901")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }
}
