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
        (member "--schema" (buf-curl-argv "http://x/pkg.Svc/M" "{}" #false))
        #false)

(check! "buf-curl-argv passes a schema when one is given"
        (if (member "--schema" (buf-curl-argv "http://x/pkg.Svc/M" "{}" "./proto")) #true #false)
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
