# ZTO Ethereum OFT adapter

`src/ZTOAdapter.sol:ZTOAdapter` locks the existing Ethereum Zero To One ERC-20 when
sending through LayerZero V2 and releases custody on authenticated return messages.
It uses the standard OFT wire format, six shared decimals, and the upstream
OApp/OFT quote, send, receive, options, compose, and simulation interfaces.

This project deploys one application. It does not deploy a new Ethereum token or
the Robinhood token. All Solidity dependencies are ordinary files in `src/vendor/`
and `test/vendor/`; no dependency installation or network is needed to build once
Foundry and Solidity 0.8.26 are installed. Nothing belongs in `lib/`.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to **0.8.26**, optimizer runs to **200**, EVM target to
**Paris**, and `bytecode_hash` to **none**. FFI and filesystem cheatcode permissions
are not enabled. Tests use no RPC, environment variables, wallet keys, forks,
submodules, or downloaded artifacts. Vendor source formatting is preserved.

The tests cover both constructor branches, a factory CREATE2 deployment, explicit
ownership, runtime size and forbidden opcodes, authorization, locking/releasing,
dust, slippage, uint64 limits, fees/refunds, token and endpoint failures, receive
retry, message authentication, compose, options, simulation rollback, and callback
attempts. A 256-run fuzz test bridges through the upstream mint/burn OFT and back,
checking conservation of ZTO and preservation of dust.

The endpoint fixture models verified-message consumption and retry; it is **not**
an implementation or verification of LayerZero's endpoint, DVNs, or executor.
The production endpoint is responsible for verification and replay prevention.
See [the security review notes](docs/SECURITY.md) for test limits and lint findings.

## Deployment parameters

| Parameter | Fixed value |
| --- | --- |
| Application | `ZTOAdapter` |
| Constructor arguments | None (`[]`) |
| Constructor value | Zero ETH |
| Chain | Ethereum mainnet, chain ID `1` |
| Local endpoint ID | `30101` |
| Underlying ZTO | `0xd782bdea4ef02a0bd391eb9089470c8080f0a68e` |
| Local token decimals | `18` (constant; never read during construction) |
| LayerZero EndpointV2 | `0x1a44076050125825900e736c501f859c50fE728c` |
| Initial owner and delegate | `0xcecc29b037f5064fcdf45a5c318f132ef76aa551` |
| Only permitted remote endpoint ID | `30416` (Robinhood) |
| Shared decimals | `6` |
| Local units per shared unit | `10^12` |

The constructor assigns the explicit owner even when called by a factory. It
registers that owner with `endpoint.setDelegate` **only if the endpoint has code**.
An existing endpoint's registration failure propagates; it is not silently ignored.
When neither dependency exists, construction succeeds and the owner can register
the delegate later with `setDelegate(address)`, after endpoint code exists.
This exception supports the fresh-EVM deployment verifier and does not establish
a usable bridge without the actual dependencies. The public `setDelegate` does
not silently succeed when there is no endpoint code.

The supplied addresses and the stated 18 decimals are assignment inputs. This task
has not independently verified live ZTO code, live endpoint configuration, or the
Robinhood deployment. Deploy only on the specified chain after those checks; the
constructor intentionally has no chain or dependency existence gate. The remote
OFT address has not been supplied and is not invented here. No peer is initially
set, so sends and authenticated receives are disabled until pairing is configured.

The launch handoff should name `ZTOAdapter` with `constructorArgs: []`. Its initial
owner is compiled into the application, not supplied as `$owner`. No transaction
has been broadcast by this project.

## Pairing and operator responsibilities

1. Verify deployed bytecode and the fixed token and endpoint addresses. Confirm
   ZTO transfers are lossless, balances do not rebase, and decimals are 18. Confirm
   `owner()`, `token()`, `endpoint()`, `sharedDecimals()`, and the endpoint's delegate
   mapping after deployment. A normal Ethereum deployment registers the delegate
   in its constructor.
2. Deploy or identify the single Robinhood OFT. It must use compatible OFT version
   1 encoding, six shared decimals, burn on outbound transfers, and mint only on
   authenticated inbound messages. Do not seed an unbacked supply or install a
   second custody adapter for the same mesh. Test fixtures are not deployment targets.
3. As this adapter's owner, call
   `setPeer(30416, bytes32(uint256(uint160(robinhoodOFT))))`. As the remote owner,
   set the reverse peer for endpoint `30101` to the similarly left-padded address
   of this adapter. Peer values are addresses, not endpoint addresses. Verify both
   mappings. Setting a peer for any other endpoint reverts.
