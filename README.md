# connect.hx

A [ConnectRPC](https://connectrpc.com) client for the [Helix](https://helix-editor.com)
editor: write requests in a buffer, execute them against a running service, read
the response in a split.

> **Status: milestone 1.** Requests execute: put the cursor in a request block
> and run `:connect-exec`. Verified against a live service. No schema awareness
> yet, and execution blocks the editor thread while the request is in flight.

Requires Helix with the experimental Steel plugin system
([mattwparas/helix, `steel-event-system`](https://github.com/mattwparas/helix/tree/steel-event-system)).

## Dependencies

- `curl` -- the default executor, and the only hard requirement.
- `buf` -- optional. Enables the schema-aware executor: request validation,
  decoded streaming responses, readable error details.

## Development

```sh
nix develop          # steel, steel-language-server, buf, curl, jq, protobuf, grpcurl
steel tests/request-tests.scm
nix build            # also runs the tests
nix fmt
```

`buf` is resolved from PATH at call time, so the right place for it is the
project's own dev shell -- see [DESIGN.md](./DESIGN.md) §7. Note that PATH comes
from wherever helix was launched, not from the file you open.

The dev shell points `STEEL_HOME` at `.dev/steel-home`, with this checkout
symlinked in as the `connect.hx` cog alongside its dependencies, so `require`
resolves at the prompt exactly as it does inside Helix.

## Using it from a nix config

The package carries the `cogName` and `pluginDependencies` passthru attributes
that `helix-plugins-nix` consumers expect, so it drops into an existing plugin
list:

```nix
# flake.nix
inputs.connect-hx.url = "github:apetrovic/connect.hx";

# wherever the plugin list lives
selectPlugins = p: [
  p.oil
  inputs.connect-hx.packages.${system}.default
];
```

Then require it from `init.scm` at top level -- **not** from inside another
module, or the commands will not be registered:

```scheme
(require "connect.hx/connect-client.scm")
```

Optionally bind the commands under `space c`:

```scheme
(connect-install-keybindings!)
```

Binding from steel rather than from `config.toml` is what gets you hints in the
space-menu popup: that path attaches each command's `@doc` string to the keymap.
A keymap written in the editor config cannot supply that text -- helix skips
`KeyTrieNode`'s label when deserialising, so a config-defined submenu renders
with a blank description.

Verify with `:connect-doctor`, which reports which executors are on PATH.

When consuming it as a local `path:` input during development, note that nix
pins the input by narHash: editing this repo does **not** affect a rebuild of
the consumer until `nix flake update connect-hx` is run there. A rebuild that
produces a byte-identical store path is the symptom.

## Commands

| Command | Status |
| --- | --- |
| `:connect-doctor` | reports which executors are on PATH |
| `:connect-exec` | execute the request under the cursor into `*connect*` |
| `:connect-set-timeout [seconds]` | set or show the request timeout (default 30s) |
| `:connect-clear` | empty the `*connect*` log and reset entry numbering |

Responses are appended and numbered, so successive calls can be compared; use
`:connect-clear` when the log gets long.

## Licence

MIT. See [LICENSE](./LICENSE).

The `.http` syntax support builds on [http2curl](https://github.com/waddie/http2curl.scm)
and process execution on [run-command](https://github.com/waddie/run-command.scm),
both MIT, both by Tom Waddington. The design owes a lot to
[http.hx](https://github.com/waddie/http.hx), which is AGPL-3.0-or-later; no
code from it is used here.
