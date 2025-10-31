// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Vm } from "forge-std/Test.sol";
import { NodePaymasterFactory } from "../../../contracts/util/NodePaymasterFactory.sol";
import { BaseTest, ENTRYPOINT_V07_ADDRESS } from "../../Base.t.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";

contract NodePaymasterFactoryTest is BaseTest {
    NodePaymasterFactory private _factory;
    Vm.Wallet private _owner;

    function setUp() public virtual override {
        super.setUp();
        _factory = new NodePaymasterFactory();
        _owner = createAndFundWallet("owner", 1000 ether);
    }

    function test_deployAndFundNodePaymaster_Success() public {
        address[] memory workerEOAs = new address[](1);
        workerEOAs[0] = MEE_NODE_EXECUTOR_EOA;

        address expectedPm = _factory.getNodePaymasterAddress(ENTRYPOINT_V07_ADDRESS, _owner.addr, workerEOAs, 0);

        uint256 codeSize = expectedPm.code.length;
        assertEq(codeSize, 0);

        address nodePaymaster =
            _factory.deployAndFundNodePaymaster{ value: 1 ether }(ENTRYPOINT_V07_ADDRESS, _owner.addr, workerEOAs, 0);
        assertEq(nodePaymaster, expectedPm);

        uint256 deposit = IEntryPoint(ENTRYPOINT_V07_ADDRESS).getDepositInfo(nodePaymaster).deposit;
        assertEq(deposit, 1 ether);
    }
}