4. Through the respective LayerZero delegates, select and verify send/receive
   libraries, DVNs, confirmation counts, executor configuration, and both directional
   pathways. These are deployment choices outside this assignment; no security
   stack is chosen by the constructor. Do not assume endpoint defaults meet the
   intended security policy. Use the official
   [OApp configuration guide](https://docs.layerzero.network/v2/developers/evm/configuration).
5. Set suitable enforced type-3 options using `setEnforcedOptions`, separately for
   `SEND = 1` and `SEND_AND_CALL = 2`, on both applications. Measure destination
   receive and compose gas before choosing limits. Inbound execution value should
   be zero: the adapter does not forward native value received by `lzReceive`.
   Compose requires its own executor option and destination composer.
6. Perform small sends in both directions and reconcile source receipts, destination
   delivery, remote supply, and adapter custody. Monitor pending packets and compose
   jobs. A failed source transaction rolls back locking. A failed destination receive
   preserves the verified packet for retry through the endpoint; it does not refund
   the source sender. Restore the cause of failure and retry with sufficient gas.
   A later compose failure is a separate retry from the already completed transfer.

Replace peers only after reviewing outstanding packets. Removing a peer with
`setPeer(30416, bytes32(0))` blocks that pathway, including pending returns until a
compatible peer is restored. There is no independent pause switch, upgrade path,
or rescue/withdraw function. Incorrect configuration can strand funds permanently.

## Sending and accounting

Users approve this adapter to spend ZTO. Construct the standard `SendParam`:
`dstEid = 30416`, `to` is the left-zero-padded recipient, `amountLD` and
`minAmountLD` are in Ethereum token base units, `extraOptions` contains execution
options, `composeMsg` is empty for a plain transfer, and `oftCmd` should be empty
(the default upstream OFT ignores it). Validate the destination recipient before
sending; the upstream wire codec truncates bytes32 to an EVM address on receipt.

Call `quoteOFT` for dust-adjusted token amounts, then `quoteSend` for messaging fees.
`quoteOFT` uses total supply as its informational limit; it does not guarantee
pathway availability, spendable balance, allowance, or a valid uint64 packet amount.
`quoteSend` and `send` enforce the actual encoding limit. Submit `send` with the
returned fee, `msg.value == fee.nativeFee`, and an appropriate refund address.
Requote if fees change. Prefer exact token approvals.

There is **no application fee**. Endpoint, DVN, and executor messaging fees remain
payable. Native fees are forwarded to the endpoint and its excess refund goes to
the requested refund address. If paying the LayerZero-token portion, the endpoint
must have a configured LZ token and the sender must separately approve that token
to the adapter; those tokens transfer directly to the endpoint.

Amounts are rounded down to multiples of `10^12` local units. For example, sending
`1e18 + 123` locks exactly `1e18`; the sender keeps `123`. A minimum greater than
the rounded amount reverts. Amounts below one shared unit with a zero minimum can
produce a zero-value message and still incur messaging fees, following upstream
semantics. Interfaces should require at least one shared unit for useful transfers.
The largest encodable transfer is `type(uint64).max * 10^12` local units, or
`18,446,744,073,709.551615` ZTO. Larger transfers revert, rather than truncate.

Conservation assumes exactly one lossless custody adapter, a correctly secured
remote mint/burn OFT, and trustworthy messaging. After all messages settle, remote
supply should equal the corresponding custody balance, adjusted for unsolicited
donations. While packets are pending, also account for locked tokens awaiting
remote mint and burned tokens awaiting home release. The adapter never mints or
burns ZTO. Sending tokens directly to the adapter creates no message or refund
entitlement. Accidental token donations or native value cannot be rescued.

## Administrative trust

The owner can set/replace/remove the Robinhood peer, change the endpoint delegate,
set enforced options, set a message inspector, set precrime configuration, transfer
ownership, and renounce ownership. These are the upstream OApp controls. A malicious
peer can request release of custody; protecting the owner key and the remote OFT's
configuration is critical. An inspector must revert to reject a message; its boolean
return value is ignored by upstream code. An inspector or bad options can block
sending despite the absence of a dedicated pause switch.

The delegate controls LayerZero endpoint configuration, not application ownership
or `setPeer`. Changing ownership does not change the registered delegate. If
rotating control, update both and verify both. Renouncing ownership can permanently
prevent application repairs while an existing delegate retains endpoint authority.
No owner function can directly withdraw custody, but peer and messaging authority
remain part of the bridge's trust boundary.

Dependency versions, licenses, and the two local upstream changes are recorded in
[DEPENDENCIES.json](DEPENDENCIES.json) and [the vendor notes](docs/VENDORED.md).
