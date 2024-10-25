// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MEE {
    
    address token;
    uint256 activeNodeSlots;
    uint256 maxNodeSlots;
    uint256 minStakePerNode;

    mapping (address => bool) activeNodes;

    constructor(address _token) {
        token = _token;
    }

    function stake(address nodeOperator, uint256 amount) external {
        
    }
}
