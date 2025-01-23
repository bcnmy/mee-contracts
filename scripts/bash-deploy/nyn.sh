# TESTNETS
#printf '%s\n' n y n | bash deploy-mee.sh testnet sepolia
#printf '%s\n' n y n | bash deploy-mee.sh testnet base-sepolia
#printf '%s\n' n y n | bash deploy-mee.sh testnet scroll-sepolia
printf '%s\n' n y n | bash deploy-mee.sh testnet arbitrum-sepolia
#printf '%s\n' n y n | bash deploy-mee.sh testnet bsc-testnet
#{ (printf '%s\n' n y n | bash deploy-mee.sh testnet gnosis-chiado) } || { (printf "Gnosis chiado :: probably errors => check logs\n") }
printf '%s\n' n y n | bash deploy-mee.sh testnet amoy
#printf '%s\n' n y n | bash deploy-mee.sh testnet optimism-sepolia
#{ (printf '%s\n' n y n | bash deploy-mee.sh testnet berachain-bartio) } || { (printf "Berachain bartio :: probably errors => check logs\n") }


# MAINNETS
#printf '%s\n' n y n | bash deploy-mee.sh mainnet base
#printf '%s\n' n y n | bash deploy-mee.sh mainnet scroll
#printf '%s\n' n y n | bash deploy-mee.sh mainnet gnosis
#printf '%s\n' n y n | bash deploy-mee.sh mainnet bsc
printf '%s\n' n y n | bash deploy-mee.sh mainnet arbitrum
printf '%s\n' n y n | bash deploy-mee.sh mainnet polygon
#printf '%s\n' n y n | bash deploy-mee.sh mainnet optimism