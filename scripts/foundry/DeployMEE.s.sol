// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "lib/forge-std/src/Script.sol";
import {K1MeeValidator} from "contracts/validators/K1MeeValidator.sol";
import {DeterministicDeployerLib} from "./utils/DeterministicDeployerLib.sol";

contract DeployMEE is Script {

    address constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    bytes32 constant MEE_EP_SALT = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 constant MEE_K1_VALIDATOR_SALT = 0x0000000000000000000000000000000000000000000000000000000000000000;
    
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

        // MEE Entry Point
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/MEEEntryPoint/MEEEntryPoint.json");
        bytes memory args = abi.encode(ENTRY_POINT_V07);

        address meeEntryPoint = DeterministicDeployerLib.computeAddress(bytecode, args, MEE_EP_SALT);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(meeEntryPoint)
        }
        
        console2.log("MEE Entry Point Addr: ", meeEntryPoint, " || >> Code Size: ", codeSize);
        
        console2.log("MEE EP initcode for salt generation: ");
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));

        // K1 MEE Validator
        bytecode = vm.getCode("scripts/bash-deploy/artifacts/K1MeeValidator/K1MeeValidator.json");

        address meeK1Validator = DeterministicDeployerLib.computeAddress(bytecode, MEE_K1_VALIDATOR_SALT);

        assembly {
            codeSize := extcodesize(meeK1Validator)
        }
        
        console2.log("MEE K1 Validator Addr: ", meeK1Validator, " || >> Code Size: ", codeSize);
    }

    function _deployMEE() internal {

        // MEE Entry Point
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/MEEEntryPoint/MEEEntryPoint.json");
        bytes memory args = abi.encode(ENTRY_POINT_V07);

        address expectedMEEEntryPoint = DeterministicDeployerLib.computeAddress(bytecode, args, MEE_EP_SALT);
        uint256 codeSize;
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
    }
}
