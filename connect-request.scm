;;; connect-request.scm -- pure request construction. No helix dependency.
;;;
;;; Everything here is a plain function over strings and hashes so it can be
;;; exercised by `steel tests/*.scm` in the nix build, where no editor exists.
;;; Anything that touches the editor or spawns a process belongs in
;;; connect-client.scm instead.

(provide parse-method-ref
         method-ref->path
         connect-url
         connect-headers
         curl-argv
         buf-curl-argv)

;; The Connect protocol version header. Required on unary requests by servers
;; that enforce it, and harmless on ones that do not -- always send it.
(define connect-protocol-version "1")

;; Split "acme.user.v1.UserService/GetUser" into its two halves.
;;
;; The separator is the LAST slash, not the first: the service name is a fully
;; qualified protobuf name, so it contains dots but never a slash, while a
;; caller may reasonably paste a whole URL in. Returns a pair of strings, or
;; #false when there is no slash to split on.
(define (parse-method-ref ref)
  (let loop ([i (- (string-length ref) 1)])
    (cond
      [(< i 0) #false]
      [(char=? (string-ref ref i) #\/)
       (cons (substring ref 0 i) (substring ref (+ i 1) (string-length ref)))]
      [else (loop (- i 1))])))

;; Inverse of parse-method-ref: a (service . method) pair back to a path
;; segment. Leading slash included, because that is how it is appended to a
;; base URL.
(define (method-ref->path service method)
  (string-append "/" service "/" method))

;; Join a base URL and a method reference into the full endpoint.
;;
;; A Connect endpoint is always `<base>/<fully.qualified.Service>/<Method>`,
;; so this is the whole of the protocol's URL scheme. Any trailing slash on
;; the base is dropped so `http://localhost:8080/` and `http://localhost:8080`
;; behave identically.
(define (connect-url base service method)
  (let ([trimmed
         (if (and (> (string-length base) 0)
                  (char=? (string-ref base (- (string-length base) 1)) #\/))
             (substring base 0 (- (string-length base) 1))
             base)])
    (string-append trimmed (method-ref->path service method))))

;; The headers every unary JSON request carries, as an alist. EXTRA is an
;; alist of caller-supplied headers appended after these, so a request can
;; override Content-Type (for `application/proto`) or add Authorization.
(define (connect-headers . extra)
  (append (list (cons "Content-Type" "application/json")
                (cons "Connect-Protocol-Version" connect-protocol-version))
          (if (null? extra) '() (car extra))))

;; Build argv for the zero-schema executor.
;;
;; `-i` includes response headers, which is how the renderer recovers the HTTP
;; status -- a Connect error is a non-2xx with a JSON body, and without the
;; status line an error is indistinguishable from a successful response that
;; happens to have a `code` field. Deliberately NO `--fail`: that would make
;; curl exit non-zero on a Connect error and discard the very body that
;; explains what went wrong.
(define (curl-argv url headers body)
  (append (list "--silent" "--show-error" "-i" "-X" "POST")
          (flatten-headers headers)
          (if (and (string? body) (> (string-length body) 0))
              (list "--data-binary" body)
              '())
          (list url)))

;; Build argv for the schema-aware executor.
;;
;; With no `--schema` flag buf falls back to server reflection, which is the
;; common case for a service you are developing against. Unlike curl, this
;; validates the request body against the descriptor and rejects unknown
;; fields client-side, and it decodes streaming responses.
(define (buf-curl-argv url body schema)
  (append (list "curl" "--protocol" "connect")
          (if (string? schema) (list "--schema" schema) '())
          (if (and (string? body) (> (string-length body) 0))
              (list "-d" body)
              '())
          (list url)))

;; ("A" . "b") ... -> ("-H" "A: b" ...)
(define (flatten-headers headers)
  (transduce headers
             (flat-mapping (lambda (h)
                             (list "-H" (string-append (car h) ": " (cdr h)))))
             (into-list)))
