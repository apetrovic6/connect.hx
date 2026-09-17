# connect.hx -- design

A ConnectRPC client for the Helix editor: write requests in a buffer, execute
them against a running service, read the response in a split. The `.http`-file
workflow from VS Code's REST Client and the JetBrains HTTP Client, specialised
for Connect.

Status: **milestone 1**. Requests execute: the block under the cursor is parsed,
sent with curl, and rendered into a `*connect*` split. Verified against the live
demo service for success, HTTP error, Connect error envelope, and no-request
cases. No schema awareness yet, and execution blocks the editor thread.

Everything below the "Architecture" heading beyond milestone 1 is a plan, not a
description of working code.


Last updated 2026-09-16.

---

## 1. Goals

- Execute a Connect unary call from a buffer and see the response, without
  leaving the editor.
- Keep plain HTTP working in the same file, because real services are never
  purely RPC -- there is always a `/healthz` or an OAuth token endpoint.
- Use the protobuf schema where it pays for itself, and degrade cleanly to a
  dumb HTTP client where it does not.

### Non-goals

- Being an LSP. Field-level completion is explicitly out of scope for the
  plugin; see §5.
- Supporting the gRPC or gRPC-Web protocols directly. `buf curl` speaks both
  if it ever matters, but the request format here is modelled on Connect.
- Replacing `buf curl` or `grpcurl` as a CLI. This is an editor front end.

---

## 2. Why ConnectRPC is the easy target

A Connect **unary** call over JSON is an ordinary HTTP POST. This is the whole
protocol as far as this plugin is concerned:

```
POST /<fully.qualified.Service>/<Method> HTTP/1.1
Content-Type: application/json
Connect-Protocol-Version: 1

<the request message, as bare JSON>
```

The response is the bare message as JSON. There is no framing, no HTTP/2
requirement and no protobuf on the wire. Verified against the public demo
service on 2026-09-16:

```console
$ curl -s -X POST https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say \
    -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
    -d '{"sentence":"hello"}'
{"sentence":"Hello there...how are you today?"}
```

That single fact is what makes the project small: `curl` is a sufficient
transport for the common case, and the interesting work is ergonomics and
schema rather than protocol implementation.

### Errors

A Connect error is a non-2xx response whose body is:

```json
{"code": "not_found", "message": "...", "details": [...]}
```

Two consequences, both load-bearing:

- **The executor must not pass `curl --fail`.** With `--fail`, curl exits
  non-zero and discards the body -- exactly the body that explains the
  failure. `tests/request-tests.scm` asserts the flag is absent so nobody adds
  it later as an "improvement".
- **The renderer needs the HTTP status**, hence `curl -i`. Without the status
  line, an error body is indistinguishable from a successful response that
  happens to have a `code` field.

`details[]` entries are `Any`-packed protobuf messages -- a type URL plus
base64. They are opaque without the schema. See §5.

### Streaming

Non-unary methods use the Connect streaming framing: each message is prefixed
by 5 bytes (1 flag byte, then a 4-byte big-endian length), with content type
`application/connect+json`. `curl` will dump this raw and it is unreadable.
`buf curl` decodes it. This is the strongest single argument for the
schema-aware executor, and the reason the executor is pluggable from day one.

---

## 3. Platform capabilities

Verified against steel 0.8.2 and the `mattwparas/helix` `steel-event-system`
fork on 2026-09-16, by probing the interpreter and reading the generated cogs
in `$STEEL_HOME/cogs/helix`. Recorded here because these were the open
feasibility questions, and the answers determine the architecture.

### Steel can do the work

| Need | Primitive | Notes |
| --- | --- | --- |
| Spawn a process | `command`, `spawn-process` | builtins, no `require`; `spawn-process` returns `(Ok ChildProcess)` |
| Capture output | `set-piped-stdout!`, `wait->stdout` | without the pipe call, output goes to the terminal and the capture is empty |
| Avoid pipe deadlock | `spawn-native-thread`, `thread-join!` | drain stdout and stderr concurrently |
| JSON | `string->jsexpr`, `value->jsexpr-string` | builtin |
| Timers | `enqueue-thread-local-callback-with-delay` | in `helix/misc.scm` |
| Async | `await-callback`, `helix-await-callback` | in `helix/misc.scm` |
| Fuzzy matching | `fuzzy-match` | in `helix/misc.scm`; enough to build a picker |
| Custom UI | `new-component!`, `push-component!` | in `helix/components.scm` |
| Inline annotation | `add-inlay-hint`, `remove-inlay-hint` | in `helix/misc.scm` |
| Talk to an LSP | `send-lsp-command`, `send-lsp-notification` | in `helix/misc.scm` |

