// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { EfficientHashLib } from "solady/utils/EfficientHashLib.sol";

interface IERC5267 {
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}

// keccak256("SuperTx(MeeUserOp[] meeUserOps)");
bytes32 constant SUPER_TX_MEE_USER_OP_ARRAY_TYPEHASH = 0x07bdf0267970db0d5b9acc9d9fa8ef0cbb5b543fb897017542bfb306f5e46ad0;
// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt,uint256[]
// extensions)");
bytes32 constant _DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
uint256 constant STATIC_HEAD_LENGTH = 0x80; // introduced to re-use it in the contracts that use this library

library HashLib {
    using EfficientHashLib for *;

    function parsePackedSigDataHead(bytes calldata packedSignatureData)
        internal
        pure
        returns (bytes32 outerTypeHash, uint256 itemIndex, bytes32[] calldata itemHashes, bytes calldata signature)
    {
        /*
         * packedSignatureData layout :
         * ======== static head part : 0x80 (128) bytes========
         * 32 bytes : outerTypeHash
         * 32 bytes : itemIndex
         * 32 bytes : itemHashes offset
         * 32 bytes : signature offset
         * ======== static tail for fusion modes =====
         * ....
         * ======== dynamic tail  ==========
         * 32 bytes : itemHashes length
         * .....    : itemHashes content
         * 32 bytes : signature length
         * .....    : signature content
         */
        assembly {
            outerTypeHash := calldataload(packedSignatureData.offset)
            itemIndex := calldataload(add(packedSignatureData.offset, 0x20))
            let u := calldataload(add(packedSignatureData.offset, 0x40)) // local offset of the array of hashes
            let s := add(packedSignatureData.offset, u) // global offset of the array of hashes
            itemHashes.offset := add(s, 0x20) // account for 20 bytes length
            itemHashes.length := calldataload(s) // get the length
            u := calldataload(add(packedSignatureData.offset, sub(STATIC_HEAD_LENGTH, 0x20))) // load local offset of the
                // signature
            s := add(packedSignatureData.offset, u) // global offset of the signature
            signature.offset := add(s, 0x20) // account for 20 bytes length
            signature.length := calldataload(s) // get the length
        }
    }

    function compareAndGetFinalHash(
        bytes32 outerTypeHash,
        bytes32 currentItemHash,
        uint256 itemIndex,
        bytes32[] calldata itemHashes
    )
        internal
        view
        returns (bytes32 finalHash)
    {
        // Compare
        if (currentItemHash != itemHashes[itemIndex]) {
            // should be treated as invalid in the caller code
            finalHash = bytes32(0);
        } else {
            // SuperTx is a dynamic struct { EntryType1 entryA, EntryType2 entryB, ... EntryTypeN entryX }
            // It's typehash is provided from the sdk, and the items are considered to be already
            // hashed as properly encoded structs as per eip-712 and provided as bytes32 hashes.
            // hashStruct(s : 𝕊) = keccak256(typeHash ‖ encodeData(s))
            // The encoding of a struct instance is enc(value₁) ‖ enc(value₂) ‖ … ‖ enc(valueₙ)
            // Since all our values are bytes32, we need to just concat all of them
            // There is one case which deserves a dedicated flow in terms of optimizations -
            // it is when all the superTxn entries are MeeUserOps structs. Then it makes sense
            // to treat them as an array of MeeUserOps structs and use the dedicated typehash.
            bytes32 structHash;
            if (outerTypeHash == SUPER_TX_MEE_USER_OP_ARRAY_TYPEHASH) {
                // if SuperTx is an array of MeeUserOps structs, then encoded data is a
                // "keccak256 hash of the concatenated encodeData of their contents" as per eip-712
                uint256 length = itemHashes.length;
                bytes32[] memory a = EfficientHashLib.malloc(length);
                for (uint256 i; i < length; ++i) {
                    a.set(i, itemHashes[i]);
                }
                bytes32 encodedData = a.hash();
                structHash = EfficientHashLib.hash(outerTypeHash, encodedData);
            } else {
                // if SuperTx is a struct, then encoded data is just the concat of all the itemHashes
                /// forge-lint:disable-next-line(asm-keccak256)
                structHash = keccak256(abi.encodePacked(outerTypeHash, itemHashes));
            }
            finalHash = hashTypedDataForAccount(msg.sender, structHash);
        }
    }

    /// @notice Hashes typed data according to eip-712
    ///         Uses account's domain separator
    /// @param account the smart account, who's domain separator will be used
    /// @param structHash the typed data struct hash
    function hashTypedDataForAccount(address account, bytes32 structHash) internal view returns (bytes32 digest) {
        (
            /*bytes1 fields*/
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            /*bytes32 salt*/
            ,
            /*uint256[] memory extensions*/
        ) = IERC5267(account).eip712Domain();

        /// @solidity memory-safe-assembly
        assembly {
            //Rebuild domain separator out of 712 domain
            let m := mload(0x40) // Load the free memory pointer.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), keccak256(add(name, 0x20), mload(name))) // Name hash.
            mstore(add(m, 0x40), keccak256(add(version, 0x20), mload(version))) // Version hash.
            mstore(add(m, 0x60), chainId)
            mstore(add(m, 0x80), verifyingContract)
            digest := keccak256(m, 0xa0) //domain separator

            // Hash typed data
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01".
            mstore(0x1a, digest) // Store the domain separator.
            mstore(0x3a, structHash) // Store the struct hash.
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten.
            mstore(0x3a, 0)
        }
    }
}
