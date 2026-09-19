# connect.hx

A [ConnectRPC](https://connectrpc.com) client for the [Helix](https://helix-editor.com)
editor: write requests in a buffer, execute them against a running service, read
the response in a split.

> **Status: working, and in use against a real service.** Requests execute from
> the buffer, `buf curl` validates against the schema, methods are discoverable
> in a picker, and request bodies are scaffolded from descriptors. Known limits
> are in [DESIGN.md](./DESIGN.md) §11.

Requires Helix with the experimental Steel plugin system
([mattwparas/helix, `steel-event-system`](https://github.com/mattwparas/helix/tree/steel-event-system)).

## Writing requests

A superset of the vscode-restclient `.http` syntax -- `###` separates requests,
`@name = value` declares a variable, `{{name}}` interpolates one. Put the cursor
in a request and run `:connect-exec`.

```http
@base = https://demo.connectrpc.com

### a Connect call, shorthand
>> connectrpc.eliza.v1.ElizaService/Say
{"sentence": "hello"}

### the same call written out
POST {{base}}/connectrpc.eliza.v1.ElizaService/Say
Content-Type: application/json
Connect-Protocol-Version: 1

{"sentence": "hello"}

### plain HTTP works too
GET {{base}}/healthz
```

`>>` is a Connect call against `@base`: the POST, the URL and the Connect
headers are implied. An absolute URL after `>>` skips `@base`. Headers may still
be written above the body, with or without a blank line between.

## Dependencies

- `curl` -- the default executor, and the only hard requirement.
- `buf` -- optional. Enables the schema-aware executor: request validation,
  decoded streaming responses, readable error details.
- `grpcurl` -- optional. Scaffolds a request body from the schema when you pick
  a method; without it you get `{}`. Needs gRPC reflection on the server.

`:connect-doctor` reports which are present.

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
inputs.connect-hx.url = "github:apetrovic6/connect.hx";

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

Optionally bind the commands under `space H`:

```scheme
(connect-install-keybindings!)
```

`space H c` executes under the cursor, `H s` the selection, `H b` the whole
buffer, `H m` picks a method to insert, `H x` clears. The bindings are scoped to `.connect`
and `.http` files -- helix selects a keymap by the focused file's extension -- so
`space H` stays free everywhere else. Each extension map inherits a copy of the
global keymap, which keeps the rest of your bindings working inside those files.

The two entries are labelled once the submenu is open, but the `H` row in the
parent space menu is blank: a submenu's description is its `KeyTrieNode` name,
which is private and `#[serde(skip)]`, and the steel keymap API has no setter
for it. Only helix's own `keymap!` macro names a node, which is why `space w`
reads "Window" and yours cannot.

Binding from steel rather than `config.toml` is also what gets you hints in the
keymap popup: that path attaches each command's `@doc` string. A steel command
bound from the editor config shows "Undocumented plugin command" instead.

Verify with `:connect-doctor`, which reports which executors are on PATH.

When consuming it as a local `path:` input during development, note that nix
pins the input by narHash: editing this repo does **not** affect a rebuild of
the consumer until `nix flake update connect-hx` is run there. A rebuild that
produces a byte-identical store path is the symptom.

## Executors

A `>>` request runs through `buf curl` when buf is on PATH, and through `curl`
otherwise. Longhand requests always use curl -- writing the headers by hand
means raw HTTP is what you wanted.

buf is worth having: it validates the body against the schema and rejects
unknown fields *before sending* (curl gets an HTTP 200 and the field silently
dropped), decodes streaming responses (curl shows the raw envelope framing), and
renders error details.

```http
### force this one onto curl -- e.g. a server with no reflection
# @executor curl
>> pkg.Service/Method
{}
```

`@schema = ./proto` is passed to `buf curl --schema` for servers that do not
serve reflection. `:connect-doctor` reports which executors are available.

## Commands

| Command | Status |
| --- | --- |
| `:connect-doctor` | reports which executors are on PATH |
| `:connect-exec` | execute the request under the cursor into `*connect*` |
| `:connect-exec-selection` | execute every request the selection touches |
| `:connect-exec-buffer` | execute every request in the buffer, top to bottom |
| `:connect-set-timeout [seconds]` | set or show the request timeout (default 30s) |
| `:connect-methods` | pick a method `@base` serves; inserts a scaffolded request |
| `:connect-clear` | empty the `*connect*` log and reset entry numbering |

Responses accumulate and are numbered in call order, so successive calls can be
compared; use `:connect-clear` when the log gets long.

## Licence

MIT. See [LICENSE](./LICENSE).

Process execution builds on [run-command](https://github.com/waddie/run-command.scm),
MIT, by Tom Waddington. The design owes a lot to
[http.hx](https://github.com/waddie/http.hx), which is AGPL-3.0-or-later; no
code from it is used here.
