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
