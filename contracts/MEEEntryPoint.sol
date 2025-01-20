// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/interfaces/IEntryPointSimulations.sol";

import "forge-std/console2.sol";

contract MEEEntryPoint is BasePaymaster, ReentrancyGuard {
    using UserOperationLib for PackedUserOperation;

    uint256 public constant PREMIUM_CALCULATION_BASE = 100_00000; // 100% with 5 decimals precision
    // TODO: Measure this gas, and make it changeable
    uint256 public constant POSTOP_GAS = 50_000;

    error EmptyMessageValue();
    error InsufficientBalance();

    constructor(IEntryPoint _entryPoint) payable BasePaymaster(_entryPoint) {}

    /**
     * EntryPoint section
     */

    function handleOps(PackedUserOperation[] calldata ops) public payable {
        if (msg.value == 0) {
            revert EmptyMessageValue();
        }
        entryPoint.depositTo{value: msg.value}(address(this));
        entryPoint.handleOps(ops, payable(msg.sender));
        entryPoint.withdrawTo(payable(msg.sender), entryPoint.getDepositInfo(address(this)).deposit);
    }

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

    // accept all userOps
    // NODE OPERATOR PREMIUM expected to be the percentage (0-100) with 5 decimals precision
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
        // TODO: 
        // encode packed maxGasLimit and nodeOperatorPremium, make them smaller uints to save on calldata
        (uint256 maxGasLimit, uint256 nodeOperatorPremium) =
            abi.decode(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:], (uint256, uint256));
        return (abi.encode(userOp.sender, userOp.unpackMaxFeePerGas(), maxGasLimit, nodeOperatorPremium), 0);
    }

    /**
     * Post-operation handler.
     * (verified to be called only through the entryPoint)
     * executes userOp and gives back refund to the userOp.sender if userOp.sender has overpaid for execution.
     * @dev if subclass returns a non-empty context from validatePaymasterUserOp, it must also implement this method.
     * @param mode enum with the following options:
     *      opSucceeded - user operation succeeded.
     *      opReverted  - user op reverted. still has to pay for gas.
     *      postOpReverted - user op succeeded, but caused postOp (in mode=opSucceeded) to revert.
     *                       Now this is the 2nd call, after user's op was deliberately reverted.
     * @param context - the context value returned by validatePaymasterUserOp
     * @param actualGasCost - actual gas used so far (without this postOp call).
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        virtual
        override
    {   
        if (mode == PostOpMode.postOpReverted) {
            return;
        }
        (address sender, uint256 maxFeePerGas, uint256 maxGasLimit, uint256 nodeOperatorPremium) =
            abi.decode(context, (address, uint256, uint256, uint256));   

        // TODO: it also doesn't work properly , as it tries to refund more than left
        uint256 refund = calculateRefund(maxGasLimit, maxFeePerGas, actualGasCost/actualUserOpFeePerGas, actualUserOpFeePerGas, nodeOperatorPremium);
        console2.log("refund in MEEEntryPoint _postOp", refund);
        if (refund > 0) {
            entryPoint.withdrawTo(payable(sender), refund);
        }
        // TODO: emit event with the refund amount
    }

    function calculateRefund(
        uint256 maxGasLimit,
        uint256 maxFeePerGas,
        uint256 actualGasUsed,
        uint256 actualUserOpFeePerGas,
        uint256 nodeOperatorPremium
    ) public pure returns (uint256 refund) {

        //account for postOpGas
        actualGasUsed = actualGasUsed + POSTOP_GAS;

        // Add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge, as verification part of maxGasLimit is > verification part of actualGasUsed, but we are ok with that, at least we do not lose funds.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed)/10;

        console2.log("actual gas cost calculated by EP ", actualGasUsed * actualUserOpFeePerGas);

        // TODO: test it works properly with premiums less than 1% (for example 50000, which is 0.5%)
        uint256 costWithPremium = (actualGasUsed * actualUserOpFeePerGas * (PREMIUM_CALCULATION_BASE + nodeOperatorPremium)) / PREMIUM_CALCULATION_BASE;

        console2.log("cost with premium", costWithPremium);

        // as MEE_NODE charges user with the premium
        uint256 maxCost = maxGasLimit * maxFeePerGas * (PREMIUM_CALCULATION_BASE + nodeOperatorPremium) / PREMIUM_CALCULATION_BASE;

        // We do not check for the case, when costWithPremium > maxCost
        // maxCost charged by the MEE Node should include the premium
        // if this is done, costWithPremium can never be > maxCost
        if (costWithPremium < maxCost) {
            refund = maxCost - costWithPremium;
        }
    }
}
