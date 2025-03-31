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

/**
 * @title BaseNode Paymaster
 * @notice Base PM functionality for MEE Node PMs.
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
abstract contract BaseNodePaymaster is BasePaymaster {

    error InvalidNodePMRefundMode(bytes4 mode);
    error InvalidNodePMPremiumMode(bytes4 mode);
    error InvalidContext(uint256 length);

    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes32;

    // 100% with 5 decimals precision
    uint256 private constant PREMIUM_CALCULATION_BASE = 100_00000;

    error EmptyMessageValue();
    error InsufficientBalance();
    error PaymasterVerificationGasLimitTooHigh();
    error Disabled();
    error PostOpGasLimitTooLow();

    constructor(IEntryPoint _entryPoint, address _meeNodeAddress) payable BasePaymaster(_entryPoint) {
        _transferOwnership(_meeNodeAddress);
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
     * param userOpHash the hash of the userOp
     * @param maxCost the max cost of the userOp
     * @return context the context to be used in the postOp
     * @return validationData the validationData to be used in the postOp
     */
    function _validate(PackedUserOperation calldata userOp, bytes32 /*userOpHash*/, uint256 maxCost)
        internal
        virtual
        returns (bytes memory, uint256)
    {   
        // TODO : Optimize it
        bytes4 refundMode = bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+4]);
        bytes4 premiumMode = bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+4:PAYMASTER_DATA_OFFSET+8]);
        address refundReceiver;

        if (refundMode == NODE_PM_MODE_KEEP) { // NO REFUND
            return ("", 0);
        } else {
            if (refundMode == NODE_PM_MODE_USER) {
                refundReceiver = userOp.sender;
            } else if (refundMode == NODE_PM_MODE_DAPP) {
                refundReceiver = address(bytes20(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+32:]));
            } else {
                revert InvalidNodePMRefundMode(refundMode);
            }
        }

        bytes memory context = abi.encodePacked(
            refundReceiver,
            uint192(bytes24(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+8:PAYMASTER_DATA_OFFSET+32])) // financial data : implied cost, or premium percentage or fixed premium  = 24 bytes (uint192)
        );

        if (premiumMode == NODE_PM_PREMIUM_IMPLIED) {
            return (context, 0);
        } else if (premiumMode == NODE_PM_PREMIUM_PERCENT || premiumMode == NODE_PM_PREMIUM_FIXED) {
            // attach gas data to calc refund
            uint256 postOpGasLimit = userOp.unpackPostOpGasLimit();
            context = abi.encodePacked(
                context,
                bytes4(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+4:PAYMASTER_DATA_OFFSET+8]), // premium mode
                maxCost, // maxGasCost
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
     * @dev postOpGasLimit is very important parameter that Node SHOULD use to balance its economic interests
            since penalty is not involved with refunds to sponsor here, 
            postOpGasLimit should account for gas that is spend by AA-EP after benchmarking actualGasSpent
            if it is too low (still enough for _postOp), nodePM will be underpaid
            if it is too high, nodePM will be overcharging the superTxn sponsor as refund is going to be lower
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
     * 32 bytes: maxGasCost
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
        uint256 refund;
        address refundReceiver;

        // Prepare refund info if any
        if (context.length == 0x00) { // 0 bytes => KEEP mode => NO REFUND
            // do nothing
        } else if (context.length == 0x2c) { // 44 bytes => REFUND: Implied cost mode.
            // calc simple refund
            uint192 impliedCost;
            (refundReceiver, impliedCost) = _getRefundReceiverAndFinancialData(context);
            refund = actualGasCost - impliedCost;
        } else if (context.length == 0x70) { // 112 bytes => REFUND: % premium or fixed premium mode.
            // calc refund according to premium mode
            uint192 premiumData;
            (refundReceiver, premiumData) = _getRefundReceiverAndFinancialData(context); 

            bytes4 premiumMode;
            uint256 maxGasCost;
            uint256 postOpGasLimit;

            assembly {
                premiumMode := calldataload(add(context.offset, 0x2c))
                maxGasCost := calldataload(add(context.offset, 0x30))
                postOpGasLimit := calldataload(add(context.offset, 0x50))
            }

            // account for postOpGas
            actualGasCost += postOpGasLimit * actualUserOpFeePerGas;

            // calculate refund based on premium mode
            if (premiumMode == NODE_PM_PREMIUM_PERCENT) {
                refund = _calculateRefundPercentage({
                    actualGasCost: actualGasCost,
                    maxGasCost: maxGasCost,
                    premiumPercentage: uint256(premiumData)
                });
            } else if (premiumMode == NODE_PM_PREMIUM_FIXED) {
                // when premium is fixed, payment by superTxn sponsor is maxGasCost + fixedPremium
                // so we refund just the gas difference, while fixedPremium is going to the MEE Node
                refund = maxGasCost - actualGasCost;
            }
        } else {
            revert InvalidContext(context.length);
        }
        
        // send refund to the superTxn sponsor
        if (refund > 0) {
                entryPoint.withdrawTo(payable(refundReceiver), refund);
        }
    }

    function _getRefundReceiverAndFinancialData(bytes calldata context) internal pure returns (address, uint192) {
        return (address(bytes20(context[:0x14])), uint192(bytes24(context[0x14:0x2c])));
    }

    /**
     * @dev calculate the refund that will be sent to the userOp.sender when premium is %
     * It is required as userOp.sender has paid the maxCostWithPremium, but the actual cost was lower
     * @param actualGasCost the actual gas cost
     * @param maxGasCost the max gas cost
     * @return refund the refund amount
     */
    function _calculateRefundPercentage(
        uint256 actualGasCost,
        uint256 maxGasCost,
        uint256 premiumPercentage
    ) internal pure returns (uint256 refund) {
        // we do not need to account for the penalty here because it goes to the beneficiary
        // which is the MEE Node itself, so we do not have to charge user for the penalty

        // account for MEE Node premium
        uint256 costWithPremium = _applyPercentagePremium(actualGasCost, premiumPercentage);

        // as MEE_NODE charges user with the premium
        uint256 maxCostWithPremium = _applyPercentagePremium(maxGasCost, premiumPercentage);

        // We do not check for the case, when costWithPremium > maxCost
        // maxCost charged by the MEE Node should include the premium
        // if this is done, costWithPremium can never be > maxCost
        if (costWithPremium < maxCostWithPremium) {
            refund = maxCostWithPremium - costWithPremium;
        }
    }

    function _applyPercentagePremium(uint256 amount, uint256 premiumPercentage) internal pure returns (uint256) {
        return amount * (PREMIUM_CALCULATION_BASE + premiumPercentage) / PREMIUM_CALCULATION_BASE;
    }

    receive() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }
}