`run-command` (MIT, a dependency) already wraps the first three correctly,
including a `/bin/sh` watchdog for timeouts -- necessary because Steel's `kill`
takes the child, SIGKILLs it and drops the handle without reaping, leaving a
zombie with no exposed PID. Do not reimplement this.

### Two constraints that shape the design

**Numbers lose their type through JSON.** `string->jsexpr` parses `[1,2]` to
`(1.0 2.0)`. protojson encodes `int64`/`uint64` as strings so those survive,
but an `int32` round-tripped through parse-then-serialise becomes `1.0`.
Therefore: **response bodies are handled as text** for display, and parsed only
when a specific field must be extracted (request chaining). Never re-serialise
a whole response and present it as what the server said.

**Helix has no completion-provider hook.** `helix/static.scm` exposes
`completion` only as "invoke the popup", and that popup is fed by LSP. A Steel
plugin cannot contribute completion items. This is the single most important
constraint on the project and §5 is built around it.

---

## 4. Architecture

Three layers, deliberately split so the testable part has no editor
dependency:

```
  .connect buffer
        |
        v
  [ parser ]          connect-request.scm  -- pure, unit-tested
        |             a request block -> {url, headers, body, method-ref}
        v
  [ executor ]        curl  |  buf curl    -- pluggable, selected per request
        |             argv construction is pure; spawning is not
        v
  [ renderer ]        connect-client.scm   -- scratch buffer, status line
```

- `connect-request.scm` -- pure functions over strings and hashes. No helix
  require, so `steel tests/*.scm` runs it in the nix sandbox where no editor
  exists. The nix build gates on these tests (`doSteelCheck = true`).
- `connect-client.scm` -- everything that touches the editor or spawns a
  process. Cannot run outside helix.

The split is not ceremony: it is the only way to have a test suite at all,
since nothing that requires `helix/*` can be loaded by a bare `steel`.

### Command registration

Helix builds its typed command list from the globals present after startup.
A name only becomes `:connect-…` if it is `provide`d **and** the module is
required from `init.scm` at top level. Requiring it from inside another module
makes the bindings module-local and the commands silently vanish. The oil
wrapper in the magos config documents this failure mode at length.

---

## 5. Schema awareness

The schema is a **FileDescriptorSet** -- the compiled form of the `.proto`
files, carrying every service, method, message, field (name, number, type,
cardinality, oneof, enum values) and doc comment. Sources, in order of
convenience:

1. **Server reflection.** `buf curl` uses it by default when `--schema` is
   omitted. Works against any Connect server mounting `grpcreflect`.
2. `buf build -o desc.binpb` (or `--format=json`, which `string->jsexpr` can
   read directly -- so descriptors are reachable from Steel with no native
   code).
3. The BSR, for a module that is published.

### What it buys, ranked by value per unit of effort

1. **Request scaffolding.** Pick a method, get a skeleton body with every
   field at the right nesting and the right type. Turns "what does
   `CreateUser` take?" from a context switch into a keystroke. Needs no hook
   Helix lacks -- it is text insertion. **Build this first.**
2. **Method discovery.** A picker over `pkg.Service/Method` that inserts the
   skeleton. `buf curl --list-methods <url>` supplies the data with no
   descriptor parsing at all; `fuzzy-match` plus `new-component!` supplies the
   UI. Verified working against the demo service.
3. **Absent vs. zero in responses.** protojson **omits default-valued
   fields** -- a `false`, a `0`, an empty string simply do not appear. Raw JSON
   cannot distinguish "unset" from "set to zero"; with the descriptor the
   renderer can show the full message shape. A genuine daily papercut that no
   plain `.http` client can fix.
