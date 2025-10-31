// SPDX-License-Identifier: Unlicense
/*
 * @title MEE UserOp Hash Lib
 *
 * @dev Calculates userOp hash for the new type of transaction - SuperTransaction (as a part of MEE stack)
 */
pragma solidity ^0.8.27;

import { EfficientHashLib } from "solady/utils/EfficientHashLib.sol";

// keccak256("MEEUserOp(bytes32 userOpHash,uint256 lowerBoundTimestamp,uint256 upperBoundTimestamp)");
bytes32 constant MEE_USER_OP_TYPEHASH = 0xa893e832cd40f0161a05fdeee70845d347394fb92e8ffc59e56e6b2d37605454;

library MEEUserOpHashLib {
    /**
     * Calculates blind userOp hash. Almost works like a regular 4337 userOp hash with few fields added.
     *
     * @param userOpHash userOp hash to calculate the hash for
     * @param lowerBoundTimestamp lower bound timestamp set when constructing userOp
     * @param upperBoundTimestamp upper bound timestamp set when constructing userOp
     * Timestamps are used by the MEE node to schedule the execution of the userOps within the superTx
     */
    function getMEEUserOpHash(
        bytes32 userOpHash,
        uint256 lowerBoundTimestamp,
        uint256 upperBoundTimestamp
    )
        internal
        pure
        returns (bytes32 meeUserOpHash)
    {
        // using double hashing to avoid second preimage attack:
        // https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/
        // https://www.npmjs.com/package/@openzeppelin/merkle-tree#fn-1
        meeUserOpHash =
            EfficientHashLib.hash(EfficientHashLib.hash(uint256(userOpHash), lowerBoundTimestamp, upperBoundTimestamp));

        // but since we are moving away from Merkle trees in future commits, we can just hash the userOpHash directly
        // return EfficientHashLib.hash(uint256(userOpHash), lowerBoundTimestamp, upperBoundTimestamp);
    }

    /**
     * @notice Calculates EIP-712 hash of the following data struct:
     * struct MEEUserOp {
     *     bytes32 userOpHash;
     *     uint256 lowerBoundTimestamp;
     *     uint256 upperBoundTimestamp;
     * }
     * Hash as per EIP-712: hashStruct(s : 𝕊) = keccak256(typeHash ‖ encodeData(s))
     * using the efficient hash library for gas optimization
     *
     * @dev Both timestamps here are used bybeing encoded into the validation data in the validateUserOp function.
     * @dev Attention!: If we are to add more fields from the userOp to the struct for better user transparency,
     * we need to make sure they are actually used and not just signed within the MeeUserOp hash.
     * At least they should be compared to the actual userOp fields.
     * Otherwise nothing prevents protocol from showing a user random param values to sign,
     * while in the userOp they are different.
     *
     *
     * @param userOpHash userOp hash to calculate the hash for
     * @param lowerBoundTimestamp lower bound timestamp
     * @param upperBoundTimestamp upper bound timestamp
     * Timestamps are used by the MEE node to schedule the execution of the userOps within the superTx
     *
     * @return meeUserOpEip712Hash the hash of the MEEUserOp struct
     */
    function getMeeUserOpEip712Hash(
        bytes32 userOpHash,
        uint256 lowerBoundTimestamp,
        uint256 upperBoundTimestamp
    )
        internal
        pure
        returns (bytes32 meeUserOpEip712Hash)
    {
        meeUserOpEip712Hash = EfficientHashLib.hash(
            MEE_USER_OP_TYPEHASH, userOpHash, bytes32(lowerBoundTimestamp), bytes32(upperBoundTimestamp)
        );
    }
}
