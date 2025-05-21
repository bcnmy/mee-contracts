// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {DeterministicDeployerLib} from "./utils/DeterministicDeployerLib.sol";
import {NodePaymasterFactory} from "contracts/util/NodePaymasterFactory.sol";

contract DeployNodePaymasterFactory is Script {

    //bytes32 constant NODE_PMF_SALT = 0x0000000000000000000000000000000000000000082f0a9c0b993b04b8c0225e; // => 0x000000f28C524B5f80550a074910bf68bf69A446 
    bytes32 constant NODE_PMF_SALT = 0x0000000000000000000000000000000000000000082f0a9c0b993b04b8c02252; 

    function setUp() public {
     
    }

    function run(bool check) external {

        if (check) {
            _checkNodePMFAddress();
        } else {
            _deployNodePMF();
        }

    }

    function _checkNodePMFAddress() internal view {

        // =================== Node PMF Validator ===================
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymasterFactory/NodePaymasterFactory.json");

        address nodePMF = DeterministicDeployerLib.computeAddress(bytecode, NODE_PMF_SALT);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(nodePMF)
        }
        
        console2.log("Node PMF Addr: ", nodePMF, " || >> Code Size: ", codeSize);

        console2.log("Node PMF initcode for salt generation: ");
        console2.logBytes32(keccak256(bytecode));
    }

    function _deployNodePMF() internal {

        uint256 codeSize;

        // = Node PMF
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymasterFactory/NodePaymasterFactory.json");
        address expectedNodePMF = DeterministicDeployerLib.computeAddress(bytecode, NODE_PMF_SALT);
        assembly {
            codeSize := extcodesize(expectedNodePMF)
        }
        if (codeSize > 0) {
            console2.log("NodePMF already deployed at: ", expectedNodePMF, " skipping deployment");
        } else {
            address nodePMF = DeterministicDeployerLib.broadcastDeploy(bytecode, NODE_PMF_SALT);
            console2.log("Node Paymaster Factory deployed at: ", nodePMF);
        }
    }
}

/// ================================

