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
     * === PM_DATA_START ===
     * 4 bytes: mode
     * 4 bytes: premium mode
     * 24 bytes: financial data:: impliedCost or premiumPercentage (only for according premium modes)
     * 20 bytes: refundReceiver (only for DAPP refund mode)
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
        bytes4 refundMode;
        bytes4 premiumMode;
        bytes calldata pmAndData = userOp.paymasterAndData;
        assembly {
            // 0x34 = 52 => PAYMASTER_DATA_OFFSET
            refundMode := calldataload(add(pmAndData.offset, 0x34))
        }
        
        address refundReceiver;
        // Handle refund mode
        if (refundMode == NODE_PM_MODE_KEEP) { // NO REFUND
            return ("", 0);
        } else {
            assembly {
                // 0x38 = 56 => PAYMASTER_DATA_OFFSET + 4
                premiumMode := calldataload(add(pmAndData.offset, 0x38))
            }
            if (refundMode == NODE_PM_MODE_USER) {
                refundReceiver = userOp.sender;
            } else if (refundMode == NODE_PM_MODE_DAPP) {
                // if fixed premium => no financial data => offset is 0x08
                // if % premium => financial data => offset is 0x08 + 0x18 = 0x20
                uint256 refundReceiverOffset = premiumMode == NODE_PM_PREMIUM_FIXED ? 0x08 : 0x20;

                // TODO: TEST AND BENCHMARK ASSEMBLY BLOCK vs SOLIDITY BLOCK

                assembly {
                    let o := add(0x34, refundReceiverOffset)
                    refundReceiver := shr(96, calldataload(add(pmAndData.offset, o)))
                }
                // refundReceiver = address(bytes20(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET+refundReceiverOffset:]));

            } else {
                revert InvalidNodePMRefundMode(refundMode);
            }
        }

        bytes memory context = _prepareContext({
            refundReceiver: refundReceiver,
            premiumMode: premiumMode, 
            maxCost: maxCost, 
            postOpGasLimit: userOp.unpackPostOpGasLimit(),
            paymasterAndData: userOp.paymasterAndData
        });

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
     * if mode is KEEP:
     * 0 bytes
     * ==== if there is a refund, always add ===
     * 20 bytes: refundReceiver
     * >== if there is implied cost add ===
     * 24 bytes: financial data:: impliedCost
     * 32 bytes: maxGasCost
     *        (76 bytes total)
     * >== if % premium mode also add ===
     * 24 bytes: financial data:: premiumPercentage
     * 32 bytes: maxGasCost
     * 32 bytes: postOpGasLimit 
     *        (108 bytes total) 
     * >== if fixed premium ====
     * 32 bytes: maxGasCost
     * 32 bytes: postOpGasLimit 
     *        (84 bytes total)
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
        } else if (context.length == 0x4c) { // 76 bytes => REFUND: Implied cost mode.
            // calc simple refund
            (refundReceiver, refund) = _handleImpliedCost(context);
        } else if (context.length == 0x54) { // 84 bytes => REFUND: fixed premium mode.
            (refundReceiver, refund) = _handleFixedPremium(context, actualGasCost, actualUserOpFeePerGas);
        } else if (context.length == 0x6c) { // 108 bytes => REFUND: % premium mode.
            (refundReceiver, refund) = _handlePercentagePremium(context, actualGasCost, actualUserOpFeePerGas);
        } else {
            revert InvalidContext(context.length);
        }

        // send refund to the superTxn sponsor
        if (refund > 0) {
                entryPoint.withdrawTo(payable(refundReceiver), refund);
        }
    }

    // ==== Helper functions ====

    function _prepareContext(
        address refundReceiver, 
        bytes4 premiumMode, 
        uint256 maxCost, 
        uint256 postOpGasLimit,
        bytes calldata paymasterAndData
    ) internal pure returns (bytes memory context) {
        context = abi.encodePacked(
            refundReceiver
        );

        if (premiumMode == NODE_PM_PREMIUM_IMPLIED) {
            uint192 impliedCost;
            // 0x3c = 60 => PAYMASTER_DATA_OFFSET + 8
            assembly {
                impliedCost := shr(64, calldataload(add(paymasterAndData.offset, 0x3c)))
            }
            context = abi.encodePacked(
                context,
                impliedCost,
                maxCost
            ); // 76 bytes
        } else if (premiumMode == NODE_PM_PREMIUM_PERCENT) {
            uint192 premiumPercentage;
            // 0x3c = 60 => PAYMASTER_DATA_OFFSET + 8
            assembly {
                premiumPercentage := shr(64, calldataload(add(paymasterAndData.offset, 0x3c)))
            }
            context = abi.encodePacked(
                context,
                premiumPercentage,
                maxCost, 
                postOpGasLimit
            ); // 108 bytes
        } else if (premiumMode == NODE_PM_PREMIUM_FIXED) {
            context = abi.encodePacked(
                context,
                maxCost, 
                postOpGasLimit
            ); // 84 bytes
        } else {
            revert InvalidNodePMPremiumMode(premiumMode);
        }
    }

    function _handleImpliedCost(bytes calldata context) internal pure returns (address refundReceiver, uint256 refund) {
        uint192 impliedCost;
        uint256 maxGasCost;
        assembly {
            refundReceiver := shr(96, calldataload(context.offset))
            impliedCost := shr(64, calldataload(add(context.offset, 0x14)))
            maxGasCost := calldataload(add(context.offset, 0x2c))
        }
        refund = maxGasCost - impliedCost;
    }

    function _handleFixedPremium(
        bytes calldata context, 
        uint256 actualGasCost, 
        uint256 actualUserOpFeePerGas
    ) internal pure returns (address refundReceiver, uint256 refund) {

        uint256 maxGasCost;
        uint256 postOpGasLimit;

        assembly {
            refundReceiver := shr(96, calldataload(context.offset))
            maxGasCost := calldataload(add(context.offset, 0x14))
            postOpGasLimit := calldataload(add(context.offset, 0x34))
        }

        // account for postOpGas
        actualGasCost += postOpGasLimit * actualUserOpFeePerGas;

        // when premium is fixed, payment by superTxn sponsor is maxGasCost + fixedPremium
        // so we refund just the gas difference, while fixedPremium is going to the MEE Node    
        refund = maxGasCost - actualGasCost;
    }

    function _handlePercentagePremium(
        bytes calldata context, 
        uint256 actualGasCost, 
        uint256 actualUserOpFeePerGas
    ) internal pure returns (address refundReceiver, uint256 refund) {

        uint192 premiumPercentage;
        uint256 maxGasCost;
        uint256 postOpGasLimit;

        assembly {
            refundReceiver := shr(96, calldataload(context.offset))
            premiumPercentage := shr(64, calldataload(add(context.offset, 0x14)))
            maxGasCost := calldataload(add(context.offset, 0x2c))
            postOpGasLimit := calldataload(add(context.offset, 0x4c))
        }

        // account for postOpGas
        actualGasCost += postOpGasLimit * actualUserOpFeePerGas;

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

    /// @dev This function is used to receive ETH from the user and immediately deposit it to the entryPoint
    receive() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }
}