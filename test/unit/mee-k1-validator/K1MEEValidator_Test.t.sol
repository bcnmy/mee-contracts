// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { MeeK1Validator_Base_Test } from "./MeeK1Validator_Base_Test.t.sol";
import { PackedUserOperation, UserOperationLib } from "account-abstraction/core/UserOperationLib.sol";
import { MEEUserOpHashLib } from "contracts/lib/util/MEEUserOpHashLib.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { MockTarget } from "../../mock/MockTarget.sol";
import { EIP1271_SUCCESS } from "contracts/types/Constants.sol";

contract K1MEEValidatorTest is MeeK1Validator_Base_Test {
    using UserOperationLib for PackedUserOperation;
    using MEEUserOpHashLib for PackedUserOperation;

    bytes32 internal constant APP_DOMAIN_SEPARATOR = 0xa1a044077d7677adbbfa892ded5390979b33993e0e2a457e3f974bbcda53821b;

    function setUp() public virtual override {
        super.setUp();
    }

    // test non-MEE flow
    function test_nonMEEFlow_ValidateUserOp_success() public {
        uint256 counterBefore = mockTarget.counter();
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);

        vm.deal(address(mockAccount), 100 ether);

        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: address(mockAccount),
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            wallet: wallet,
            preVerificationGasLimit: 3e5,
            verificationGasLimit: 500e3,
            callGasLimit: 3e6
        });

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        vm.startPrank(MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.counter(), counterBefore + 1);
    }

    function test_nonMEEFlow_validateSignatureWithData_success() public view {
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });
        bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOp);
        assertTrue(mockAccount.validateSignatureWithData(userOpHash, userOp.signature, abi.encodePacked(wallet.addr)));
    }

    function test_nonMEEFlow_isValidSignature_7739_success() public view {
        TestTemps memory t;
        t.contents = keccak256("0x1234");
        bytes32 dataToSign = toERC1271Hash(t.contents, address(mockAccount));
        (t.v, t.r, t.s) = vm.sign(wallet.privateKey, dataToSign);
        bytes memory contentsType = "Contents(bytes32 stuff)";
        bytes memory signature =
            abi.encodePacked(t.r, t.s, t.v, APP_DOMAIN_SEPARATOR, t.contents, contentsType, uint16(contentsType.length));
        bytes4 ret = mockAccount.isValidSignature(toContentsHash(t.contents), signature);
        assertEq(ret, bytes4(EIP1271_SUCCESS));
    }

    // ================================

    /// @notice Generates an ERC-1271 hash for the given contents and account.
    /// @dev This function is used for ERC-7739 flow
    /// @param contents The contents hash.
    /// @param account The account address.
    /// @return The ERC-1271 hash.
    function toERC1271Hash(bytes32 contents, address account) internal view returns (bytes32) {
        bytes32 parentStructHash = keccak256(
            abi.encodePacked(
                abi.encode(
                    keccak256(
                        "TypedDataSign(Contents contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)Contents(bytes32 stuff)"
                    ),
                    contents
                ),
                accountDomainStructFields(account)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", APP_DOMAIN_SEPARATOR, parentStructHash));
    }

    /// @notice Generates a contents hash.
    /// @param contents The contents hash.
    /// @return The EIP-712 hash.
    function toContentsHash(bytes32 contents) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", APP_DOMAIN_SEPARATOR, contents));
    }

    /// @notice Retrieves the EIP-712 domain struct fields.
    /// @param account The account address.
    /// @return The encoded EIP-712 domain struct fields.
    function accountDomainStructFields(address account) internal view returns (bytes memory) {
        AccountDomainStruct memory t;
        ( /*fields*/ , t.name, t.version, t.chainId, t.verifyingContract, t.salt, /*extensions*/ ) =
            EIP712(account).eip712Domain();

        return abi.encode(
            keccak256(bytes(t.name)),
            keccak256(bytes(t.version)),
            t.chainId,
            t.verifyingContract, // Use the account address as the verifying contract.
            t.salt
        );
    }
}
