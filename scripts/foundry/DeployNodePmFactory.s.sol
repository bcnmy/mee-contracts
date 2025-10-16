// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "node_modules/forge-std/src/Script.sol";
import {DeterministicDeployerLib} from "./utils/DeterministicDeployerLib.sol";
import {NodePaymasterFactory} from "../../../contracts/util/NodePaymasterFactory.sol";
import {CreateX} from "./utils/CreateX.sol";

contract DeployNodePaymasterFactory is Script {

    bytes32 constant NODE_PMF_SALT = 0x00000000000000000000000000000000000000000621b09c7f5c6b003de7bfc4; // => 0x000000005824a1ED617994dF733151D26a4cf03d

    bytes32 public constant DISPERSE_SALT = 0xfd73487f4e6544007a3ce4000000000000000000000000000000000000000000;
    bytes public constant DISPERSE_INITCODE = hex"608060405234801561001057600080fd5b506106f4806100206000396000f300608060405260043610610057576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff16806351ba162c1461005c578063c73a2d60146100cf578063e63d38ed14610142575b600080fd5b34801561006857600080fd5b506100cd600480360381019080803573ffffffffffffffffffffffffffffffffffffffff169060200190929190803590602001908201803590602001919091929391929390803590602001908201803590602001919091929391929390505050610188565b005b3480156100db57600080fd5b50610140600480360381019080803573ffffffffffffffffffffffffffffffffffffffff169060200190929190803590602001908201803590602001919091929391929390803590602001908201803590602001919091929391929390505050610309565b005b6101866004803603810190808035906020019082018035906020019190919293919293908035906020019082018035906020019190919293919293905050506105b0565b005b60008090505b84849050811015610301578573ffffffffffffffffffffffffffffffffffffffff166323b872dd3387878581811015156101c457fe5b9050602002013573ffffffffffffffffffffffffffffffffffffffff1686868681811015156101ef57fe5b905060200201356040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050602060405180830381600087803b1580156102ae57600080fd5b505af11580156102c2573d6000803e3d6000fd5b505050506040513d60208110156102d857600080fd5b810190808051906020019092919050505015156102f457600080fd5b808060010191505061018e565b505050505050565b60008060009150600090505b8585905081101561034657838382818110151561032e57fe5b90506020020135820191508080600101915050610315565b8673ffffffffffffffffffffffffffffffffffffffff166323b872dd3330856040518463ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020018281526020019350505050602060405180830381600087803b15801561041d57600080fd5b505af1158015610431573d6000803e3d6000fd5b505050506040513d602081101561044757600080fd5b8101908080519060200190929190505050151561046357600080fd5b600090505b858590508110156105a7578673ffffffffffffffffffffffffffffffffffffffff1663a9059cbb878784818110151561049d57fe5b9050602002013573ffffffffffffffffffffffffffffffffffffffff1686868581811015156104c857fe5b905060200201356040518363ffffffff167c0100000000000000000000000000000000000000000000000000000000028152600401808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200182815260200192505050602060405180830381600087803b15801561055457600080fd5b505af1158015610568573d6000803e3d6000fd5b505050506040513d602081101561057e57600080fd5b8101908080519060200190929190505050151561059a57600080fd5b8080600101915050610468565b50505050505050565b600080600091505b858590508210156106555785858381811015156105d157fe5b9050602002013573ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166108fc858585818110151561061557fe5b905060200201359081150290604051600060405180830381858888f19350505050158015610647573d6000803e3d6000fd5b5081806001019250506105b8565b3073ffffffffffffffffffffffffffffffffffffffff1631905060008111156106c0573373ffffffffffffffffffffffffffffffffffffffff166108fc829081150290604051600060405180830381858888f193505050501580156106be573d6000803e3d6000fd5b505b5050505050505600a165627a7a723058204f25a733917e0bf639cd1e101d55bd927f843fb395fb2a963a7909c09ae023ed0029"; 

    CreateX public createX;

    function setUp() public {
        
    }

    function run(bool check) external {

        if (check) {
            _checkNodePMFAddress();
        } else {
            _deployNodePMF();
        }

    }

    function _checkNodePMFAddress() internal view {

        // =================== Node PMF Validator ===================
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymasterFactory/NodePaymasterFactory.json");

        address nodePMF = DeterministicDeployerLib.computeAddress(bytecode, NODE_PMF_SALT);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(nodePMF)
        }
        
        console2.log("Node PMF Addr: ", nodePMF, " || >> Code Size: ", codeSize);

        console2.log("Node PMF initcode for salt generation: ");
        console2.logBytes32(keccak256(bytecode));

        // createx
        codeSize;
        address createXAddr = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
        assembly {
            codeSize := extcodesize(createXAddr)
        }
        
        if (codeSize == 0) {
            console2.log("CreateX not deployed at expected Addr");
        } else {
            console2.log("CreateX deployed at expected Addr");
        }
    }

    function _deployNodePMF() internal {

        uint256 codeSize;

        // = Node PMF
        bytes memory bytecode = vm.getCode("scripts/bash-deploy/artifacts/NodePaymasterFactory/NodePaymasterFactory.json");
        address expectedNodePMF = DeterministicDeployerLib.computeAddress(bytecode, NODE_PMF_SALT);
        assembly {
            codeSize := extcodesize(expectedNodePMF)
        }
        if (codeSize > 0) {
            console2.log("NodePMF already deployed at: ", expectedNodePMF, " skipping deployment");
        } else {
            address nodePMF = DeterministicDeployerLib.broadcastDeploy(bytecode, NODE_PMF_SALT);
            console2.log("Node Paymaster Factory deployed at: ", nodePMF);
        }

        // Disperse 
        assembly {
            codeSize := extcodesize(0xd15fE25eD0Dba12fE05e7029C88b10C25e8880E3)
        }
        if (codeSize == 0) {
            console2.log("Disperse not deployed at expected Addr, deploying...");
            createX = CreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
            address disperse = createX.deployCreate2(DISPERSE_SALT, DISPERSE_INITCODE);
            console2.log("Disperse now deployed at address:", disperse);
        } else {
            console2.log("Disperse already deployed at expected Addr");
        }
        

    }
}

/// ================================