4. **Pre-send validation.** This matters more than it first appears. A typo'd
   field is **silently ignored** by the server:

   ```console
   $ curl ... -d '{"nope":1}'        # -> HTTP 200, field discarded
   $ buf curl ... -d '{"sentance":"hi"}'
   Failure: json unmarshal: proto: (line 1:2): unknown field "sentance"
   ```

   Raw curl gives a green result for a request that did not do what was
   written. `buf curl` catches it client-side, for free.
5. **Error `details` decoding.** Turns the `Any`-packed blobs into readable
   messages. Worth it only if the services actually use rich errors.
6. **Hover docs.** Proto comments ride along in the descriptor set. Needs a
   custom component or an LSP.
7. **Field completion while typing.** The demo-friendly feature and the
   expensive one, blocked by the missing completion hook (§3). Options: build
   a bespoke overlay (real work, will not feel native, fights Helix's own
   completion), or write an actual `.connect` LSP server (the correct answer,
   gets completion + diagnostics + hover at once -- but it is a separate
   binary and a separate project). **Deferred indefinitely**; item 1 covers
   most of the need.

Items 1-4 are the plan. Items 5-7 are explicitly parked.

---

## 6. File format

A superset of the vscode-restclient `.http` syntax, so plain HTTP and Connect
calls coexist in one buffer and the existing conventions carry over. The parser
is our own (connect-request.scm): waddie's http2curl reads the same syntax but
only exposes a whole-input string->curl-string conversion, and the Connect layer
needs the pieces individually.

```http
@base = http://localhost:8080
@user = {{base}}/acme.user.v1.UserService

### plain HTTP still works
GET {{base}}/healthz

### a Connect call, written longhand
POST {{user}}/GetUser
Content-Type: application/json
Connect-Protocol-Version: 1

{"id": "123"}

### the same call, shorthand -- headers and method are implied
>> acme.user.v1.UserService/GetUser
{"id": "123"}
```

The `>>` shorthand is the only new syntax, and it is implemented. It expands to
the longhand form above against the current `@base`: the method, the URL
assembly and the Connect headers are all implied, since for a unary call they
never vary. An absolute URL after `>>` skips `@base`, for a one-off call to
another host.

Its header/body split differs from the longhand form, and has to. Longhand ends
its header block at the first blank line; requiring that blank line is most of
the ceremony the shorthand exists to remove. So after `>>` the headers are taken
while the lines still look like headers, and the body starts at the first line
that does not. "Looks like a header" is therefore strict -- a letter, then
letters, digits or dashes, then a colon -- because `{"sentence": "hello"}` also
contains a colon and a looser rule swallows the body as a header named
`{"sentence"`. An explicit blank line still works if you prefer it.

A malformed `>>` line is reported as an error naming the problem (no `@base`,
not a method reference, nothing after the marker), distinct from the `#false`
that means "the cursor is not in a request at all" -- a comment block is the
latter and is not worth complaining about.

A parsed request carries a `connect?` flag recording that it came from `>>`,
which is what milestone 3 needs to route those to `buf curl` while leaving plain
HTTP on curl. Whether that flag should be the whole of the decision, or a
`# @executor` directive should override it, is still open.

### Selection model

http.hx requires the whole request to be **selected** before executing, which
suits Helix's selection-action model but is painful without a textobject.
connect.hx should support both: execute the primary selection if there is one,
otherwise expand from the cursor to the enclosing `###` block. The latter is
what every other editor does and there is no reason to be austere about it.

---

## 7. Executors

Two backends behind one interface, chosen per request.

| | `curl` | `buf curl` |
| --- | --- | --- |
| Dependency | curl only | buf on PATH |
| Schema needed | no | reflection or `--schema` |
| Unary JSON | yes | yes |
| Streaming | unreadable framing | decoded |
| Unknown-field typos | silently ignored | rejected client-side |
| Error `details` | opaque | decodable |
| Arbitrary HTTP | yes | no |

`curl` is the default and the only hard dependency: the plugin must be useful
on a machine without buf, and plain HTTP requests in the same file need it
anyway. `buf curl` is selected when available and when the request is a
Connect method call.

`:connect-doctor` (implemented) reports which are present.

