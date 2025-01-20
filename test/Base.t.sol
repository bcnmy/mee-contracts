// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, Vm } from "forge-std/Test.sol";
import {MEEEntryPoint} from "../contracts/MEEEntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MockAccount} from "./mock/MockAccount.sol";
import {MockTarget} from "./mock/MockTarget.sol";

contract BaseTest is Test {

    address constant ENTRYPOINT_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant MEE_NODE_ADDRESS = 0x177EE170D31177Ee170D31177ee170d31177eE17;
    uint256 constant MEE_NODE_HEX = 0x177ee170de;

    IEntryPoint internal ENTRYPOINT;
    MEEEntryPoint internal MEE_ENTRYPOINT;
    MockTarget internal mockTarget;

    function setUp() public virtual {
        setupEntrypoint();
        deployMEEEntrypoint(ENTRYPOINT);
        vm.deal(MEE_NODE_ADDRESS, 1_000 ether);
        mockTarget = new MockTarget();
    }

    function deployMEEEntrypoint(IEntryPoint ep) internal {
        MEE_ENTRYPOINT = new MEEEntryPoint(ep);
    }

    function deployMockAccount() internal returns (MockAccount) {
        return new MockAccount();
    }

    function setupEntrypoint() internal {
        if (block.chainid == 31337) {
            if(address(ENTRYPOINT) != address(0)){
                return;
            }
            ENTRYPOINT = new EntryPoint();
            vm.etch(address(ENTRYPOINT_V07_ADDRESS), address(ENTRYPOINT).code);
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        } else {
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        }
    }

    function buildUserOpWithCalldata(
        address account,
        bytes memory callData,
        Vm.Wallet memory wallet
    )
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        uint256 nonce = ENTRYPOINT.getNonce(account, 0);
        userOp = buildPackedUserOp(account, nonce);
        userOp.callData = callData;

        bytes memory signature = signUserOp(wallet, userOp);
        userOp.signature = signature;
    }

    /// @notice Builds a user operation struct for account abstraction tests
    /// @param sender The sender address
    /// @param nonce The nonce
    /// @return userOp The built user operation
    function buildPackedUserOp(address sender, uint256 nonce) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(40e3), uint128(3e6))), // verification and call gas limit
            preVerificationGas: 3e5, // Adjusted preVerificationGas
            gasFees: bytes32(abi.encodePacked(uint128(11e9), uint128(1e9))), // maxFeePerGas = 11gwei and maxPriorityFeePerGas = 1gwei
            paymasterAndData: "",
            signature: ""
        });
    }

    function signUserOp(Vm.Wallet memory wallet, PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 opHash = ENTRYPOINT.getUserOpHash(userOp);
        opHash = MessageHashUtils.toEthSignedMessageHash(opHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, opHash);
        return abi.encodePacked(r, s, v);
    }

    function createAndFundWallet(string memory name, uint256 amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = newWallet(name);
        vm.deal(wallet.addr, amount);
        return wallet;
    }

    function newWallet(string memory name) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(name);
        vm.label(wallet.addr, name);
        return wallet;
    }

    function unpackMaxPriorityFeePerGasMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.gasFees);
    }

    function unpackMaxFeePerGasMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.gasFees);
    }

    function unpackVerificationGasLimitMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.accountGasLimits);
    }

    function unpackCallGasLimitMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.accountGasLimits);
    }
}

