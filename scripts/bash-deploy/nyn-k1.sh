{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet mainnet) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet sepolia) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet base) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet base-sepolia) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet polygon) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet amoy) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet arbitrum) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet arbitrum-sepolia) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet optimism) } # || { (printf "====== ALERT ======\nBSC :: probably errors => check logs\n====== ALERT ======\n") }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet optimism-sepolia) } 
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet bsc) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet bsc-testnet) }

{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet sonic-mainnet) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet sonic-blaze-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet scroll) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet scroll-sepolia) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet gnosis) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet gnosis-chiado) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet avalanche) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet fuji) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet apechain) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet apechain-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet hyperevm) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet coredao-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet neura-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet sei-mainnet) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet sei-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet unichain-mainnet) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet unichain-testnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet katana-mainnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet lisk-mainnet) }
{ (printf '==========================\n') }
{ (printf '%s\n' n y n | bash deploy-k1.sh mainnet worldchain-mainnet) }
{ (printf '%s\n' n y n | bash deploy-k1.sh testnet worldchain-testnet) }