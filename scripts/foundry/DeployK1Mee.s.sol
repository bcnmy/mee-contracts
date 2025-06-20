// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {K1MeeValidator} from "contracts/validators/K1MeeValidator.sol";
import {DeterministicDeployerLib} from "./utils/DeterministicDeployerLib.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";

contract DeployK1 is Script {

    address constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant MODULE_REGISTRY_ADDRESS = 0x000000000069E2a187AEFFb852bF3cCdC95151B2;

    address constant ATTESTER_ADDRESS = 0xF9ff902Cdde729b47A4cDB55EF16DF3683a04EAB; // Biconomy Attester

    bytes32 constant MEE_K1_VALIDATOR_SALT = 0x000000000000000000000000000000000000000047819504fd5006001ee95238; //=> 0x00000000d12897DDAdC2044614A9677B191A2d95;
    bytes32 constant ETH_FORWARDER_SALT = 0x0000000000000000000000000000000000000000f9941fb84509c0031a6fc104; //=> 0x000000Afe527A978Ecb761008Af475cfF04132a1; 

    ModuleType[] moduleTypesToAttest;

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

        // =================== K1 MEE Validator ===================
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/K1MeeValidator/K1MeeValidator.json");

        address meeK1Validator = DeterministicDeployerLib.computeAddress(bytecode, MEE_K1_VALIDATOR_SALT);

        uint256 codeSize;
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

        uint256 codeSize;

        // K1 MEE Validator
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/K1MeeValidator/K1MeeValidator.json");
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
        
        if (registerModule(expectedMEEK1Validator)) {
            attestModule(expectedMEEK1Validator);
        }

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

    function registerModule(address moduleAddress) internal returns (bool) {
        IRegistryModuleManager registry = IRegistryModuleManager(MODULE_REGISTRY_ADDRESS);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(MODULE_REGISTRY_ADDRESS)
        }
        if (codeSize == 0) {
            console2.log("Module registry not deployed => module not registered on registry");
            return false;
        }
        ResolverUID resolverUID = ResolverUID.wrap(0xdbca873b13c783c0c9c6ddfc4280e505580bf6cc3dac83f8a0f7b44acaafca4f);
        ModuleRecord memory moduleRecord = registry.findModule(moduleAddress);

        bool isRegistered = ResolverUID.unwrap(moduleRecord.resolverUID) != bytes32(0x0000000000000000000000000000000000000000000000000000000000000000);
        bool res;
        if (isRegistered) {
            console2.log("Module already registered on registry");
            return true;
        } else {
            vm.startBroadcast();
            try registry.registerModule(
                resolverUID,
                moduleAddress,
                hex"",
                hex""
            ) {
                console2.log("Module registered on registry");
                res = true;
            } catch (bytes memory reason) {
                console2.log("Module not registered on registry: registration failed");
                console2.logBytes(reason);
                res = false;
            }
            vm.stopBroadcast();
        }
        return res;
    }

    function attestModule(address moduleAddress) internal returns (bool) {
        IRegistryModuleManager registry = IRegistryModuleManager(MODULE_REGISTRY_ADDRESS);

        address[] memory attesters = new address[](1);
        attesters[0] = ATTESTER_ADDRESS;
        
        ModuleType[] memory moduleTypes = new ModuleType[](1);
        moduleTypes[0] = ModuleType.wrap(uint256(1)); // validator

        // check if module is already attested
        uint256 needToAttest = 0;
        for (uint256 i; i < moduleTypes.length; i++) {
            ModuleType moduleType = moduleTypes[i];
            try registry.check(moduleAddress, moduleType, attesters, 1) {
                console2.log("Attestation as type %s successful, check passed", ModuleType.unwrap(moduleType));
            } catch (bytes memory reason) {
                console2.log("Module not attested as type %s, attesting...", ModuleType.unwrap(moduleType));
                needToAttest++;
                moduleTypesToAttest.push(moduleType);
            }
        }

        if (needToAttest == 0) {
            console2.log("Module already attested, skipping attestation");
            return true;
        }

        if (moduleTypesToAttest.length != needToAttest) {
            revert("Module types to attest mismatch");
        }

        AttestationRequest memory meeK1ValidatorAttestationRequest = AttestationRequest({
            moduleAddress: moduleAddress,
            expirationTime: uint48(block.timestamp + 3650 days),
            data: bytes(""),
            moduleTypes: moduleTypesToAttest
        });

        bytes memory cd = abi.encodeWithSelector(
            // attest(bytes32, AttestationRequest) (0x945e3641) 
            bytes4(0x945e3641),
            bytes32(0x93d46fcca4ef7d66a413c7bde08bb1ff14bacbd04c4069bb24cd7c21729d7bf1), //schema UID <= need to be added by Rhinestone to the registry
            meeK1ValidatorAttestationRequest
        );
        //console.logBytes(cd);

        vm.startBroadcast();

        IAttester attester = IAttester(ATTESTER_ADDRESS);

        try attester.adminExecute(Execution({
            target: MODULE_REGISTRY_ADDRESS,
            value: 0,
            callData: cd
        })) {
            console2.log("Attestation successful, re-checking");
            for (uint256 i; i < moduleTypesToAttest.length; i++) {
                ModuleType moduleType = moduleTypesToAttest[i];
                console2.log("Checking attestations for module %s with type %s", moduleAddress, ModuleType.unwrap(moduleType));
                try registry.check(moduleAddress, moduleType, attesters, 1) {
                    console2.log("Attestation successful, check passed");
                } catch (bytes memory reason) {
                    console2.log("Check failed");
                    console2.logBytes(reason);
                }
            }
        } catch (bytes memory reason) {
            console2.log("Attestation failed");
            console2.logBytes(reason);
        }

        vm.stopBroadcast();
    }
}

/// ================================

type ResolverUID is bytes32;

struct ModuleRecord {
    ResolverUID resolverUID; // The unique identifier of the resolver.
    address sender; // The address of the sender who deployed the contract
    bytes metadata; // Additional data related to the contract deployment
}

struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

type ModuleType is uint256;

struct AttestationRequest {
    address moduleAddress;
    uint48 expirationTime;
    bytes data;
    ModuleType[] moduleTypes;
}

interface IRegistryModuleManager {
    function registerModule(
        ResolverUID resolverUID,
        address moduleAddress,
        bytes calldata metadata,
        bytes calldata resolverContext
    ) external;

    function findModule(address moduleAddress) external view returns (ModuleRecord memory);

    function check(address module, ModuleType moduleType, address[] calldata attesters, uint256 threshold) external view;
}

interface IAttester {
    function adminExecute(Execution memory execution) external;
}
