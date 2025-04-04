// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

contract NodePaymasterFactory {

    /// @notice The error thrown when the NodePaymaster deployment fails
    error NodePMDeployFailed();

    /// @notice Deploy and fund a new NodePaymaster
    /// @param entryPoint The 4337 EntryPoint address expected to call the NodePaymaster
    /// @param owner The owner of the NodePaymaster
    /// @param index The deployment index of the NodePaymaster
    /// @return nodePaymaster The address of the deployed NodePaymaster
    /// @dev The NodePaymaster is deployed using create2 with a deterministic address
    /// @dev The NodePaymaster is funded with the msg.value
    function deployAndFundNodePaymaster(address entryPoint, address owner, uint256 index) public payable returns (address nodePaymaster) {
        address expectedPm = _predictNodePaymasterAddress(entryPoint, owner, index);

        bytes memory deploymentData = abi.encodePacked(
                type(NodePaymaster).creationCode,
                abi.encode(entryPoint, owner)
            );

            assembly {
                nodePaymaster := create2(
                    0x0,
                    add(0x20, deploymentData),
                    mload(deploymentData),
                    index
                )
            }
            
            if(address(nodePaymaster) == address(0) || address(nodePaymaster) != expectedPm) {
                revert NodePMDeployFailed();
            }

            // deposit the msg.value to the EP at the node paymaster's name
            IEntryPoint(entryPoint).depositTo{value: msg.value}(nodePaymaster);
    }

    /// @notice Get the counterfactual address of a NodePaymaster
    /// @param entryPoint The 4337 EntryPoint address expected to call the NodePaymaster
    /// @param owner The owner of the NodePaymaster
    /// @param index The deployment index of the NodePaymaster
    /// @return nodePaymaster The counterfactual address of the NodePaymaster
    function getNodePaymasterAddress(address entryPoint, address owner, uint256 index) public view returns (address) {
        return _predictNodePaymasterAddress(entryPoint, owner, index);
    }

    // function to check if some EOA got PmContract deployed
    function _predictNodePaymasterAddress(address entryPoint, address owner, uint256 index) internal view returns (address) {
        bytes32 initCodeHash =
                keccak256(abi.encodePacked(
                    type(NodePaymaster).creationCode, 
                    abi.encode(entryPoint, owner)
                ));

        // Return the predicted address
        return payable(address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), index, initCodeHash))))));
    }

}