### Where buf comes from

**The project's dev shell, not the editor and not this package.** Decided
2026-09-16; the reasoning matters because the obvious alternatives are both
worse.

`buf` is project state. The schema it reads lives with the project -- `buf.yaml`,
`buf.lock`, the module dependencies, the proto tree -- and the buf version
should be whatever that project pins. An editor-global buf is a second,
unrelated pin that silently shadows the project's.

So the plugin resolves it **from PATH at call time** (`command -v`, then
`/bin/sh -c`, which inherits the editor's environment) and never records a
store path. Verified by putting a fake `buf` earlier on PATH and watching
`:connect-doctor` report it:

```
connect.hx: curl 8.21.0 | buf 1.99.0-from-project-devshell
```

Two consequences worth keeping in mind:

- **This package must not depend on buf.** Beyond the version-pinning problem,
  `buildHelixPlugin` is `dontBuild`/`dontConfigure` with an install phase that
  globs `**/*.scm` -- there is no wrapper step in which to inject a PATH entry,
  so the packaging format cannot express a runtime dependency even if it were
  wanted. (`buildHelixPluginWithNative` is for `#%require-dylib` libraries,
  which is a different mechanism.)
- **PATH comes from where helix was launched**, not from the file that is open.
  Launched from inside the project's dev shell, the plugin sees that buf;
  launched from a desktop entry, it does not, even with the same project open.
  A helix wrapper that appends buf to PATH (nix-wrapper-modules uses
  `wrapperSuffixEnv`, so a dev shell's buf still wins) is a reasonable floor if
  that turns out to be annoying in practice. Not done, deliberately: the
  degraded mode is honest and schema features are project-scoped anyway.

---

## 8. Rendering

A persistent `*connect*` scratch buffer in a vertical split, markdown, following
the shape http.hx established -- it works and there is no reason to be novel.
Focus returns to the request buffer after rendering: the response is to be read,
not edited.

Each response is **appended**, so a sequence of calls can be compared against
each other. Entries are numbered and separated by a rule; `:connect-clear`
empties the log and resets the counter.

The append is done by rewriting the buffer with old + new rather than seeking
to the end and inserting there, which looks wasteful and is not. `select_all`
followed by `delete_selection` is the only sequence found that survives the
first write into a newly created buffer. Every seek-based variant tried --
`goto_file_end`, `collapse_selection`, and the typed `:goto`, each with and
without `enqueue-thread-local-callback` -- builds a transaction whose positions
still belong to the *request* buffer and applies it to the 1-character response
document, which **panics helix** rather than erroring:

```
thread 'main' panicked at helix-core/src/transaction.rs:509:
Positions [(586, AfterSticky), (587, BeforeSticky)] are out of range for
changeset len 1!
```

`editor-set-focus!` does not reconcile the incoming view's selection with the
document; `select_all` does, by rewriting the selection against the document
actually being edited. That is why http.hx opens with the same two calls, and
it is worth knowing before "optimising" this into an insert-at-end.

Deferring through `enqueue-thread-local-callback` does NOT substitute for it --
tested, still panics. Note the typed `:goto` panics here even though the static
commands around it are fine, so view positioning after a write is limited to
`helix/static.scm` commands.

Known rough edge: the view lands at the bottom of the buffer, so a long
response scrolls its own header off screen. Putting the cursor at the top of
the new entry is what `:goto` was for, and it is currently unavailable.
The rendered shape, as implemented:

```markdown
# 1 · POST https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say

`HTTP/2 200`  ·  309ms

```json
{"sentence":"Hello there...how are you today?"}
```

## response headers

```
HTTP/2 200
content-type: application/json
...
```

---
```

The body is fenced as `json` when the response Content-Type says so, which is
what gives it highlighting inside the markdown buffer. Response headers get a
plain heading, NOT an HTML `<details>` block: helix renders a markdown buffer as
text, so `<details>` collapses nothing and only adds literal tag noise to the
output.

Connect-specific: on a non-2xx, `code` and `message` are lifted out of the error
envelope into the status line (`` `HTTP/2 400` -- **invalid_argument: ...** ``),
since that is the entire information content of a failed call. The body is still
rendered verbatim underneath. Parsing there is best-effort and guarded: a non-2xx
whose body is not a Connect envelope (a router's plain-text 404, say) simply
renders without a summary.

The parsed value is used ONLY for that summary. steel's JSON reader turns
integers into floats, so a re-serialised body would misreport what the server
actually sent -- the body shown is always the bytes curl received.

**Blocking.** `run-command` drains concurrently but still `thread-join!`s, so
the call blocks the editor thread until the process exits. Against localhost
this is imperceptible; against a slow endpoint it freezes the editor. The
timeout (default 30s, as http.hx uses) bounds the damage but does not fix it.
A non-blocking path -- spawn, return, poll via
`enqueue-thread-local-callback-with-delay`, repopulate the buffer when the
process exits -- is the known fix, and the primitives exist. Deferred until
the blocking version proves annoying in practice.

---

## 9. Milestones

- **0. Plumbing.** *(done)* Flake, cog contract, dependency closure, pure
  request construction, tests gating the build, `:connect-doctor` proving the
  cog loads and can spawn a process from the editor thread.
- **1. Execute a request.** *(done)* Parse the enclosing block, build curl argv,
  run it, render into `*connect*`. Longhand syntax only. Cursor-based, no
  selection required. `:connect-exec`, `:connect-set-timeout`.
- **2. Shorthand and ergonomics.** *(done)* The `>>` form, execute-selection and
  execute-buffer, and keybindings under `space H` scoped to .http/.connect.
  (`@base` and cursor-based block selection landed in milestone 1.)
- **3. `buf curl` executor.** Selected when buf is present; unlocks streaming,
  validation and decoded errors at once.
- **4. Method discovery.** `--list-methods` into a picker.
- **5. Request scaffolding.** Descriptor set to skeleton body. The biggest
  single ergonomic win, and the point at which this stops being "an http client
  that knows a URL shape".

Milestones 1 and 2 need no protobuf tooling at all. That ordering is
deliberate: it produces something usable before any schema work begins, and
the schema work is then informed by actual use rather than speculation.

---

## 10. Open questions

- Does `>>` select the executor, or is that orthogonal? Leaning orthogonal: a
  `# @executor buf` directive, defaulting to buf-when-available.
- Where do descriptor sets get cached, and what invalidates them? A
  `.connect-cache/` in the workspace is the obvious answer; reflection makes it
  optional.
- Is a `.connect` file type worth registering, or should this just be `.http`?
  Registering a new type means another grammar problem; reusing `.http` means
  http.hx and connect.hx would both claim the same buffers if both are
  installed.
- ~~Helix ships no `http` tree-sitter grammar.~~ Done, in the magos config:
  `rest-nvim/tree-sitter-http` (packaged in nixpkgs as
  `tree-sitter-grammars.tree-sitter-http`) installed into an additive
  `HELIX_RUNTIME` dir holding just `grammars/http.so` and `queries/http/`, with
  a `[[language]]` entry claiming `.http` and `.connect`. Two things to know if
  this is ever repackaged: helix searches every runtime dir and takes the first
  hit, so an additive dir does not shadow the stock one; and the shipped
  queries are neovim's, so the nvim-only `#offset!` predicate has to be
  stripped or helix rejects the whole file ("unknown predicate", and with it
  every injection).

---

## Appendix: verification log

Everything asserted above as "verified" was checked on 2026-09-16 against
steel 0.8.2, buf 1.72.0 and `https://demo.connectrpc.com`:

- Connect unary over plain curl returns the bare JSON message. ✓
- An unknown JSON field is accepted with HTTP 200 by the server and rejected
  client-side by `buf curl`. ✓
- `buf curl --list-methods <url>` lists methods via reflection with no local
  `.proto` files. ✓
- `buf curl` decodes a server-streaming response (`ElizaService/Introduce`)
  into sequential JSON messages. ✓
- `--schema` takes a directory or module, **not** a URL; omitting it is what
  selects reflection. ✓
- Steel: `spawn-process` -> `(Ok ChildProcess)`, `set-piped-stdout!` required
  for capture, `string->jsexpr` yields floats for integers. ✓
- Helix cogs expose no completion-provider API. ✓
