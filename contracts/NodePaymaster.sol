// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "account-abstraction/core/UserOperationLib.sol";
import { BaseNodePaymaster } from "./BaseNodePaymaster.sol";

/**
 * @title Node Paymaster
 * @notice A paymaster every MEE Node should deploy.
 * @dev Allows handleOps calls by any address allowed by owner().
 * It is used to sponsor userOps. Introduced for gas efficient MEE flow.
 */
contract NodePaymaster is BaseNodePaymaster {
    mapping(address workerEOA => bool isWhitelisted) private _workerEOAs;

    constructor(
        IEntryPoint _entryPoint,
        address _meeNodeMasterEOA,
        address[] memory workerEOAs
    )
        payable
        BaseNodePaymaster(_entryPoint, _meeNodeMasterEOA)
    {
        uint256 length = workerEOAs.length;
        for (uint256 i; i < length; ++i) {
            _workerEOAs[workerEOAs[i]] = true;
        }
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
     * 24 bytes: financial data:: premiumPercentage or fixedPremium
     * 20 bytes: refundReceiver (only for DAPP mode)
     *
     * @param userOp the userOp to validate
     * @param userOpHash the hash of the userOp
     * @param maxCost the max cost of the userOp
     * @return context the context to be used in the postOp
     * @return validationData the validationData to be used in the postOp
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        // solhint-disable-next-line avoid-tx-origin
        if (tx.origin == owner() || _workerEOAs[tx.origin]) {
            (context, validationData) = _validate(userOp, userOpHash, maxCost);
        } else {
            validationData = 1;
        }
    }

    // ====== Manage worker EOAs ======

    /**
     * @notice Whitelist a worker EOA
     * @param workerEOA The worker EOA to whitelist
     */
    function whitelistWorkerEOA(address workerEOA) external onlyOwner {
        _workerEOAs[workerEOA] = true;
    }

    /**
     * @notice Whitelist a list of worker EOAs
     * @param workerEOAs The list of worker EOAs to whitelist
     */
    function whitelistWorkerEOAs(address[] calldata workerEOAs) external onlyOwner {
        uint256 length = workerEOAs.length;
        for (uint256 i; i < length; ++i) {
            _workerEOAs[workerEOAs[i]] = true;
        }
    }

    /**
     * @notice Remove a worker EOA from the whitelist
     * @param workerEOA The worker EOA to remove from the whitelist
     */
    function removeWorkerEOAFromWhitelist(address workerEOA) external onlyOwner {
        _workerEOAs[workerEOA] = false;
    }

    /**
     * @notice Remove a list of worker EOAs from the whitelist
     * @param workerEOAs The list of worker EOAs to remove from the whitelist
     */
    function removeWorkerEOAsFromWhitelist(address[] calldata workerEOAs) external onlyOwner {
        uint256 length = workerEOAs.length;
        for (uint256 i; i < length; ++i) {
            _workerEOAs[workerEOAs[i]] = false;
        }
    }

    /**
     * @notice Check if a worker EOA is whitelisted
     * @param workerEOA The worker EOA to check
     * @return _isWhitelisted True if the worker EOA is whitelisted, false otherwise
     */
    function isWorkerEOAWhitelisted(address workerEOA) external view returns (bool _isWhitelisted) {
        _isWhitelisted = _workerEOAs[workerEOA];
    }

    /**
     * @notice Check if a list of worker EOAs are whitelisted
     * @param workerEOAs The list of worker EOAs to check
     * @return An array of booleans, where each element corresponds to the whitelist status of the corresponding worker EOA
     */
    /* solhint-disable-next-line gas-named-return-values */
    function areWorkerEOAsWhitelisted(address[] calldata workerEOAs) external view returns (bool[] memory) {
        bool[] memory whitelisted = new bool[](workerEOAs.length);
        uint256 length = workerEOAs.length;
        for (uint256 i; i < length; ++i) {
            whitelisted[i] = _workerEOAs[workerEOAs[i]];
        }
        return whitelisted;
    }

    /// @notice Returns the version of the NodePaymaster
    /// @return _version version of the NodePaymaster
    /// @dev adds versioning to the NodePaymaster
    function version() external pure returns (string memory _version) {
        _version = "1.0.1";
    }
}
