// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/Helpers.sol";
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/interfaces/IEntryPointSimulations.sol";

struct WithdrawalRequest {
    uint256 amount;
    address to;
    uint256 requestSubmittedTimestamp;
}

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
    
    // TODO: make this configurable
    uint256 private minDeposit = 0.001 ether;

    error InsufficientBalance(address nodeId, uint256 requiredBalance);
    error NodeIdCanNotBeZero();
    error DepositCanNotBeZero();
    error LowDeposit();
    error EmptyMessageValue();

    event NodeDeposited(address indexed nodeId, uint256 indexed amount);
    event OpProcessed(address indexed nodeId, bytes32 indexed opHash, uint256 gasCostCharged, uint256 premiumEarned);

    mapping(address => uint256) public nodeBalances;
    mapping(address => bool) internal _trustedNodes;
    mapping(address nodeId => WithdrawalRequest request) internal _requests;

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
/*     function handleOps(PackedUserOperation[] calldata ops) public payable {
        if (msg.value == 0) {
            revert EmptyMessageValue();
        }

        // Check msg.value is >= maxGasCost + maxGasCostWithPremium for all the ops
        // we can not do this in the validatePaymasterUserOp as the msg.value is joint for all the ops
        // and MEE EP deposit also includes the pre deposited funds
        // otherwise MEE_EP can unintentionally use its own deposit from SPM mode
        // also we do not want to revert is postOp (while idoing refund to the userOp.sender) after validating the userOp
        uint256 maxGasCostForAllOps = _getMaxGasCost(ops);
        require(msg.value >= maxGasCostForAllOps + _applyPremium(maxGasCostForAllOps), MessageValueTooLow());

        entryPoint.depositTo{value: msg.value}(address(this));
        entryPoint.handleOps(ops, payable(msg.sender));
        entryPoint.withdrawTo(payable(msg.sender), entryPoint.getDepositInfo(address(this)).deposit);
    } */

    function handleOps(PackedUserOperation[] calldata ops) public payable { 
        // node has an option to increase the deposit with the same call
        // the unused deposit will NOT be refunded after the call
        if (msg.value != 0) {
            //deposit to the OG EP and increase balance for a given node
            _depositFor(msg.sender);
        }
        entryPoint.handleOps(ops, payable(msg.sender));
    }

    function handleOpsWithRefund(PackedUserOperation[] calldata ops) public payable {
        handleOps(ops);
        nodeBalances[msg.sender] = 0;
        entryPoint.withdrawTo(payable(msg.sender), nodeBalances[msg.sender]);
    }

    // TODO: SHOULD rebuild simulation functions to use balance, not the value sent from the node?

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
        // at this point, maxGasCost is already locked by the OG EP as the prefund.
        // we now have to make sure that the node has enough balance to cover the refund to the userOp.sender for this given op
        // which can be up to maxGasCostWithPremium
        uint256 maxGasCost = _getMaxGasCost(userOp);
        uint256 nodeOperatorPremiumPercentage = uint256(bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:]));
        uint256 requiredBalance = maxGasCost + _applyPremium(maxGasCost, nodeOperatorPremiumPercentage);
        require(nodeBalances[tx.origin] >= requiredBalance, InsufficientBalance(tx.origin, requiredBalance)); //for verbosity
        nodeBalances[tx.origin] -= requiredBalance;

        context = abi.encode(
            userOp.sender,
            userOp.unpackMaxFeePerGas(),
            _getMaxGasLimit(userOp),
            nodeOperatorPremiumPercentage,
            requiredBalance,
            userOpHash
        );
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
        (address sender, uint256 maxFeePerGas, uint256 maxGasLimit, uint256 nodeOperatorPremiumPercentage, uint256 charged, bytes32 userOpHash) =
            abi.decode(context, (address, uint256, uint256, uint256, uint256, bytes32));

        // Refund the userOp.sender
        (uint256 opSenderRefund, uint256 actualGasUsed) = _calculateRefund(
            {
                maxGasLimit: maxGasLimit, 
                maxFeePerGas: maxFeePerGas, 
                actualGasUsed: actualGasCost/actualUserOpFeePerGas, 
                actualUserOpFeePerGas: actualUserOpFeePerGas, 
                nodeOperatorPremiumPercentage: nodeOperatorPremiumPercentage
            }
        );
        if (opSenderRefund > 0) {
            entryPoint.withdrawTo(payable(sender), opSenderRefund);
        }

        // update actualGasCost accounting for postOp and penalty
        actualGasCost = actualGasUsed * actualUserOpFeePerGas;
        
        // Refund node balance
        // Spends:
        // - actualGasCost is gas that was used by userOp. It is deducted from MEE_EP deposit by OG EP and refunded to the mee node by OG EP
        //   This amount is slightly higher that the actual gas used by the userOp (see _calculateRefund for details)
        //   That means MEE EP slightly overcharges the MEE_NODE, MEE_NODE should account for that when setting up the premium
        //   To make this overcharge as low as possible, MEE_NODE should set the verificationGasLimit and pmVerificationGasLimit as tight as possible
        // - opSenderRefund is also sent from the MEE_EP's deposit at OG EP
        nodeBalances[tx.origin] += charged - actualGasCost - opSenderRefund;
        emit OpProcessed(tx.origin, userOpHash, actualGasCost, _getPremium(actualGasCost, nodeOperatorPremiumPercentage));
    }

    /**
     * @dev calculate the refund that will be sent to the userOp.sender
     * It is required as userOp.sender has paid the maxCostWithPremium, but the actual cost was lower
     * @param maxGasLimit the max gas limit
     * @param maxFeePerGas the max fee per gas
     * @param actualGasUsed the actual gas used
     * @param actualUserOpFeePerGas the actual userOp fee per gas
     * @param nodeOperatorPremiumPercentage the node operator premium percentage
     * @return refund the refund amount
     */
    function _calculateRefund(
        uint256 maxGasLimit,
        uint256 maxFeePerGas,
        uint256 actualGasUsed,
        uint256 actualUserOpFeePerGas,
        uint256 nodeOperatorPremiumPercentage
    ) internal view returns (uint256, uint256) {

        // account for postOpGas. postOpGas is overestimated as we do not know the actual gas used by postOp in OG EP
        actualGasUsed = actualGasUsed + postOpGas;

        // Add penalty
        // We treat maxGasLimit - actualGasUsed as unusedGas and it is true if preVerificationGas, verificationGasLimit and pmVerificationGasLimit are tight enough.
        // If they are not tight, we overcharge userOp.sender, as verification part of maxGasLimit is > verification part of actualGasUsed =>
        // => penalty is higher than actual penalty => actualGasUsed is overestimated and refund is smaller.
        // This will be fixed when OG EP sends the actual penalty to the PM.
        // Details: https://docs.google.com/document/d/1WhJcMx8F6DYkNuoQd75_-ggdv5TrUflRKt4fMW0LCaE/edit?tab=t.0 
        actualGasUsed += (maxGasLimit - actualGasUsed)/10;
        
        // account for MEE Node premium
        uint256 actualCostWithPremium = _applyPremium(actualGasUsed * actualUserOpFeePerGas, nodeOperatorPremiumPercentage);

        // as MEE_NODE charges user with the premium
        uint256 maxCostWithPremium = _applyPremium(maxGasLimit * maxFeePerGas, nodeOperatorPremiumPercentage);

        // We do not check for the case, when costWithPremium > maxCost
        // maxCost charged by the MEE Node should include the premium
        // if this is done, costWithPremium can never be > maxCost
        uint256 refund;
        if (actualCostWithPremium < maxCostWithPremium) {
            refund = maxCostWithPremium - actualCostWithPremium;
        }
        return (refund, actualGasUsed);
    }

    /**
     * @dev set the gas cost for the post op executions
     * @param newPostOpGas the new gas cost
     */
    function setPostOpGas(uint256 newPostOpGas) external onlyOwner {
        postOpGas = newPostOpGas;
    } 

    function depositFor(address nodeId) external payable {
        if (nodeId == address(0)) revert NodeIdCanNotBeZero();
        if (msg.value == 0) revert DepositCanNotBeZero();
        _depositFor(nodeId);
    }

    function _depositFor(address nodeId) internal {
        if (nodeBalances[nodeId] + msg.value < minDeposit) revert LowDeposit();
        nodeBalances[nodeId] += msg.value;
        entryPoint.depositTo{ value: msg.value }(address(this));
        emit NodeDeposited(nodeId, msg.value);
    }

    function _getMaxGasCost(PackedUserOperation[] calldata ops) internal view returns (uint256 maxGasCost) {
        uint256 length = ops.length;
        for (uint256 i = 0; i < length; i++) {
            maxGasCost += _getMaxGasCost(ops[i]);
        }
    }

    function _getMaxGasCost(PackedUserOperation calldata op) internal view returns (uint256) {
        return _getMaxGasLimit(op) * op.unpackMaxFeePerGas();
    }

    function _getMaxGasLimit(PackedUserOperation calldata op) internal view returns (uint256) {
        return op.preVerificationGas + op.unpackVerificationGasLimit() + op.unpackCallGasLimit() + op.unpackPaymasterVerificationGasLimit() + op.unpackPostOpGasLimit();
    }

    function _applyPremium(uint256 cost, uint256 nodeOperatorPremiumPercentage) internal view returns (uint256 costWithPremium) {
        return cost * (PREMIUM_CALCULATION_BASE + nodeOperatorPremiumPercentage) / PREMIUM_CALCULATION_BASE;
    }

    function _getPremium(uint256 cost, uint256 nodeOperatorPremiumPercentage) internal view returns (uint256 premium) {
        return _applyPremium(cost, nodeOperatorPremiumPercentage) - cost;
    }

    // TODO : use custom base contract
    // so deposit() can not be used
    // how do we withdraw the leftovers only, never nodes' balances?
}
