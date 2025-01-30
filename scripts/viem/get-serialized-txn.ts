// import viem
import { concat, http, parseEther, parseGwei, serializeTransaction } from "viem";
import { anvil, localhost } from "viem/chains";
import { createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

//todo => get it as a param
const privateKey = "0x46a31f1f917570aa8a60b2339f1a0469cbce2feb53c705746446981548845b3b";
//const privateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const account = privateKeyToAccount(privateKey);

// create wallet with private key
const wallet = createWalletClient({
    account,
    chain: anvil,
    transport: http("http://localhost:8545")
})

const encodedTransfer = "0xa9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec580000"

// random one
// todo => get it as a param
const superTxHash = "0x1d69c064e2bd749cfe331b748be1dd5324cbf4e1839dda346cbb741a3e3169d1"
// concat transfer and superTxHash
const data = concat([encodedTransfer, superTxHash])
console.log(data);

/* const serialized = serializeTransaction({
    chainId: 1,
    gas: 21001n,
    maxFeePerGas: parseGwei('20'),
    maxPriorityFeePerGas: parseGwei('2'),
    nonce: 69,
    to: "0x7774512345123451234512345123451234512707",
    value: parseEther('0.01'),
    data: data
  })

console.log(serialized); */

/*
0x02f894014584773594008504a817c800825209947774512345123451234512345123451234512707872386f26fc10000b864a9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec5800003926631465ece4e56214cb286bce00b7a259e5d59cbde28c91b83ae4bf61fb01c0
*/

const request = await wallet.prepareTransactionRequest({ 
    to: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
    gas: 50000n,
    value: 0n,
    data: data
  })

console.log(request);   
   
const serializedTransaction = await wallet.signTransaction(request)

console.log(serializedTransaction);

//0x02f8d6827a6980843b9aca0084832156008256809470997970c51812dc3a010c7d01b50e0d17dc79c885174876e800b864a9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec5800001d69c064e2bd749cfe331b748be1dd5324cbf4e1839dda346cbb741a3e3169d1c080a0d6009b220503ba6ce9d2134d2a8d989014a800787fcbaad11e1add2feaf08befa0143ace885ce43abc60b1583d9603c0b6f8250edb656da6b63b689f6906791a9e
  


