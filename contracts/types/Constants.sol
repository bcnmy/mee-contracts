// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

bytes3 constant SIG_TYPE_MEE_FLOW = 0x177eee;

bytes4 constant SIG_TYPE_SIMPLE = 0x177eee00;
bytes4 constant SIG_TYPE_ON_CHAIN = 0x177eee01;
bytes4 constant SIG_TYPE_ERC20_PERMIT = 0x177eee02;
bytes4 constant SIG_TYPE_MM_DELEGATION = 0x177eee03;
// ...other sig types: ERC-7683, Permit2, etc

bytes4 constant EIP1271_SUCCESS = 0x1626ba7e;
bytes4 constant EIP1271_FAILED = 0xffffffff;

uint256 constant MODULE_TYPE_STATELESS_VALIDATOR = 7;

bytes4 constant NODE_PM_MODE_USER = 0x170de000; // refund goes to the user
bytes4 constant NODE_PM_MODE_DAPP = 0x170de001; // refund goes to the dApp
bytes4 constant NODE_PM_MODE_KEEP = 0x170de002; // no refund as node sponsored

bytes4 constant NODE_PM_PREMIUM_PERCENT = 0x9ee4ce00; // premium percentage
bytes4 constant NODE_PM_PREMIUM_FIXED = 0x9ee4ce01; // fixed premium