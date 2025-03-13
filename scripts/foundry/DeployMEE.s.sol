// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {K1MeeValidator} from "contracts/validators/K1MeeValidator.sol";
import {DeterministicDeployerLib} from "./utils/DeterministicDeployerLib.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";

type ResolverUID is bytes32;

struct ModuleRecord {
    ResolverUID resolverUID; // The unique identifier of the resolver.
    address sender; // The address of the sender who deployed the contract
    bytes metadata; // Additional data related to the contract deployment
}

interface IRegistryModuleManager {
    function registerModule(
        ResolverUID resolverUID,
        address moduleAddress,
        bytes calldata metadata,
        bytes calldata resolverContext
    ) external;

    function findModule(address moduleAddress) external view returns (ModuleRecord memory);
}

contract DeployMEE is Script {

    address constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant MODULE_REGISTRY_ADDRESS = 0x000000000069E2a187AEFFb852bF3cCdC95151B2;

    address constant MEE_NODE_ADDRESS = 0x4b19129EA58431A06D01054f69AcAe5de50633b6;

    bytes32 constant NODE_PM_BICO_SALT = 0x0000000000000000000000000000000000000000501b432898ec1104da3714bc; // => 0x000000EF48a36e5C1E37B6d7519BF296E610fd89
    bytes32 constant MEE_EP_SALT = 0x00000000000000000000000000000000000000005cc6ccbe3c6475039340efcb; // => 0x0000000083EA22441344A6aDec0a72858484bB9B
    bytes32 constant MEE_K1_VALIDATOR_SALT = 0x000000000000000000000000000000000000000071f7e488ac1c920333dec4c8; // => 0x000000002b5Ba85adc15B1640E3b523FF34A61e9; 
    bytes32 constant ETH_FORWARDER_SALT = 0x00000000000000000000000000000000000000008f1af550db65a6032eca72b3; // => 0x0000000088ca766994Ce7F0aa842aB98c63244fA

    function setUp() public {
     
    }

    function run(bool check) external {

        if (check) {
            _checkMEEAddresses();
        } else {
            _deployMEE();
        }

    }

    function _checkMEEAddresses() internal {
        // =================== Node Paymaster contract
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymaster/NodePaymaster.json");
        bytes memory args = abi.encode(ENTRY_POINT_V07, MEE_NODE_ADDRESS);
        address expectedNodePaymaster = DeterministicDeployerLib.computeAddress(bytecode, args, NODE_PM_BICO_SALT);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(expectedNodePaymaster)
        }
        console2.log("Node Paymaster Addr: ", expectedNodePaymaster, " || >> Code Size: ", codeSize);

        console2.log("Node PM initcode for salt generation: ");
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));

        address noBroadcastDeployedNodePMAddress;
        //No broadcast
        if (codeSize == 0) {
            noBroadcastDeployedNodePMAddress = DeterministicDeployerLib.deploy(bytecode, args, NODE_PM_BICO_SALT);
        } else {
            noBroadcastDeployedNodePMAddress = expectedNodePaymaster;
        }
        //console2.log("Simulated deployement Node Paymaster Addr: ", noBroadcastDeployedNodePMAddress);
        bytes32 expectedNodePMCodeHash;
        assembly {
            expectedNodePMCodeHash := extcodehash(noBroadcastDeployedNodePMAddress)
        }
        //console2.logBytes32(expectedNodePMCodeHash);

        // =================== MEE Entry Point ===================
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/MEEEntryPoint/MEEEntryPoint.json");
        args = abi.encode(ENTRY_POINT_V07, expectedNodePMCodeHash);

        address meeEntryPoint = DeterministicDeployerLib.computeAddress(bytecode, args, MEE_EP_SALT);

        assembly {
            codeSize := extcodesize(meeEntryPoint)
        }
        
        console2.log("MEE Entry Point Addr: ", meeEntryPoint, " || >> Code Size: ", codeSize);
        
        console2.log("MEE EP initcode for salt generation: ");
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));

        // =================== K1 MEE Validator ===================
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/K1MeeValidator/K1MeeValidator.json");

        address meeK1Validator = DeterministicDeployerLib.computeAddress(bytecode, MEE_K1_VALIDATOR_SALT);

        assembly {
            codeSize := extcodesize(meeK1Validator)
        }
        
        console2.log("MEE K1 Validator Addr: ", meeK1Validator, " || >> Code Size: ", codeSize);

        console2.log("MEE K1 Validator initcode for salt generation: ");
        console2.logBytes32(keccak256(bytecode));

        // =================== ETH Forwarder contract ===================
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/EtherForwarder/EtherForwarder.json");
        address expectedEtherForwarder = DeterministicDeployerLib.computeAddress(bytecode, ETH_FORWARDER_SALT);
        assembly {
            codeSize := extcodesize(expectedEtherForwarder)
        }
        console2.log("ETH Forwarder Addr: ", expectedEtherForwarder, " || >> Code Size: ", codeSize);

        console2.log("ETH Forwarder initcode for salt generation: ");
        console2.logBytes32(keccak256(bytecode));

    }

    function _deployMEE() internal {
        // Node Paymaster contract
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymaster/NodePaymaster.json");
        bytes memory args = abi.encode(ENTRY_POINT_V07, MEE_NODE_ADDRESS);
        address expectedNodePaymaster = DeterministicDeployerLib.computeAddress(bytecode, args, NODE_PM_BICO_SALT);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(expectedNodePaymaster)
        }
        address nodePaymaster = expectedNodePaymaster;
        if (codeSize > 0) {
            console2.log("Node Paymaster already deployed at: ", expectedNodePaymaster, " skipping deployment");
        } else {
            nodePaymaster = DeterministicDeployerLib.broadcastDeploy(bytecode, args, NODE_PM_BICO_SALT);
            require(nodePaymaster == expectedNodePaymaster, "Node Paymaster address mismatch");
            console2.log("Node Paymaster deployed at: ", nodePaymaster);
        }

        bytes32 nodePMCodeHash;
        assembly {
            nodePMCodeHash := extcodehash(nodePaymaster)
        }

        // MEE Entry Point
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/MEEEntryPoint/MEEEntryPoint.json");
        args = abi.encode(ENTRY_POINT_V07, nodePMCodeHash);

        address expectedMEEEntryPoint = DeterministicDeployerLib.computeAddress(bytecode, args, MEE_EP_SALT);
        assembly {
            codeSize := extcodesize(expectedMEEEntryPoint)
        }
        if (codeSize > 0) {
            console2.log("MEE Entry Point already deployed at: ", expectedMEEEntryPoint, " skipping deployment");
        } else {
            address meeEntryPoint = DeterministicDeployerLib.broadcastDeploy(bytecode, args, MEE_EP_SALT);
            console2.log("MEE Entry Point deployed at: ", meeEntryPoint);
        }

        // K1 MEE Validator
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/K1MeeValidator/K1MeeValidator.json");
        address expectedMEEK1Validator = DeterministicDeployerLib.computeAddress(bytecode, MEE_K1_VALIDATOR_SALT);
        assembly {
            codeSize := extcodesize(expectedMEEK1Validator)
        }
        if (codeSize > 0) {
            console2.log("MEE K1 Validator already deployed at: ", expectedMEEK1Validator, " skipping deployment");
        } else {
            address meeK1Validator = DeterministicDeployerLib.broadcastDeploy(bytecode, MEE_K1_VALIDATOR_SALT);
            console2.log("MEE K1 Validator deployed at: ", meeK1Validator);
        }
        
        registerModule(expectedMEEK1Validator);

        // ETH Forwarder contract
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/EtherForwarder/EtherForwarder.json");
        address expectedEtherForwarder = DeterministicDeployerLib.computeAddress(bytecode, ETH_FORWARDER_SALT);
        assembly {
            codeSize := extcodesize(expectedEtherForwarder)
        }
        if (codeSize > 0) {
            console2.log("ETH Forwarder already deployed at: ", expectedEtherForwarder, " skipping deployment");
        } else {
            address etherForwarder = DeterministicDeployerLib.broadcastDeploy(bytecode, ETH_FORWARDER_SALT);
            console2.log("ETH Forwarder deployed at: ", etherForwarder);
        }

    }

    function registerModule(address moduleAddress) internal {
        IRegistryModuleManager registry = IRegistryModuleManager(MODULE_REGISTRY_ADDRESS);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(MODULE_REGISTRY_ADDRESS)
        }
        if (codeSize == 0) {
            console2.log("Module registry not deployed => module not registered on registry");
            return;
        }
        ResolverUID resolverUID = ResolverUID.wrap(0xdbca873b13c783c0c9c6ddfc4280e505580bf6cc3dac83f8a0f7b44acaafca4f);
        ModuleRecord memory moduleRecord = registry.findModule(moduleAddress);

        bool isRegistered = ResolverUID.unwrap(moduleRecord.resolverUID) != bytes32(0x0000000000000000000000000000000000000000000000000000000000000000);
        if (isRegistered) {
            console2.log("Module already registered on registry");
        } else {
            vm.startBroadcast();
            try registry.registerModule(
                resolverUID,
                moduleAddress,
                hex"",
                hex""
            ) {
                console2.log("Module registered on registry");
            } catch (bytes memory reason) {
                console2.log("Module not registered on registry: registration failed");
                console2.logBytes(reason);
            }
            vm.stopBroadcast();
        }
    }
}
