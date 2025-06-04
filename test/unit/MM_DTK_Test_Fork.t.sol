// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../mock/MockTarget.sol";
import {MockAccount} from "../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {MEEUserOpHashLib} from "contracts/lib/util/MEEUserOpHashLib.sol";
import {MockERC20PermitToken} from "../mock/MockERC20PermitToken.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {EIP1271_SUCCESS, EIP1271_FAILED} from "contracts/types/Constants.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {MockDelegationManager} from "../mock/MockDelegationManager.sol";
import {IDelegationManager} from "contracts/lib/util/MMDelegationHelpers.sol";

interface IGetOwner {
    function getOwner(address account) external view returns (address);
}

contract MM_DTK_Test_Fork is BaseTest {
    using UserOperationLib for PackedUserOperation;
    using MEEUserOpHashLib for PackedUserOperation;
    using Strings for address;
    using Strings for uint256;

    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    bytes32 internal constant APP_DOMAIN_SEPARATOR = 0xa1a044077d7677adbbfa892ded5390979b33993e0e2a457e3f974bbcda53821b;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 valueToSet;

    function setUp() public virtual override {
        // create a fork of baseSepolia
        string memory baseSepoliaRpcUrl = vm.envString("BASE_SEPOLIA_RPC_URL");
        uint256 baseSepolia = vm.createFork(baseSepoliaRpcUrl);
        vm.selectFork(baseSepolia);

        super.setUp();
        wallet = createAndFundWallet("wallet", 5 ether);
        mockAccount = deployMockAccount({validator: address(k1MeeValidator), handler: address(0)});
        vm.prank(address(mockAccount));
        k1MeeValidator.transferOwnership(wallet.addr);
        valueToSet = MEE_NODE_HEX;
    }

    /// forge-config: default.fuzz.runs = 10
    function test_superTxFlow_mm_dtk_redeem_Delegation_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 25);
        uint256 amountToTransfer = 1 ether;

        IDelegationManager delegationManager = IDelegationManager(0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3);

        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        
        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);

        //Vm.Wallet memory alice = createAndFundWallet("alice", 5 ether);
        // 7702 delegate this wallet to the EIP7702StatelessDeleGatorImpl
        vm.etch(address(wallet.addr), abi.encodePacked(hex'ef0100', hex'63c0c19a282a1B52b07dD5a65b58948A07DAE32B'));
        deal(address(erc20), address(wallet.addr), amountToTransfer * (numOfClones + 10));
        
        // create superTxn with the delegation

        // this is the calldata to be used in the delegation caveat.terms
        bytes memory delegationInnerCalldata = abi.encodeWithSelector(
            erc20.approve.selector, 
            address(mockAccount), 
            amountToTransfer * (numOfClones + 1)
        );

        // this is the calldata to be used to redeem the delegation
        bytes memory redeemingExecutionCalldata = abi.encodeWithSelector(
            erc20.approve.selector, 
            address(mockAccount), 
            amountToTransfer * (numOfClones + 1)
        );

        // this is the calldata to be used in the superTxn, transfer tokens to bob
        bytes memory innerCallData = abi.encodeWithSelector(erc20.transferFrom.selector, wallet.addr, bob, amountToTransfer);

        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);
 
        userOps = makeDTKSuperTxWithRedeem({
            userOps: userOps,
            delegationSigner: wallet, //Delegator Account signs the delegation
            executionTo: address(erc20),
            allowedCalldata: delegationInnerCalldata,
            delegationManager: delegationManager,
            isRedeemTx: true,
            executionMode: bytes32(0), // this is the simple single erc7579 mode
            redeemExecutionCalldata: redeemingExecutionCalldata
        });

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer * (numOfClones + 1));
    }

    

    // ================================

    function buildBasicMEEUserOpWithCalldata(bytes memory callData, address account, Vm.Wallet memory userOpSigner)
        public
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: account,
            callData: callData,
            wallet: userOpSigner,
            preVerificationGasLimit: 3e5,
            verificationGasLimit: 500e3,
            callGasLimit: 3e6
        });

        userOp = makeMEEUserOp({
            userOp: userOp, 
            pmValidationGasLimit: 40_000, 
            pmPostOpGasLimit: 50_000, 
            impliedCostPercentageOfMaxGasCost: 75, 
            wallet: userOpSigner, 
            sigType: bytes4(0)
        });

        return userOp;
    }

}
