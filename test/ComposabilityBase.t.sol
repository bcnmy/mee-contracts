// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Base.t.sol";
import {MockAccountFallback} from "./mock/MockAccountFallback.sol";
import {MockAccountNonRevert} from "./mock/MockAccountNonRevert.sol";
import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";
import {MockAccountDelegateCaller} from "./mock/MockAccountDelegateCaller.sol";
import {MockAccountCaller} from "./mock/MockAccountCaller.sol";
contract ComposabilityTestBase is BaseTest {
    ComposableExecutionModule internal composabilityHandler;
    MockAccountFallback internal mockAccountFallback;
    MockAccountDelegateCaller internal mockAccountDelegateCaller;
    MockAccountCaller internal mockAccountCaller;
    MockAccountNonRevert internal mockAccountNonRevert;
    MockAccount internal mockAccount;

    function setUp() public virtual override {
        super.setUp();
        composabilityHandler = new ComposableExecutionModule();
        mockAccountFallback = new MockAccountFallback({
            _validator: address(0),
            _executor: address(composabilityHandler),
            _handler: address(composabilityHandler)
        });
        mockAccountCaller = new MockAccountCaller({
            _validator: address(0),
            _executor: address(composabilityHandler),
            _handler: address(composabilityHandler)
        });
        mockAccountDelegateCaller = new MockAccountDelegateCaller({
            _composableModule: address(composabilityHandler)
        });

        vm.prank(address(mockAccountFallback));
        composabilityHandler.onInstall(abi.encodePacked(ENTRYPOINT_V07_ADDRESS));

        mockAccount = deployMockAccount({validator: address(0), handler: address(0xa11ce)});
        mockAccountNonRevert = new MockAccountNonRevert({_validator: address(0), _handler: address(0xa11ce)});

        // fund accounts
        vm.deal(address(mockAccountFallback), 100 ether);
        vm.deal(address(mockAccountDelegateCaller), 100 ether);
        vm.deal(address(mockAccountCaller), 100 ether);
        vm.deal(address(mockAccountNonRevert), 100 ether);
        vm.deal(address(mockAccount), 100 ether);
    }
}
