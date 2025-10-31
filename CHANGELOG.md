# @biconomy/mee-contracts

## 1.1.0
- MEE K1 Validator 1.1.0
- Node Paymaster 1.0.1
- Node Paymaster Factory 1.0.1

### Patch Changes
- Add SignTypedData support: in MEE simple mode, the EIP-712 data struct is signed, not a blind Stx hash

## 1.0.2
- MEE K1 Validator 1.0.4
- Node Paymaster 1.0.1
- Node Paymaster Factory 1.0.1

### Patch Changes
- Optimize keccak'ing stuff using solady/efficient hash lib
- Remove many unused parameters
- Do bunch of linting
- Add useful tools and gh actions
- Add versioning to Node PM and Node PM Factory
