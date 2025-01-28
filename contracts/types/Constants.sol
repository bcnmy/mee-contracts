// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

bytes4 constant SIG_TYPE_OFF_CHAIN = 0x177eee00;
bytes4 constant SIG_TYPE_ON_CHAIN = 0x177eee01;
bytes4 constant SIG_TYPE_ERC20_PERMIT = 0x177eee02;
// ...other sig types: ERC-7683, Permit2, etc
