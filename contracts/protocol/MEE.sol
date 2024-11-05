// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MEE {
    address token;
    uint256 activeNodeSlots;

    uint256 maxNodeSlots = 1000; // 1k max node slots
    uint256 public minStakePerNode = 10_000 * 10 ** 18; // 10k tokens minimum to become a node operator
    uint256 public slashingThreshold = 1_000_000 * 10 ** 18; // 1M Tokens threshold to slash the node

    mapping(address => bool) activeNodes;

    constructor(address _token) {
        token = _token;
    }

    function stake(address nodeOperator, uint256 amount) external {
        // Staking logic:
        // 1. reject adding new node operator if max nodes reached
        // 2. reject adding stake to the existing operator if max staked tokens reached for the node
        // 3. allow others to delegate their stake to the existing node operators
    }

    function slash(address nodeOperator, bytes32 commitment, bytes memory quoteData) external {
        // Slashing logic:
        // 1. verify commitment and the quote - check if the conditions are met for starting a slashing procedure
        // 2. if slashing request does not exist initiate new slashing procedure
        // 3. add msg.sender votes to slash the node
        // 4. check if this vote has surpassed slashing threshold and if true - slash
    }
}
