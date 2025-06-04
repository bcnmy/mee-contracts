// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract MockDelegationManager {
    function getDomainHash() public pure returns (bytes32) {
        return bytes32(0x6e2134a4aa81c929e56cbd63e64774d7c6737c13e56cbd63e64774d7c6737c13); // some random hash   
    }
}
