// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/interfaces/IEntryPointSimulations.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 * @dev Should be deployed via Factory only.
 */

 struct PMConfig {
    address meeNodeAddress;
    uint96 nodeOperatorPremiumPercentage;
 }

contract NodePaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes32;

    uint256 private constant PREMIUM_CALCULATION_BASE = 100_00000; // 100% with 5 decimals precision
    PMConfig public pmConfig;
    uint256 private postOpGas = 50_000;
    mapping(bytes32 => bool) private executedUserOps;

    error EmptyMessageValue();
    error InsufficientBalance();
    error PaymasterVerificationGasLimitTooHigh();

    error OnlySponsorOwnStuff();

    // TODO: fix argument for ownable as it is msg.sender now while need to be meeNodeAddress

    // TODO: fix Base Paymaster in terms of exposed methods, does this one work or we need custom BasePaymaster?

    constructor(
        IEntryPoint _entryPoint,
        address _meeNodeAddress,
        uint96 _nodeOperatorPremiumPercentage
    ) payable BasePaymaster(_entryPoint) {
        pmConfig = PMConfig({
            meeNodeAddress: _meeNodeAddress,
            nodeOperatorPremiumPercentage: _nodeOperatorPremiumPercentage
        });
    }

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
        PMConfig memory pmConfig = pmConfig;
        require(tx.origin == pmConfig.meeNodeAddress, OnlySponsorOwnStuff());
        
        context = abi.encode(userOp.sender, userOp.unpackMaxFeePerGas(), _getMaxGasLimit(userOp), pmConfig.nodeOperatorPremiumPercentage, userOpHash);
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
        (address sender, uint256 maxFeePerGas, uint256 maxGasLimit, uint96 premiumPercentage, bytes32 userOpHash) =
            abi.decode(context, (address, uint256, uint256, uint96, bytes32));

        executedUserOps[userOpHash] = true;

        uint256 refund = _calculateRefund(maxFeePerGas, actualGasCost/actualUserOpFeePerGas, actualUserOpFeePerGas, maxGasLimit, premiumPercentage);
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
        uint96 premiumPercentage
    ) internal view returns (uint256 refund) {

        //account for postOpGas
        actualGasUsed = actualGasUsed + postOpGas;

        // Add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge, as verification part of maxGasLimit is > verification part of actualGasUsed, but we are ok with that, at least we do not lose funds.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed)/10;

        //uint256 premiumPercentageMemory = NODE_OPERATOR_PREMIUM_PERCENTAGE; 
        
        // account for MEE Node premium
        uint256 costWithPremium = (actualGasUsed * actualUserOpFeePerGas * (PREMIUM_CALCULATION_BASE + premiumPercentage)) / PREMIUM_CALCULATION_BASE;

        // as MEE_NODE charges user with the premium
        uint256 maxCostWithPremium = maxGasLimit * maxFeePerGas * (PREMIUM_CALCULATION_BASE + premiumPercentage) / PREMIUM_CALCULATION_BASE;

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

    function _getMaxGasCost(PackedUserOperation calldata op) internal view returns (uint256) {
        return _getMaxGasLimit(op) * op.unpackMaxFeePerGas();
    }

    function _getMaxGasLimit(PackedUserOperation calldata op) internal view returns (uint256) {
        return op.preVerificationGas + op.unpackVerificationGasLimit() + op.unpackCallGasLimit() + op.unpackPaymasterVerificationGasLimit() + op.unpackPostOpGasLimit();
    }
}
