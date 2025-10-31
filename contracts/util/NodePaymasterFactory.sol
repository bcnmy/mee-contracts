// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { NodePaymaster } from "contracts/NodePaymaster.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";

/// @title NodePaymasterFactory
/// @notice A factory for deploying and funding NodePaymasters
/// @dev The NodePaymaster is deployed using create2 with a deterministic address
/// @dev The NodePaymaster is funded with the msg.value
/// @author Biconomy
contract NodePaymasterFactory {
    /// @notice The error thrown when the NodePaymaster deployment fails
    error NodePMDeployFailed();

    /// @notice Deploy and fund a new NodePaymaster
    /// @param entryPoint The 4337 EntryPoint address expected to call the NodePaymaster
    /// @param owner The owner of the NodePaymaster
    /// @param workerEoas The worker EOAs of a given node. Only those will be allowed
    /// to call handleOps
    /// @param index The deployment index of the NodePaymaster
    /// @return nodePaymaster The address of the deployed NodePaymaster
    /// @dev The NodePaymaster is deployed using create2 with a deterministic address
    /// @dev The NodePaymaster is funded with the msg.value
    function deployAndFundNodePaymaster(
        address entryPoint,
        address owner,
        address[] calldata workerEoas,
        uint256 index
    )
        public
        payable
        returns (address nodePaymaster)
    {
        address expectedPm = _predictNodePaymasterAddress(entryPoint, owner, workerEoas, index);

        bytes memory deploymentData =
            abi.encodePacked(type(NodePaymaster).creationCode, abi.encode(entryPoint, owner, workerEoas));

        assembly {
            nodePaymaster := create2(0x0, add(0x20, deploymentData), mload(deploymentData), index)
        }

        if (address(nodePaymaster) == address(0) || address(nodePaymaster) != expectedPm) {
            revert NodePMDeployFailed();
        }

        // deposit the msg.value to the EP at the node paymaster's name
        IEntryPoint(entryPoint).depositTo{ value: msg.value }(nodePaymaster);
    }

    /// @notice Get the counterfactual address of a NodePaymaster
    /// @param entryPoint The 4337 EntryPoint address expected to call the NodePaymaster
    /// @param owner The owner of the NodePaymaster
    /// @param workerEoas The worker EOAs of a given node. Only those will be allowed
    /// to call handleOps
    /// @param index The deployment index of the NodePaymaster
    /// @return nodePmAddress The counterfactual address of the NodePaymaster
    function getNodePaymasterAddress(
        address entryPoint,
        address owner,
        address[] calldata workerEoas,
        uint256 index
    )
        public
        view
        returns (address nodePmAddress)
    {
        nodePmAddress = _predictNodePaymasterAddress(entryPoint, owner, workerEoas, index);
    }

    /// @notice Function to check if some EOA got PmContract deployed
    /// @param entryPoint The 4337 EntryPoint address expected to call the NodePaymaster
    /// @param owner The owner of the NodePaymaster
    /// @param workerEoas The worker EOAs of a given node. Only those will be allowed
    /// to call handleOps
    /// @param index The deployment index of the NodePaymaster
    /// @return nodePmAddress The predicted address of the NodePaymaster
    function _predictNodePaymasterAddress(
        address entryPoint,
        address owner,
        address[] calldata workerEoas,
        uint256 index
    )
        internal
        view
        returns (address nodePmAddress)
    {
        /// forge-lint:disable-start(asm-keccak256)
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(NodePaymaster).creationCode, abi.encode(entryPoint, owner, workerEoas)));
        /// forge-lint:disable-end(asm-keccak256)

        // Return the predicted address
        uint256 predictedAddress;
        // keccak256(abi.encodePacked(bytes1(0xff), address(this), index, initCodeHash))
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 0x01), shl(96, address()))
            mstore(add(ptr, 0x15), index)
            mstore(add(ptr, 0x35), initCodeHash)
            predictedAddress := keccak256(ptr, 0x55)
        }
        return payable(address(uint160(predictedAddress)));
    }

    /// @notice Returns the version of the NodePaymasterFactory
    /// @return _version version of the NodePaymasterFactory
    /// @dev adds versioning to the NodePaymasterFactory
    function version() external pure returns (string memory _version) {
        _version = "1.0.1";
    }
}
