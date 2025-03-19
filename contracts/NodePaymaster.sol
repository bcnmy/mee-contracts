// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import "account-abstraction/core/Helpers.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {EcdsaLib} from "./lib/util/EcdsaLib.sol";
import {NODE_PM_MODE_USER, NODE_PM_MODE_DAPP, NODE_PM_MODE_KEEP, NODE_PM_PREMIUM_IMPLIED, NODE_PM_PREMIUM_PERCENT, NODE_PM_PREMIUM_FIXED} from "./types/Constants.sol";

import "forge-std/console2.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
contract NodePaymaster is BasePaymaster {

    error InvalidNodePMRefundMode(bytes4 mode);
    error InvalidNodePMPremiumMode(bytes4 mode);
    error InvalidContext(uint256 length);

    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes32;

    // TODO: adjust it 
    // PM.postOp() consumes around 44k. We add a buffer for EP penalty calc
    // and chains with non-standard gas pricing
    uint256 private constant POST_OP_GAS = 49_999;
    
    // 100% with 5 decimals precision
    uint256 private constant PREMIUM_CALCULATION_BASE = 100_00000;
    
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
     * @dev check if the userOp was executed
     * @param userOpHash the hash of the userOp
     * @return executed true if the userOp was executed, false otherwise
     */
    function wasUserOpExecuted(bytes32 userOpHash) public view returns (bool) {
        return executedUserOps[userOpHash];
    }

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
        require(_checkMeeNodeMasterSig(userOp.signature, userOpHash), OnlySponsorOwnStuff()); 

        // TODO : Optimize it

        bytes4 refundMode = bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+4]);
        bytes4 premiumMode = bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+4:PAYMASTER_DATA_OFFSET+8]);
        address refundReceiver;

        bytes memory context = abi.encodePacked(userOpHash);

        if (refundMode == NODE_PM_MODE_KEEP) { // NO REFUND
            return (context, 0);
        } else {
            if (refundMode == NODE_PM_MODE_USER) {
                refundReceiver = userOp.sender;
            } else if (refundMode == NODE_PM_MODE_DAPP) {
                refundReceiver = address(bytes20(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+32:]));
            } else {
                revert InvalidNodePMRefundMode(refundMode);
            }
        }

        context = abi.encodePacked(
            context,
            refundReceiver,
            uint192(bytes24(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+8:PAYMASTER_DATA_OFFSET+32])) // financial data : implied cost, or premium percentage or fixed premium  = 24 bytes (uint192)
        );

        if (premiumMode == NODE_PM_PREMIUM_IMPLIED) {
            return (context, 0);
        } else if (premiumMode == NODE_PM_PREMIUM_PERCENT || premiumMode == NODE_PM_PREMIUM_FIXED) {
            // attach gas data to calc refund
            uint256 postOpGasLimit = userOp.unpackPostOpGasLimit();
            require(postOpGasLimit > POST_OP_GAS, PostOpGasLimitTooLow());
            context = abi.encodePacked(
                context,
                bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+4:PAYMASTER_DATA_OFFSET+8]), // premium mode
                userOp.unpackMaxFeePerGas(), // maxFeePerGas
                userOp.preVerificationGas + userOp.unpackVerificationGasLimit() + userOp.unpackCallGasLimit() + userOp.unpackPaymasterVerificationGasLimit() + postOpGasLimit, // maxGasLimit
                postOpGasLimit // postOpGasLimit
            );
        } else {
            revert InvalidNodePMPremiumMode(premiumMode);
        }
        return (context, 0);
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
     * context is encoded as follows:
     * 32 bytes: userOpHash 
     * total(32 bytes)
     * ==== if there is refund add ===
     * 20 bytes: refundReceiver
     * 24 bytes: financial data:: impliedCost, or premiumPercentage or fixedPremium 
     * total(76 bytes)
     * ==== if % or fixed premium mode add ===
     * 4 bytes: premium mode
     * 32 bytes: maxFeePerGas
     * 32 bytes: maxGasLimit
     * 32 bytes: postOpGasLimit 
     * total(176 bytes)
     * @param actualGasCost - actual gas used so far (without this postOp call).
     * @param actualUserOpFeePerGas - actual userOp fee per gas
     */
    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        virtual
        override
    {  
        bytes32 userOpHash;
        assembly {
            userOpHash := calldataload(context.offset)
        }
        executedUserOps[userOpHash] = true;
        // that's it for the keep mode
        
        uint256 refund;
        address refundReceiver;

        // One of the refund scenarios
        if (context.length == 0x4c) { // 76 bytes => Implied cost mode.
            // calc simple refund
            uint192 impliedCost;
            (refundReceiver, impliedCost) = _getRefundReceiverAndFinancialData(context);
            refund = actualGasCost - impliedCost;
        } else if (context.length == 0xb0) { // 176 bytes => % premium or fixed premium mode.
            uint192 premiumData;
            (refundReceiver, premiumData) = _getRefundReceiverAndFinancialData(context); 


            //console2.log("premiumData", premiumData);
            //console2.log("refundReceiver", refundReceiver);

            bytes4 premiumMode;
            uint256 maxFeePerGas;
            uint256 maxGasLimit;
            uint256 postOpGasLimit;

            assembly {
                premiumMode := calldataload(add(context.offset, 0x4c))
                maxFeePerGas := calldataload(add(context.offset, 0x50))
                maxGasLimit := calldataload(add(context.offset, 0x70))
                postOpGasLimit := calldataload(add(context.offset, 0x90))
            }

            //console2.logBytes4(premiumMode);
            //console2.log(maxFeePerGas);
            //console2.log(maxGasLimit);
            //console2.log(postOpGasLimit);

            refund = _calculateRefund({
                maxFeePerGas: maxFeePerGas,
                actualGasUsed: actualGasCost / actualUserOpFeePerGas,
                actualUserOpFeePerGas: actualUserOpFeePerGas,
                maxGasLimit: maxGasLimit,
                postOpGasLimit: postOpGasLimit,
                premiumData: uint256(premiumData)
            });
        } else {
            revert InvalidContext(context.length);
        }

        if (refund > 0) {
                entryPoint.withdrawTo(payable(refundReceiver), refund);
        }
    }

    function _getRefundReceiverAndFinancialData(bytes calldata context) internal view returns (address, uint192) {
        return (address(bytes20(context[0x20:0x34])), uint192(bytes24(context[0x34:0x4c])));
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
        uint256 premiumData
    ) internal view returns (uint256 refund) {
        //account for postOpGas
        actualGasUsed = actualGasUsed + postOpGasLimit;

        // If there's unused gas, add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge, as verification part of maxGasLimit is > verification part of actualGasUsed, but we are ok with that, at least we do not lose funds.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed) / 10;

        uint256 premiumPercentage = premiumData;

        // account for MEE Node premium
        uint256 costWithPremium = (
            actualGasUsed * actualUserOpFeePerGas * (PREMIUM_CALCULATION_BASE + premiumPercentage)
        ) / PREMIUM_CALCULATION_BASE;

        // as MEE_NODE charges user with the premium
        uint256 maxCostWithPremium =
            maxGasLimit * maxFeePerGas * (PREMIUM_CALCULATION_BASE + premiumPercentage) / PREMIUM_CALCULATION_BASE;

        // We do not check for the case, when costWithPremium > maxCost
        // maxCost charged by the MEE Node should include the premium
        // if this is done, costWithPremium can never be > maxCost
        if (costWithPremium < maxCostWithPremium) {
            refund = maxCostWithPremium - costWithPremium;
        }
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