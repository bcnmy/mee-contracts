// import viem
import { concat, http, parseEther, parseGwei, serializeTransaction } from "viem";
import { localhost } from "viem/chains";
import { createWalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

//todo => get it as a param
const privateKey = "0x46a31f1f917570aa8a60b2339f1a0469cbce2feb53c705746446981548845b3b";

// create wallet with private key
const wallet = createWalletClient({
    chain: localhost,
    transport: http("http://localhost:8545")
})

const account = privateKeyToAccount(privateKey);

const encodedTransfer = "0xa9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec580000"

// random one
// todo => get it as a param
const superTxHash = "0x3926631465ece4e56214cb286bce00b7a259e5d59cbde28c91b83ae4bf61fb01"
// concat transfer and superTxHash
const data = concat([encodedTransfer, superTxHash])
console.log(data);

const serialized = serializeTransaction({
    chainId: 1,
    gas: 21001n,
    maxFeePerGas: parseGwei('20'),
    maxPriorityFeePerGas: parseGwei('2'),
    nonce: 69,
    to: "0x7774512345123451234512345123451234512707",
    value: parseEther('0.01'),
    data: data
  })

console.log(serialized);

/*
0x02f894014584773594008504a817c800825209947774512345123451234512345123451234512707872386f26fc10000b864a9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec5800003926631465ece4e56214cb286bce00b7a259e5d59cbde28c91b83ae4bf61fb01c0
*/