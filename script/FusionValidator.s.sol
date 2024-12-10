// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "lib/forge-std/src/Script.sol";
import {K1MeeValidator} from "../contracts/validators/K1MeeValidator.sol";
import {DeterministicDeployFactory} from "../contracts/deployer/DeterministicDeployFactory.sol";

contract DeployFusionValidator is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        DeterministicDeployFactory factory = DeterministicDeployFactory(vm.envAddress("DEPLOYER_FACTORY"));
    }
}
