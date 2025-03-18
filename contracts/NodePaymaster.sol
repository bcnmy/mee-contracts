// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import "account-abstraction/core/Helpers.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {EcdsaLib} from "contracts/lib/util/EcdsaLib.sol";

import "forge-std/console2.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
contract NodePaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes32;

    // TODO: adjust it 
    // PM.postOp() consumes around 44k. We add a buffer for EP penalty calc
    // and chains with non-standard gas pricing
    uint256 private constant POST_OP_GAS = 49_999;
    mapping(bytes32 => bool) private executedUserOps;

    error EmptyMessageValue();
    error InsufficientBalance();
    error PaymasterVerificationGasLimitTooHigh();
    error Disabled();
    error OnlySponsorOwnStuff();
    error PostOpGasLimitTooLow();

    constructor(IEntryPoint _entryPoint, address _meeNodeAddress) payable BasePaymaster(_entryPoint) {
        _transferOwnership(_meeNodeAddress);
    }

    /**
     * @dev Accepts all userOps
     * Verifies that the handleOps is called by the MEE Node, so it sponsors only for superTxns by owner MEE Node
     * @dev The use of tx.origin makes the NodePaymaster incompatible with the general ERC4337 mempool.
     * This is intentional, and the NodePaymaster is restricted to the MEE node owner anyway.
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
        returns (bytes memory context, uint256 validationData)
    {   
        require(_checkMeeNodeMasterSig(userOp.signature, userOpHash), OnlySponsorOwnStuff()); 

        bytes4 mode = bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+4]);
        uint256 impliedCost = uint256(bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+4:]));        
        
        uint256 postOpGasLimit = userOp.unpackPostOpGasLimit();
        require(postOpGasLimit > POST_OP_GAS, PostOpGasLimitTooLow());
        context = abi.encode(
            mode == NODE_PM_MODE_SPONSORED ? owner() : userOp.sender, 
            userOp.unpackMaxFeePerGas(), 
            userOp.preVerificationGas + userOp.unpackVerificationGasLimit() + userOp.unpackCallGasLimit() + userOp.unpackPaymasterVerificationGasLimit() + postOpGasLimit,
            userOpHash, 
            impliedCost,
            postOpGasLimit
        );
    }

    /**
     * Post-operation handler.
     * Checks mode and refunds the userOp.sender if needed.
     * param PostOpMode enum with the following options: // not used
     *      opSucceeded - user operation succeeded.
     *      opReverted  - user op reverted. still has to pay for gas.
     *      postOpReverted - user op succeeded, but caused postOp (in mode=opSucceeded) to revert.
     *                       Now this is the 2nd call, after user's op was deliberately reverted.
     * @param context - the context value returned by validatePaymasterUserOp
     * @param actualGasCost - actual gas used so far (without this postOp call).
     * @param actualUserOpFeePerGas - actual userOp fee per gas
     */
    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        virtual
        override
    {  
        address refundReceiver;
        uint256 maxFeePerGas;
        uint256 maxGasLimit;
        bytes32 userOpHash;
        uint256 impliedCost;
        uint256 postOpGasLimit;

        assembly {
            refundReceiver := calldataload(context.offset)
            maxFeePerGas := calldataload(add(context.offset, 0x20))
            maxGasLimit := calldataload(add(context.offset, 0x40))
            userOpHash := calldataload(add(context.offset, 0x60))
            impliedCost := calldataload(add(context.offset, 0x80))
            postOpGasLimit := calldataload(add(context.offset, 0xa0))
        }

        executedUserOps[userOpHash] = true;

        uint256 refund = _calculateRefund({
            maxFeePerGas: maxFeePerGas,
            actualGasUsed: actualGasCost / actualUserOpFeePerGas,
            actualUserOpFeePerGas: actualUserOpFeePerGas,
            maxGasLimit: maxGasLimit,
            postOpGasLimit: postOpGasLimit,
            impliedCost: impliedCost
        });
        if (refund > 0) {
            entryPoint.withdrawTo(payable(sender), refund);
        }
    }

    /**
     * @dev calculate the refund that will be sent to the userOp.sender
     * It is required as userOp.sender has paid the maxCostWithPremium, but the actual cost was lower
     * @param maxFeePerGas the max fee per gas
     * @param actualGasUsed the actual gas used
     * @param actualUserOpFeePerGas the actual userOp fee per gas
     * @param maxGasLimit the max gas limit
     * @return refund the refund amount
     */
    function _calculateRefund(
        uint256 maxFeePerGas,
        uint256 actualGasUsed,
        uint256 actualUserOpFeePerGas,
        uint256 maxGasLimit,
        uint256 postOpGasLimit,
        uint256 impliedCost
    ) internal view returns (uint256 refund) {
        //account for postOpGas
        actualGasUsed = actualGasUsed + postOpGasLimit;

        // If there's unused gas, add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge, as verification part of maxGasLimit is > verification part of actualGasUsed, but we are ok with that, at least we do not lose funds.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed)/10;
        
        refund = impliedCost - actualGasUsed * actualUserOpFeePerGas;
    }

    /**
     * @dev check if the userOp was executed
     * @param userOpHash the hash of the userOp
     * @return executed true if the userOp was executed, false otherwise
     */
    function wasUserOpExecuted(bytes32 userOpHash) public view returns (bool) {
        return executedUserOps[userOpHash];
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