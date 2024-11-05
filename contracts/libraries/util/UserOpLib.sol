// SPDX-License-Identifier: Unlicense
/*
 * @title UserOp Lib
 *
 * @dev Calculates userOp hash for the new type of transaction - SuperTransaction (as a part of MEE stack)
 */
pragma solidity ^0.8.27;

import "@account-abstraction/interfaces/PackedUserOperation.sol";
import "@account-abstraction/core/UserOperationLib.sol";

library UserOpLib {
    using UserOperationLib for PackedUserOperation;

    /**
     * Calculates userOp hash. Almost works like a regular 4337 userOp hash with few fields added.
     *
     * @param userOp userOp to calculate the hash for
     * @param lowerBoundTimestamp lower bound timestamp set when constructing userOp
     * @param upperBoundTimestamp upper bound timestamp set when constructing userOp
     */
    function getUserOpHash(
        PackedUserOperation calldata userOp,
        uint256 lowerBoundTimestamp,
        uint256 upperBoundTimestamp
    ) internal view returns (bytes32 userOpHash) {
        userOpHash = keccak256(
            bytes.concat(keccak256(abi.encode(userOp.hash(), lowerBoundTimestamp, upperBoundTimestamp, block.chainid)))
        );
    }
}
