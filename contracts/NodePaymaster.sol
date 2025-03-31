// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {BaseNodePaymaster} from "./BaseNodePaymaster.sol";
import {EcdsaLib} from "./lib/util/EcdsaLib.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * @dev Allows handleOps calls by any address allowed by owner().
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
contract NodePaymaster is BaseNodePaymaster {

    constructor(
        IEntryPoint _entryPoint,
        address _meeNodeAddress
    ) 
        payable 
        BaseNodePaymaster(_entryPoint, _meeNodeAddress)
    {}

    /**
     * @dev Accepts all userOps
     * Verifies that the handleOps is called by the MEE Node, so it sponsors only for superTxns by owner MEE Node
     * @dev The use of tx.origin makes the NodePaymaster incompatible with the general ERC4337 mempool.
     * This is intentional, and the NodePaymaster is restricted to the MEE node owner anyway.
     * 
     * PaymasterAndData is encoded as follows:
     * 20 bytes: Paymaster address
     * 32 bytes: pm gas values
     * 4 bytes: mode
     * 4 bytes: premium mode
     * 24 bytes: financial data:: impliedCost, premiumPercentage or fixedPremium
     * 20 bytes: refundReceiver (only for DAPP mode)
     * 
     * @param userOp the userOp to validate
     * @param userOpHash the hash of the userOp
     * @param maxCost the max cost of the userOp
     * @return context the context to be used in the postOp
     * @return validationData the validationData to be used in the postOp
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {   
        if( tx.origin == owner() || _checkMeeNodeMasterSig(userOp.signature, userOpHash)) {
            return _validate(userOp, userOpHash, maxCost);
        }
        return ("", 1);
    }

    /// @notice Checks if the hash was signed by the MEE Node (owner())
    function _checkMeeNodeMasterSig(bytes calldata userOpSigData, bytes32 userOpHash) internal view returns (bool) {
        bytes calldata nodeMasterSig;
        assembly {
            nodeMasterSig.offset := sub(add(userOpSigData.offset, userOpSigData.length), 65)
            nodeMasterSig.length := 65
        }
        return EcdsaLib.isValidSignature({
            expectedSigner: owner(),
            hash: keccak256(abi.encodePacked(userOpHash, tx.origin)),
            signature: nodeMasterSig
        });
    }

}