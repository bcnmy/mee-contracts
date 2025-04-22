// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, Vm} from "forge-std/Test.sol";
import {NodePaymasterFactory} from "../../../contracts/util/NodePaymasterFactory.sol";
import {BaseTest, ENTRYPOINT_V07_ADDRESS} from "../../Base.t.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

contract NodePaymasterFactoryTest is BaseTest {

    NodePaymasterFactory factory;
    Vm.Wallet private owner;

    function setUp() public virtual override {
        super.setUp();
        factory = new NodePaymasterFactory();
        owner = createAndFundWallet("owner", 1000 ether);
    }

    function test_deployAndFundNodePaymaster_Success() public {
        address expectedPm = factory.getNodePaymasterAddress(ENTRYPOINT_V07_ADDRESS, owner.addr, 0);

        uint256 codeSize = expectedPm.code.length;
        assertEq(codeSize, 0);
        
        address nodePaymaster = factory.deployAndFundNodePaymaster{value: 1 ether}(ENTRYPOINT_V07_ADDRESS, owner.addr, 0);
        assertEq(nodePaymaster, expectedPm);

        uint256 deposit = IEntryPoint(ENTRYPOINT_V07_ADDRESS).getDepositInfo(nodePaymaster).deposit;
        assertEq(deposit, 1 ether);
    }

    

}

    