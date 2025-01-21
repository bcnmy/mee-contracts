// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/interfaces/IEntryPointSimulations.sol";

/**
 * @title MEEEntryPoint
 * @notice A simple wrapper around the OG EntryPoint required for MEE.
 * Acts as a paymaster as well to pay for userOp processing.
 */

contract MEEEntryPoint is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes32;

    uint256 private constant PREMIUM_CALCULATION_BASE = 100_00000; // 100% with 5 decimals precision
    uint256 private postOpGas = 17_000;

    error EmptyMessageValue();
    error InsufficientBalance();
    error PaymasterVerificationGasLimitTooHigh();

    constructor(IEntryPoint _entryPoint) payable BasePaymaster(_entryPoint) {}

    /**
     * EntryPoint section
     */

    /**
     * @dev handle the userOps\
     * @dev Accepts the value from the MEE_NODE and deposits it to the OG EntryPoint
     * @dev Calls handleOps
     * @dev Withdraws its own deposit from the OG EntryPoint to the msg.sender which is MEE_NODE
     * This deposit at the point of withdrawal includes the MEE_NODE's premium
     * @param ops the userOps to handle
     */
    function handleOps(PackedUserOperation[] calldata ops) public payable {
        if (msg.value == 0) {
            revert EmptyMessageValue();
        }
        entryPoint.depositTo{value: msg.value}(address(this));
        entryPoint.handleOps(ops, payable(msg.sender));
        entryPoint.withdrawTo(payable(msg.sender), entryPoint.getDepositInfo(address(this)).deposit);
    }

    /**
     * @dev simulate the handleOp execution
     * @dev To be used with state overrides. Won't work in the wild as EP doesn't implement simulateHandleOp
     * @param op the userOp to execute
     * @param target the target address to call
     * @param callData the call data
     * @return executionResult the execution result
     */
    function simulateHandleOp(PackedUserOperation calldata op, address target, bytes calldata callData)
        external
        payable
        returns (IEntryPointSimulations.ExecutionResult memory)
    {
        if (msg.value == 0) {
            revert EmptyMessageValue();
        }
        IEntryPointSimulations entryPointWithSimulations = IEntryPointSimulations(address(entryPoint));
        entryPointWithSimulations.depositTo{value: msg.value}(address(this));
        return entryPointWithSimulations.simulateHandleOp(op, target, callData);
    }

    /**
     * @dev simulate the validation of the userOp
     * @dev To be used with state overrides. Won't work in the wild as EP doesn't implement simulateValidation
     * @param op the userOp to validate
     * @return validationResult the validation result
     */
    function simulateValidation(PackedUserOperation calldata op)
        external
        payable
        returns (IEntryPointSimulations.ValidationResult memory)
    {
        if (msg.value == 0) {
            revert EmptyMessageValue();
        }
        IEntryPointSimulations entryPointWithSimulations = IEntryPointSimulations(address(entryPoint));
        entryPointWithSimulations.depositTo{value: msg.value}(address(this));
        return entryPointWithSimulations.simulateValidation(op);
    }

    /**
     * Paymaster section
     */

    /**
     * @dev Accepts all userOps
     * In fact just repacks the data into the context and sends it to the postOp
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
        // This check is not needed because:
        // 1. EntryPoint already checks that the deposit is enough https://github.com/eth-infinitism/account-abstraction/blob/7af70c8993a6f42973f520ae0752386a5032abe7/contracts/core/EntryPoint.sol#L532
        // 2. It in fact never works properly because EP deducts deposit before calling validatePaymasterUserOp https://github.com/eth-infinitism/account-abstraction/blob/7af70c8993a6f42973f520ae0752386a5032abe7/contracts/core/EntryPoint.sol#L535 
        /*
        if (entryPoint.getDepositInfo(address(this)).deposit < maxCost) {
            revert InsufficientBalance();
        }
        */
        context = abi.encode(userOp.sender, userOp.unpackMaxFeePerGas(), bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:]));
        validationData = 0;
    }

    /**
     * Post-operation handler.
     * Checks mode and refunds the userOp.sender if needed.
     * @param mode enum with the following options:
     *      opSucceeded - user operation succeeded.
     *      opReverted  - user op reverted. still has to pay for gas.
     *      postOpReverted - user op succeeded, but caused postOp (in mode=opSucceeded) to revert.
     *                       Now this is the 2nd call, after user's op was deliberately reverted.
     * @param context - the context value returned by validatePaymasterUserOp
     * @param actualGasCost - actual gas used so far (without this postOp call).
     * @param actualUserOpFeePerGas - actual userOp fee per gas
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        virtual
        override
    {   
        if (mode == PostOpMode.postOpReverted) {
            return;
        }
        (address sender, uint256 maxFeePerGas, bytes32 pmData) =
            abi.decode(context, (address, uint256, bytes32));

        uint256 refund = _calculateRefund(maxFeePerGas, actualGasCost/actualUserOpFeePerGas, actualUserOpFeePerGas, pmData);
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
     * @param pmData the pm data : maxGasLimit and nodeOperatorPremium encoded as a single bytes32
     * @return refund the refund amount
     */
    function _calculateRefund(
        uint256 maxFeePerGas,
        uint256 actualGasUsed,
        uint256 actualUserOpFeePerGas,
        bytes32 pmData
    ) internal view returns (uint256 refund) {

        //account for postOpGas
        actualGasUsed = actualGasUsed + postOpGas;

        uint256 maxGasLimit = pmData.unpackHigh128();
        uint256 nodeOperatorPremium = pmData.unpackLow128();

        // Add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge, as verification part of maxGasLimit is > verification part of actualGasUsed, but we are ok with that, at least we do not lose funds.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed)/10;
        
        // account for MEE Node premium
        uint256 costWithPremium = (actualGasUsed * actualUserOpFeePerGas * (PREMIUM_CALCULATION_BASE + nodeOperatorPremium)) / PREMIUM_CALCULATION_BASE;

        // as MEE_NODE charges user with the premium
        uint256 maxCostWithPremium = maxGasLimit * maxFeePerGas * (PREMIUM_CALCULATION_BASE + nodeOperatorPremium) / PREMIUM_CALCULATION_BASE;

        // We do not check for the case, when costWithPremium > maxCost
        // maxCost charged by the MEE Node should include the premium
        // if this is done, costWithPremium can never be > maxCost
        if (costWithPremium < maxCostWithPremium) {
            refund = maxCostWithPremium - costWithPremium;
        }
    }

    /**
     * @dev set the gas cost for the post op executions
     * @param newPostOpGas the new gas cost
     */
    function setPostOpGas(uint256 newPostOpGas) external onlyOwner {
        postOpGas = newPostOpGas;
    } 
}
