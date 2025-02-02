import { concat, http } from "viem";
import { anvil } from "viem/chains";
import { createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

//todo => get it as a param
const privateKey = "0x46a31f1f917570aa8a60b2339f1a0469cbce2feb53c705746446981548845b3b"; //random wallet pk that is used in the tests

const account = privateKeyToAccount(privateKey);

// create wallet with private key
const wallet = createWalletClient({
    account,
    chain: anvil,
    transport: http("http://localhost:8545")
})

const encodedTransfer = "0xa9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec580000"

// userOps root
//const superTxHash = "0x1d69c064e2bd749cfe331b748be1dd5324cbf4e1839dda346cbb741a3e3169d1"

// some hash for non validate flow
const superTxHash = "0x5cb98b1166f4168a57931b88844fc8195271defd4b8e0f0c6422f5d7fbf6f7cf"

// concat transfer and superTxHash
const data = concat([encodedTransfer, superTxHash])
console.log(data);

const request = await wallet.prepareTransactionRequest({ 
    to: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
    gas: 50000n,
    value: 0n,
    data: data
  })

const serializedTransaction = await wallet.signTransaction(request)

console.log(serializedTransaction);  


