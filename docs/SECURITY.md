# Local security review and boundaries

The local checks establish application behavior under controlled mocks. They are
not an independent adversarial review of this bridge, its live dependencies, or
the planned LayerZero security configuration. A separate contributor should review
the final application and remote deployment before funds are bridged. No live
chain calls, deployment, Slither run, or Mythril run was performed.

The supplied protected check was read. `ZTOAdapterDeployment.t.sol` reproduces its
relevant constructor, CREATE2, EIP-170 size, initcode size, and forbidden-runtime-
opcode properties without depending on its environment configuration. The protected
test itself is an input, not a delivered or modified test.

## Custody and authorization

`send` debits `msg.sender` through SafeERC20 and forwards its packet through the
fixed endpoint. A revert anywhere in that transaction restores custody, allowance,
and ETH. The adapter has no mutable per-user accounting or owner withdrawal path.
The standard adapter assumes a lossless, non-rebasing token; no balance-delta
correction has been added. Tests cover normal, empty-return, false-return, and
reverting transfers. Fee-on-transfer or rebasing behavior is unsupported.

`lzReceive` accepts only the fixed endpoint and the configured peer for the source
EID. The adapter does not duplicate the endpoint's replay ledger. The mock models
single consumption and rollback so tests can exercise retry without claiming to
prove the real endpoint. A compromised endpoint, verification configuration, owner,
or remote mint/burn OFT can violate the custody guarantee.

There is no extra reentrancy guard around upstream OFT logic. There is no reusable
local withdrawal allowance or stale per-user balance to consume. A nested send still
debits its own caller; a token callback cannot authenticate itself as the endpoint
or call the self-only simulation entrypoint. The callback tests exercise both
restrictions. Endpoint replay consumption must occur before receiver execution.
The fixed token and endpoint must still be reviewed for their actual behavior.

Precrime simulation allows trusted-shaped packets but always reverts at completion.
Tests confirm that even a simulated successful custody release is rolled back.
Composed receives queue work after crediting tokens; failure to queue reverts the
credit. Execution of queued compose work later is independent of that credit.

## Compiler and lint review

The optimized runtime measured 11,669 bytes with Solidity 0.8.26, below the 24,576
byte limit. The deployed opcode scan rejects `DELEGATECALL`, `CALLCODE`, and
`SELFDESTRUCT`. OpenZeppelin's vendored `Address.sol` includes a generic
`functionDelegateCall` helper, but it is unused and is absent from the application
runtime. No upgradeable contracts are used.

`forge build` passes with lint warnings in upstream dependencies. Their relevant
interpretations are:

* The arbitrary-`from` warning on `_debit` refers to an internal function; the
  concrete public send path supplies `msg.sender`.
* Division before multiplication deliberately removes dust. The cast to `uint64`
  follows an explicit overflow check. Both boundaries are tested.
* The message inspector is specified to revert on rejection; its boolean return
  is deliberately unused. Setting inspector/precrime to zero disables those optional
  facilities, so zero-address checks would change upstream behavior.
* Events follow external token/endpoint calls in upstream code. Consumers should
  reconcile messages by GUID and delivery state rather than rely solely on log order.
* Payable receive/simulation entrypoints explain native-currency warnings. Sends
  forward their fee, simulations revert, and native value deliberately supplied to
  an authenticated receive would be stranded. Operational options should specify
  zero receive value; there is no rescue function by requirement.
* The options validation loop intentionally rejects invalid entries atomically.
  Simulation loops are caller-sized and always revert. Codec casts implement the
  upstream wire representation; EVM recipients and peers must be left-zero-padded.

These findings do not require modifying upstream packet or custody behavior.
