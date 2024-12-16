#!/bin/bash

### VERIFY INPUTS ###
printMan() {
    printf "Usage: $0 <Environment: local|mainnet|testnet> <Network Name>\n"
}

if [ $# -eq 0 ]; then
    printf "Please provide private key, environment and network name\n"
    printMan
    exit 1
fi

if [ -z $1 ]; then
    printf "Please provide environment\n"
    printMan
    exit 1
fi

ENVIRONMENT=$1
VERIFY=""

if [ $ENVIRONMENT = "local" ]; then
    CHAIN_NAME="localhost"
else 
    if [ $ENVIRONMENT = "mainnet" ] || [ $ENVIRONMENT = "testnet" ]; then
        if [ -z $2 ]; then
            printf "Please provide network name\n"
            printMan
            exit 1
        fi
        CHAIN_NAME=$2
        VERIFY="--verify"
    else 
        printf "Invalid environment\n"
        printMan
        exit 1
    fi
fi

source ../../.env

# set private key based on the environment
if [ $ENVIRONMENT = "mainnet" ]; then
    PRIVATE_KEY=$MAINNET_DEPLOYER_PRIVATE_KEY
else 
    if [ $ENVIRONMENT = "testnet" ]; then
        PRIVATE_KEY=$TESTNET_DEPLOYER_PRIVATE_KEY
    else 
        PRIVATE_KEY=$LOCAL_DEPLOYER_PRIVATE_KEY
    fi
fi

### DEPLOY PRE-REQUISITES ###
{ (bash deploy-prerequisites.sh $PRIVATE_KEY $ENVIRONMENT $CHAIN_NAME) } || {
    printf "Deployment prerequisites failed\n"
    exit 1
}

### COPY ARTIFACTS ###
read -r -p "Do you want to rebuild MEE artifacts from your local sources? (y/n): " proceed
if [ $proceed = "y" ]; then
    ### BUILD ARTIFACTS ###
    printf "Building MEE artifacts\n"
    { (forge build 1> ./logs/forge-build.log 2> ./logs/forge-build-errors.log) } || {
        printf "Build failed\n See logs for more details\n"
        exit 1
    }
    printf "Copying MEE artifacts\n"
    mkdir -p ./artifacts/MEEEntryPoint
    mkdir -p ./artifacts/K1MeeValidator
    cp ../../out/MEEEntryPoint.sol/MEEEntryPoint.json ./artifacts/MEEEntryPoint/.
    cp ../../out/K1MeeValidator.sol/K1MeeValidator.json ./artifacts/K1MeeValidator/.
    printf "Artifacts copied\n"

    ### CREATE VERIFICATION ARTIFACTS ###
    printf "Creating verification artifacts\n"
    forge verify-contract --show-standard-json-input $(cast address-zero) MEEEntryPoint > ./artifacts/MEEEntryPoint/verify.json
    forge verify-contract --show-standard-json-input $(cast address-zero) K1MeeValidator > ./artifacts/K1MeeValidator/verify.json    
else 
    printf "Using precompiled artifacts\n"
fi

### DEPLOY MEE SCs ###
printf "Addresses for MEE SCs:\n"
mkdir -p ./logs/$CHAIN_NAME
forge script DeployMEE true --sig "run(bool)" --rpc-url $CHAIN_NAME -vv > ./logs/$CHAIN_NAME/$CHAIN_NAME-predeploy-mee.log
cat ./logs/$CHAIN_NAME/$CHAIN_NAME-predeploy-mee.log | grep -e "Addr" -e "already deployed"
printf "Do you want to proceed with the addresses above? (y/n): "
read -r proceed
if [ $proceed = "y" ]; then
    printf "Do you want to specify gas price? (y/n): "
    read -r proceed
    if [ $proceed = "y" ]; then
        printf "Enter gas prices args: \n For the EIP-1559 chains, enter two args: base fee and priority fee in gwei\n For the legacy chains, enter one argument. \n Example eip-1559: 20 1 \n Example legacy: 20 \n"
        read -r -a GAS_ARGS
        if [ ${#GAS_ARGS[@]} -eq 2 ]; then
            GAS_SUFFIX="--with-gas-price ${GAS_ARGS[0]}gwei --priority-gas-price ${GAS_ARGS[1]}gwei"
        else 
            GAS_SUFFIX="--with-gas-price ${GAS_ARGS[0]}gwei"
        fi
    else 
        GAS_SUFFIX=""
    fi
    {   
        printf "Proceeding with deployment \n"
        mkdir -p ./logs/$CHAIN_NAME
        forge script DeployMEE false --sig "run(bool)" --rpc-url $CHAIN_NAME --etherscan-api-key $CHAIN_NAME --private-key $PRIVATE_KEY $VERIFY -vv --broadcast --slow $GAS_SUFFIX 1> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-mee.log 2> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-mee-errors.log 
    } || {
        printf "Deployment failed\n See logs for more details\n"
        exit 1
    }
    printf "Deployment successful\n"
    cat ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-mee.log | grep -e "deployed at" -e "registered on registry"
    
else 
    printf "Exiting\n"
    exit 1
fi  