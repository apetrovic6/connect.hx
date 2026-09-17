;;; Pure tests for connect-request.scm. Run by the nix build (doSteelCheck)
;;; and by `steel tests/request-tests.scm` in the dev shell.
;;;
;;; Required by relative path rather than as "connect.hx/connect-request.scm"
;;; so the tests run against the working tree, not whatever version happens to
;;; be installed in STEEL_HOME.
(require "../connect-request.scm")

(define (check! label actual expected)
  (if (equal? actual expected)
      (displayln (string-append "ok   " label))
      (begin
        (displayln (string-append "FAIL " label))
        (displayln (string-append "  expected: " (to-string expected)))
        (displayln (string-append "  actual:   " (to-string actual)))
        (error! (string-append "test failed: " label)))))

;; The split is on the last slash, so a pasted full URL still yields the
;; method rather than choking on the scheme's slashes.
(check! "parse-method-ref splits on the last slash"
        (parse-method-ref "connectrpc.eliza.v1.ElizaService/Say")
        (cons "connectrpc.eliza.v1.ElizaService" "Say"))

(check! "parse-method-ref tolerates a full URL"
        (cdr (parse-method-ref "https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say"))
        "Say")

(check! "parse-method-ref returns #false without a slash"
        (parse-method-ref "NotAMethodRef")
        #false)

(check! "connect-url joins base and method"
        (connect-url "https://demo.connectrpc.com" "connectrpc.eliza.v1.ElizaService" "Say")
        "https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say")

;; A trailing slash on the base must not produce a double slash, which some
;; routers treat as a different (404ing) path.
(check! "connect-url drops a trailing slash on the base"
        (connect-url "http://localhost:8080/" "pkg.Svc" "M")
        "http://localhost:8080/pkg.Svc/M")

(check! "connect-headers carries the protocol version"
        (assoc "Connect-Protocol-Version" (connect-headers))
        (cons "Connect-Protocol-Version" "1"))

(check! "connect-headers appends caller headers after the defaults"
        (assoc "Authorization" (connect-headers (list (cons "Authorization" "Bearer t"))))
        (cons "Authorization" "Bearer t"))

;; --fail would swallow the error body, which is the whole payload of a
;; Connect error. Guard against anyone "helpfully" adding it later.
(check! "curl-argv never passes --fail"
        (member "--fail" (curl-argv "http://x/pkg.Svc/M" (connect-headers) "{}"))
        #false)

(check! "curl-argv includes response headers"
        (if (member "-i" (curl-argv "http://x/pkg.Svc/M" (connect-headers) "{}")) #true #false)
        #true)

(check! "curl-argv ends with the url"
        (last (curl-argv "http://x/pkg.Svc/M" (connect-headers) "{}"))
        "http://x/pkg.Svc/M")

(check! "curl-argv omits the body flag when there is no body"
        (member "--data-binary" (curl-argv "http://x/pkg.Svc/M" (connect-headers) ""))
        #false)

(check! "buf-curl-argv uses reflection when no schema is given"
        (member "--schema" (buf-curl-argv "http://x/pkg.Svc/M" '() "{}" #false))
        #false)

(check! "buf-curl-argv passes a schema when one is given"
        (if (member "--schema" (buf-curl-argv "http://x/pkg.Svc/M" '() "{}" "./proto"))
            #true
            #false)
        #true)

(displayln "all request tests passed")

;; ---------------------------------------------------------------------------
;; Buffer parsing
;; ---------------------------------------------------------------------------

(define sample
  (string-join
   (list "@base = https://demo.connectrpc.com"
         "@eliza = {{base}}/connectrpc.eliza.v1.ElizaService"
         ""
         "### say hello"
         "POST {{eliza}}/Say"
         "Content-Type: application/json"
         ""
         "{\"sentence\": \"hello\"}"
         ""
         "### plain http still works"
         "GET {{base}}/healthz")
   "\n"))

(define vars (resolve-variables (parse-variables sample)))

(check! "parse-variables finds both declarations"
        (length (parse-variables sample))
        2)

;; @eliza refers to @base, so resolution has to reach a fixed point rather
;; than take the values as written.
(check! "resolve-variables expands a variable that refers to another"
        (cdr (assoc "eliza" vars))
        "https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService")

(check! "expand-variables substitutes every occurrence"
        (expand-variables "{{base}}/a and {{base}}/b" vars)
        "https://demo.connectrpc.com/a and https://demo.connectrpc.com/b")

;; A cycle must terminate rather than spin on the editor thread.
(check! "resolve-variables survives a cycle"
        (list? (resolve-variables (list (cons "a" "{{b}}") (cons "b" "{{a}}"))))
        #true)

(check! "split-blocks finds the preamble and both requests"
        (length (split-blocks sample))
        3)

;; The separator introduces the block below it, so a cursor on the `###` line
;; selects that request rather than the one above.
(check! "block-at-line maps the separator line to the block it introduces"
        (block-first-line (block-at-line (split-blocks sample) 3))
        3)

(check! "block-at-line maps a body line to its own block"
        (block-first-line (block-at-line (split-blocks sample) 7))
        3)

(check! "block-at-line maps the second request"
        (block-first-line (block-at-line (split-blocks sample) 10))
        9)

(check! "char-offset->line counts newlines"
        (char-offset->line "a\nb\nc" 4)
        2)

(define req (parse-request (block-lines (block-at-line (split-blocks sample) 5)) vars))

(check! "parse-request reads the method" (request-method req) "POST")

(check! "parse-request expands the url"
        (request-url req)
        "https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say")

(check! "parse-request reads headers"
        (assoc "Content-Type" (request-headers req))
        (cons "Content-Type" "application/json"))

(check! "parse-request reads the body"
        (request-body req)
        "{\"sentence\": \"hello\"}")

;; The declaration preamble above the first `###` holds no request.
(check! "parse-request returns #false for a block with no request line"
        (parse-request (block-lines (block-at-line (split-blocks sample) 0)) vars)
        #false)

;; A body containing a blank line must survive intact -- only the FIRST blank
;; line ends the header section.
(check! "parse-request keeps blank lines inside the body"
        (request-body
         (parse-request (list "POST http://x/p.S/M" "" "{" "" "}") '()))
        "{\n\n}")

(check! "request->curl-argv supplies the protocol version header"
        (if (member "Connect-Protocol-Version: 1" (request->curl-argv req)) #true #false)
        #true)

;; A Content-Type written in the buffer must not have the default reimposed
;; underneath it, or `application/proto` silently becomes json.
(check! "request->curl-argv does not duplicate a written header"
        (length (filter (lambda (a) (starts-with? a "Content-Type"))
                        (request->curl-argv req)))
        1)

(check! "request->curl-argv honours a lowercased override"
        (if (member "content-type: application/proto"
                    (request->curl-argv
                     (parse-request (list "POST http://x/p.S/M"
                                          "content-type: application/proto"
                                          ""
                                          "{}")
                                    '())))
            #true
            #false)
        #true)

(displayln "all parsing tests passed")

;; ---------------------------------------------------------------------------
;; The `>>` shorthand
;; ---------------------------------------------------------------------------

(define short-vars (list (cons "base" "https://demo.connectrpc.com")))

(define (parse-lines lines vars) (parse-request lines vars))

(define short (parse-lines (list ">> connectrpc.eliza.v1.ElizaService/Say"
                                 "{\"sentence\": \"hello\"}")
                           short-vars))

(check! "shorthand implies POST" (request-method short) "POST")

(check! "shorthand builds the url from @base"
        (request-url short)
        "https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say")

;; No blank line after the request line -- that omission is the whole point of
;; the shorthand, so the body has to be found without one.
(check! "shorthand takes the body with no blank line"
        (request-body short)
        "{\"sentence\": \"hello\"}")

(check! "shorthand is marked as a connect call" (request-connect? short) #true)

(check! "longhand is not marked as a connect call"
        (request-connect? (parse-lines (list "GET http://x/healthz") '()))
        #false)

(check! "shorthand still supplies the connect headers"
        (if (member "Connect-Protocol-Version: 1" (request->curl-argv short)) #true #false)
        #true)

;; A header line before the body, still without a blank separator.
(define short-hdr (parse-lines (list ">> pkg.Svc/M"
                                     "Authorization: Bearer t"
                                     "{\"a\": 1}")
                               short-vars))

(check! "shorthand reads a header written above the body"
        (assoc "Authorization" (request-headers short-hdr))
        (cons "Authorization" "Bearer t"))

;; The body's own colon must not be mistaken for a header separator.
(check! "shorthand does not eat the body as a header"
        (request-body short-hdr)
        "{\"a\": 1}")

(check! "shorthand accepts an explicit blank line too"
        (request-body (parse-lines (list ">> pkg.Svc/M" "" "{\"a\": 1}") short-vars))
        "{\"a\": 1}")

;; An absolute reference ignores @base, for a one-off call to another host.
(check! "shorthand takes an absolute url as given"
        (request-url (parse-lines (list ">> https://other.example.com/pkg.Svc/M") '()))
        "https://other.example.com/pkg.Svc/M")

(check! "shorthand expands variables in the reference"
        (request-url (parse-lines (list ">> {{svc}}/Say")
                                  (list (cons "base" "http://h") (cons "svc" "pkg.Svc"))))
        "http://h/pkg.Svc/Say")

;; Errors are distinct from #false: #false means "no request here", which is
;; what a comment block is, while these mean "this meant to be a request".
(check! "shorthand without @base is an error"
        (request-error? (parse-lines (list ">> pkg.Svc/M") '()))
        #true)

(check! "the missing-@base error names the problem"
        (if (string-contains? (request-error-message (parse-lines (list ">> pkg.Svc/M") '()))
                              "@base")
            #true
            #false)
        #true)

(check! "shorthand without a slash is an error"
        (request-error? (parse-lines (list ">> NotAMethodRef") short-vars))
        #true)

(check! "bare >> is an error"
        (request-error? (parse-lines (list ">>") short-vars))
        #true)

(check! "a comment block is still #false, not an error"
        (parse-lines (list "# just a comment") '())
        #false)

(displayln "all shorthand tests passed")

;; ---------------------------------------------------------------------------
;; Block ranges
;; ---------------------------------------------------------------------------

(define sample-blocks (split-blocks sample))

(check! "a line range inside one block selects that block"
        (length (blocks-in-line-range sample-blocks 5 6))
        1)

;; Overlap, not containment: touching one line of a request runs all of it.
(check! "a partial overlap still selects the block"
        (block-first-line (car (blocks-in-line-range sample-blocks 7 7)))
        3)

(check! "a range spanning two blocks selects both"
        (length (blocks-in-line-range sample-blocks 5 10))
        2)

(check! "a range covering the buffer selects every block"
        (length (blocks-in-line-range sample-blocks 0 99))
        3)

(displayln "all block range tests passed")

;; ---------------------------------------------------------------------------
;; buf executor
;; ---------------------------------------------------------------------------

;; buf sets the protocol and content type itself, and Connect-Protocol-Version
;; sent twice is a 400.
(check! "buf-curl-argv drops the connect headers"
        (member "Connect-Protocol-Version: 1"
                (buf-curl-argv "http://x/p.S/M"
                               (list (cons "Connect-Protocol-Version" "1")
                                     (cons "Content-Type" "application/json"))
                               "{}"
                               #false))
        #false)

(check! "buf-curl-argv keeps other headers"
        (if (member "Authorization: Bearer t"
                    (buf-curl-argv "http://x/p.S/M"
                                   (list (cons "Authorization" "Bearer t"))
                                   "{}"
                                   #false))
            #true
            #false)
        #true)

(check! "buf-curl-argv speaks connect" 
        (if (member "connect" (buf-curl-argv "http://x/p.S/M" '() "{}" #false)) #true #false)
        #true)

(check! "buf-curl-argv ignores an empty schema"
        (member "--schema" (buf-curl-argv "http://x/p.S/M" '() "{}" ""))
        #false)

(check! "block-executor reads a curl directive"
        (block-executor (list "### one" "# @executor curl" ">> p.S/M"))
        "curl")

(check! "block-executor reads a buf directive"
        (block-executor (list "# @executor buf" ">> p.S/M"))
        "buf")

(check! "block-executor ignores an unknown executor"
        (block-executor (list "# @executor wget" ">> p.S/M"))
        #false)

(check! "block-executor is #false when nothing is declared"
        (block-executor (list "### one" ">> p.S/M"))
        #false)

;; The directive lives inside a comment so the file still reads as .http to
;; anything else.
(check! "a directive is not mistaken for a plain comment"
        (block-executor (list "# just a comment" "# @executor curl"))
        "curl")

(displayln "all buf executor tests passed")

;; ---------------------------------------------------------------------------
;; Method discovery
;; ---------------------------------------------------------------------------

(define listed (list "connectrpc.eliza.v1.ElizaService/Converse"
                     "connectrpc.eliza.v1.ElizaService/Say"
                     "acme.user.v1.UserService/GetUser"))

(check! "group-methods groups by service" (length (group-methods listed)) 2)

;; buf's order is the schema's order, which is more useful than alphabetical.
(check! "group-methods keeps buf's ordering"
        (cdr (car (group-methods listed)))
        (list "Converse" "Say"))

(check! "group-methods names the service"
        (car (car (group-methods listed)))
        "connectrpc.eliza.v1.ElizaService")

(check! "group-methods drops blank lines"
        (length (group-methods (list "" "pkg.S/M" "  ")))
        1)

(check! "group-methods drops lines that are not method refs"
        (length (group-methods (list "Failure: something went wrong")))
        0)

(check! "buf-list-methods-argv asks for the method list"
        (if (member "--list-methods" (buf-list-methods-argv "http://x" #false)) #true #false)
        #true)

(check! "buf-list-methods-argv passes a schema when given"
        (if (member "--schema" (buf-list-methods-argv "http://x" "./proto")) #true #false)
        #true)

(check! "buf-list-methods-argv uses reflection otherwise"
        (member "--schema" (buf-list-methods-argv "http://x" #false))
        #false)

(displayln "all method discovery tests passed")

;; ---------------------------------------------------------------------------
;; Scaffolding
;; ---------------------------------------------------------------------------

;; grpcurl has no scheme to infer a port from, so it is always explicit.
(check! "https defaults to port 443"
        (url->grpc-address "https://demo.connectrpc.com")
        "demo.connectrpc.com:443")

(check! "http defaults to port 80"
        (url->grpc-address "http://example.com")
        "example.com:80")

(check! "an explicit port is kept"
        (url->grpc-address "http://localhost:8080")
        "localhost:8080")

(check! "a path is dropped"
        (url->grpc-address "https://example.com/api")
        "example.com:443")

(check! "http means plaintext" (url-plaintext? "http://localhost:8080") #true)
(check! "https does not" (url-plaintext? "https://x") #false)

;; The leading dot is protobuf's fully-qualified marker; grpcurl rejects a
;; symbol that still carries it.
(check! "describe-input-type strips the leading dot"
        (describe-input-type
         "rpc Say ( .connectrpc.eliza.v1.SayRequest ) returns ( .connectrpc.eliza.v1.SayResponse )")
        "connectrpc.eliza.v1.SayRequest")

(check! "describe-input-type handles a streaming marker"
        (describe-input-type "rpc Introduce ( .pkg.IntroduceRequest ) returns ( stream .pkg.Reply )")
        "pkg.IntroduceRequest")

(check! "describe-input-type is #false without parens"
        (describe-input-type "not a method description")
        #false)

(check! "extract-message-template takes everything after the marker"
        (extract-message-template "pkg.M is a message:\nmessage M {}\n\nMessage template:\n{\n  \"a\": \"\"\n}")
        "{\n  \"a\": \"\"\n}")

(check! "extract-message-template is #false when absent"
        (extract-message-template "pkg.M is a message:")
        #false)

(check! "grpcurl-describe-argv adds -plaintext for http"
        (if (member "-plaintext" (grpcurl-describe-argv "http://x" "pkg.M" #false)) #true #false)
        #true)

(check! "grpcurl-describe-argv omits -plaintext for https"
        (member "-plaintext" (grpcurl-describe-argv "https://x" "pkg.M" #false))
        #false)

(check! "grpcurl-describe-argv asks for a template only when wanted"
        (member "-msg-template" (grpcurl-describe-argv "https://x" "pkg.M" #false))
        #false)

(displayln "all scaffolding tests passed")

;; ---------------------------------------------------------------------------
;; Reflection over plaintext
;; ---------------------------------------------------------------------------

;; buf refuses reflection on an http:// URL without this: there is no ALPN to
;; negotiate HTTP/2 over plain text, and reflection needs HTTP/2.
(check! "http with no schema forces h2c"
        (if (member "--http2-prior-knowledge" (buf-curl-argv "http://localhost:5000/api/p.S/M" '() "{}" #false))
            #true
            #false)
        #true)

(check! "https does not need forcing"
        (member "--http2-prior-knowledge" (buf-curl-argv "https://x/p.S/M" '() "{}" #false))
        #false)

;; With a schema there is no reflection, and forcing HTTP/2 would break a server
;; that only speaks HTTP/1.1.
(check! "a schema suppresses the h2c flag"
        (member "--http2-prior-knowledge" (buf-curl-argv "http://x/p.S/M" '() "{}" "./proto"))
        #false)

(check! "listing methods over http forces h2c too"
        (if (member "--http2-prior-knowledge" (buf-list-methods-argv "http://localhost:5000/api" #false))
            #true
            #false)
        #true)

(check! "listing with a schema does not"
        (member "--http2-prior-knowledge" (buf-list-methods-argv "http://x" "./proto"))
        #false)

;; A base URL with a path prefix must keep it -- the service path is appended,
;; not substituted.
(check! "connect-url keeps a path prefix"
        (connect-url "http://localhost:5000/api" "fishing.v1.Svc" "Method")
        "http://localhost:5000/api/fishing.v1.Svc/Method")

(displayln "all plaintext reflection tests passed")
