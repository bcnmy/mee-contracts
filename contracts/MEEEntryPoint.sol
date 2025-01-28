// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";

/**
 * @title Simple wrapper around EntryPoint
 * @dev Used to ensure only proper Node PMs are used
 */

contract MEEEntryPoint {

    error InvalidPMCodeHash(bytes32 pmCodeHashOnChain);

    IEntryPoint public immutable entryPoint;
    bytes32 public immutable nodePmCodeHash;

    constructor(IEntryPoint _entryPoint, bytes32 _nodePmCodeHash) {
        entryPoint = _entryPoint;
        nodePmCodeHash = _nodePmCodeHash;
    }

    /**
     * @dev Handles userOps. Verifies that the PM code hash is correct.
     *      This verification is crucial to ensure that only proper Node PMs are used.
     *      Malicious NodePM can:
     *      - refund 0 to the userOp.sender
     *      - avoid slashing by returning true (executed) for all userOp hashes
     * @notice This check can be made by the MEE Network in the future. For now, it lives on-chain.
     * @param userOps the userOps to handle
     * @param beneficiary the beneficiary of the userOps
     */
    function handleOps(PackedUserOperation[] calldata userOps, address payable beneficiary) public {
        uint256 opsLen = userOps.length;
        for (uint256 i = 0; i < opsLen; i++) {
            address pm = address(uint160(bytes20(userOps[i].paymasterAndData[0:20])));
            bytes32 pmCodeHash;
            assembly {
                pmCodeHash := extcodehash(pm)
            }
            if (pmCodeHash != nodePmCodeHash) {
                revert InvalidPMCodeHash(pmCodeHash);
            }
        }
        entryPoint.handleOps(userOps, beneficiary);
    }

}
