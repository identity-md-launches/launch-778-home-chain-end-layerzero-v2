# Vendored source provenance

All dependencies are checked-in ordinary source files. No install command is
needed at verification time. NPM archives were downloaded directly from the
registry and verified against their SHA-512 integrity values. Exact URLs,
versions, archive hashes, and original Solidity file SHA-256 hashes are recorded
in `DEPENDENCIES.json`.

| Package | Version | Location |
| --- | --- | --- |
| `@layerzerolabs/oft-evm` | `4.0.1` | `src/vendor/@layerzerolabs/oft-evm` |
| `@layerzerolabs/oapp-evm` | `0.4.1` | `src/vendor/@layerzerolabs/oapp-evm` |
| `@layerzerolabs/lz-evm-protocol-v2` | `3.0.168` | `src/vendor/@layerzerolabs/lz-evm-protocol-v2` |
| `@openzeppelin/contracts` | `5.0.2` | `src/vendor/@openzeppelin/contracts` |
| `forge-std` | `v1.9.7` | `test/vendor/forge-std` |

Only the application/test import closure of LayerZero and OpenZeppelin is included.
The upstream `OFT.sol` and ERC-20 implementation support the interoperability test;
the application itself derives from `OFTAdapter`. All LayerZero code is under `src/`.
Forge standard library sources and their MIT/Apache licenses are vendored for
tests, including compatibility with the protected test's `forge-std/Test.sol` import.

Exactly two vendored source files differ from their upstream originals:

* `oft-evm/contracts/OFTAdapter.sol` imports `IERC20` directly, accepts an explicit
  `uint8 _localDecimals` constructor argument, and passes it to `OFTCore`. It does
  not call `IERC20Metadata(_token).decimals()`. `ZTOAdapter` supplies its constant 18.
* `oapp-evm/contracts/oapp/OAppCore.sol` calls `endpoint.setDelegate(_delegate)` in
  its constructor only when `_endpoint.code.length != 0`. It still rejects a zero
  constructor delegate and propagates errors from an endpoint with code. The
  inherited owner-only public `setDelegate` is unchanged.

Peer restriction to Robinhood, the fixed deployment addresses, and explicit owner
initialization live in `ZTOAdapter.sol`, not in the vendored sources. Packet codecs,
the `uint64` overflow check, receive authentication, dust/slippage behavior,
SafeERC20 custody transfers, messaging payment, and simulation behavior are unchanged.

Upstream Solidity SPDX notices are retained. Most included files are MIT licensed.
The protocol's `PacketV1Codec.sol` and `AddressCast.sol` use `LZBL-1.2`, whose full
license is included beside the protocol sources. LayerZero MIT and LZBL texts were
retrieved from the LayerZero-v2 repository at the immutable revision recorded in
`DEPENDENCIES.json`; the NPM archives omit those license texts. OpenZeppelin's MIT
license was retrieved from its `v5.0.2` tag. Forge-std licenses came from its archive.

Reference implementations and interface documentation are available in the
[LayerZero devtools repository](https://github.com/LayerZero-Labs/devtools) and
[LayerZero V2 repository](https://github.com/LayerZero-Labs/LayerZero-v2).
