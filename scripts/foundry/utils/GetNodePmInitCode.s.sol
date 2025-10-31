// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { Script, console2 } from "forge-std/Script.sol";
import { NodePaymaster } from "../../../contracts/NodePaymaster.sol";

contract GetNodePmInitCode is Script {
    function setUp() public { }

    function run() public {
        bytes memory initCode = type(NodePaymaster).creationCode;
        console2.logBytes(initCode);
    }
}
