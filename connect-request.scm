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

;; ---------------------------------------------------------------------------
;; Buffer parsing
;;
;; The format is a superset of the vscode-restclient `.http` syntax: requests
;; separated by `###`, `@name = value` declarations, `{{name}}` interpolation.
;; Parsing it here rather than delegating to waddie's http2curl because the Connect
;; layer needs the pieces individually (the method reference in particular),
;; while http2curl only exposes a whole-input string->curl-string conversion.
;; ---------------------------------------------------------------------------

(provide parse-variables
         resolve-variables
         expand-variables
         split-blocks
         block-lines
         block-first-line
         block-last-line
         block-at-line
         blocks-in-line-range
         char-offset->line
         parse-request
         request-error?
         request-error-message
         request-connect?
         request-method
         request-url
         request-headers
         request-body
         request->curl-argv)

;; How many passes `resolve-variables` makes before giving up. A variable
;; referring to another variable is normal (`@eliza = {{base}}/...`); a cycle
;; is not, and must not hang the editor thread.
(define max-variable-passes 10)

;; Marks the Connect shorthand: `>> package.Service/Method`.
(define shorthand-marker ">>")

(define (comment-line? line)
  (let ([t (trim line)])
    (or (starts-with? t "#") (starts-with? t "//"))))

(define (blank-line? line)
  (= (string-length (trim line)) 0))

(define (declaration-line? line)
  (starts-with? (trim line) "@"))

;; Split on the FIRST occurrence of DELIM, returning (before . after), or
;; #false when DELIM does not occur. Used for both `@name = value` and
;; `Header: value`, neither of which may re-split on a delimiter appearing in
;; the value -- a URL contains colons, a token contains equals signs.
(define (split-once str delim)
  (let ([parts (split-many str delim)])
    (if (or (null? parts) (null? (cdr parts)))
        #false
        (cons (car parts)
              (trim-leading-delim (substring str
                                             (string-length (car parts))
                                             (string-length str))
                                  delim)))))

(define (trim-leading-delim str delim)
  (if (starts-with? str delim)
      (substring str (string-length delim) (string-length str))
      str))

;; Collect `@name = value` declarations from the whole buffer, as an alist.
;;
;; File-wide rather than per-block, and last-wins, matching vscode-restclient:
;; a declaration applies to every request in the file, so a `@base` at the top
;; reaches the request at the bottom.
(define (parse-variables text)
  (transduce (split-many text "\n")
             (flat-mapping
              (lambda (line)
                (let ([t (trim line)])
                  (if (declaration-line? t)
                      (let ([parts (split-once (substring t 1 (string-length t)) "=")])
                        (if parts (list (cons (trim (car parts)) (trim (cdr parts)))) '()))
                      '()))))
             (into-list)))

;; Expand `{{name}}` references in STR against VARS.
(define (expand-variables str vars)
  (foldl (lambda (kv acc)
           (string-replace acc (string-append "{{" (car kv) "}}") (cdr kv)))
         str
         vars))

;; Expand references *within* the variable values themselves, so `@eliza =
;; {{base}}/pkg.Svc` resolves. Iterates to a fixed point rather than assuming
;; declaration order, and gives up after max-variable-passes so a cycle
;; (`@a = {{b}}`, `@b = {{a}}`) cannot spin on the editor thread.
(define (resolve-variables vars)
  (let loop ([current vars] [pass 0])
    (if (>= pass max-variable-passes)
        current
        (let ([next (map (lambda (kv)
                           (cons (car kv) (expand-variables (cdr kv) current)))
                         current)])
          (if (equal? next current) current (loop next (+ pass 1)))))))

;; A block is (first-line last-line lines), zero-indexed and inclusive. The
;; `###` separator belongs to the block it introduces, so a cursor resting on
;; the separator selects the request beneath it rather than the one above.
(define (make-block first last lines) (list first last lines))
(define (block-first-line b) (car b))
(define (block-last-line b) (car (cdr b)))
(define (block-lines b) (car (cdr (cdr b))))

(define (separator-line? line) (starts-with? (trim line) "###"))

(define (split-blocks text)
  (let ([lines (split-many text "\n")])
    (let loop ([ls lines] [i 0] [start 0] [cur '()] [acc '()])
      (cond
        [(null? ls)
         (reverse (cons (make-block start (if (> i 0) (- i 1) 0) (reverse cur)) acc))]
        [(and (separator-line? (car ls)) (not (= i start)))
         (loop (cdr ls) (+ i 1) i (list (car ls))
               (cons (make-block start (- i 1) (reverse cur)) acc))]
        [else (loop (cdr ls) (+ i 1) start (cons (car ls) cur) acc)]))))

;; The block containing LINE. Falls back to the last block when the line is
;; past the end, which happens when the cursor sits on the trailing newline.
(define (block-at-line blocks line)
  (let loop ([bs blocks] [fallback #false])
    (cond
      [(null? bs) fallback]
      [(and (>= line (block-first-line (car bs)))
            (<= line (block-last-line (car bs))))
       (car bs)]
      [else (loop (cdr bs) (car bs))])))

;; Zero-indexed line containing character OFFSET.
(define (char-offset->line text offset)
  (let loop ([i 0] [line 0])
    (cond
      [(>= i offset) line]
      [(>= i (string-length text)) line]
      [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ line 1))]
      [else (loop (+ i 1) line)])))

;; A parsed request: (method url headers body connect?). Headers is an alist.
;; `connect?` records that it came from the `>>` shorthand, which milestone 3
;; needs in order to route those to `buf curl` and leave plain HTTP on curl.
(define (make-request method url headers body connect?)
  (list method url headers body connect?))
(define (request-method r) (list-ref r 0))
(define (request-url r) (list-ref r 1))
(define (request-headers r) (list-ref r 2))
(define (request-body r) (list-ref r 3))
(define (request-connect? r) (list-ref r 4))

;; A request that could not be parsed, carrying the reason. Distinct from
;; #false, which means "no request here at all" -- the cursor sitting in a
;; comment block is normal, a malformed `>>` line is not, and the two want
;; different messages.
(define (request-error message) (list 'connect-error message))
(define (request-error? r) (and (list? r) (not (null? r)) (equal? (car r) 'connect-error)))
(define (request-error-message r) (list-ref r 1))

;; Parse one block's LINES into a request, expanding VARS as it goes.
;;
;; Returns #false when the block holds no request line, or a request-error when
;; a line means to be a request but cannot be read as one.
(define (parse-request lines vars)
  (let ([body-lines (drop-leading-noise lines)])
    (if (null? body-lines)
        #false
        (let ([request-line (expand-variables (trim (car body-lines)) vars)]
              [rest (cdr body-lines)])
          (if (starts-with? request-line shorthand-marker)
              (parse-shorthand-request request-line rest vars)
              (parse-longhand-request request-line rest vars))))))

;; `POST <url>` plus a header block and body, the vscode-restclient form.
(define (parse-longhand-request request-line rest vars)
  (let ([parts (split-once request-line " ")])
    (if (not parts)
        #false
        (let* ([method (trim (car parts))]
               [url (trim (cdr parts))]
               [split (split-headers-and-body rest)])
          (if (= (string-length url) 0)
              #false
              (make-request method
                            url
                            (expand-header-values (car split) vars)
                            (expand-variables (cdr split) vars)
                            #false))))))

;; `>> pkg.Service/Method` -- the Connect shorthand.
;;
;; Expands to a POST at `<base>/pkg.Service/Method`; the method, the URL
;; assembly and the Connect headers are all implied, since for a unary Connect
;; call they never vary. The headers come from connect-headers in
;; request->curl-argv, the same as for the longhand form, so a header written
;; in the block still overrides them.
;;
;; The reference may be an absolute URL, in which case `@base` is not consulted
;; -- useful for a one-off call to a different host in a file that has a base.
(define (parse-shorthand-request request-line rest vars)
  (let ([ref (trim (substring request-line
                              (string-length shorthand-marker)
                              (string-length request-line)))])
    (cond
      [(= (string-length ref) 0)
       (request-error "shorthand needs a method: >> package.Service/Method")]
      [(absolute-url? ref) (shorthand-request ref rest vars)]
      [else
       (let ([parsed (parse-method-ref ref)]
             [base (assoc "base" vars)])
         (cond
           [(not parsed)
            (request-error
             (string-append "not a method reference: " ref " -- want package.Service/Method"))]
           [(not base)
            (request-error
             (string-append "no @base declared, so `>> " ref "` has no host to call"))]
           [else
            (shorthand-request (connect-url (cdr base) (car parsed) (cdr parsed)) rest vars)]))])))

(define (shorthand-request url rest vars)
  (let ([split (split-shorthand-headers-and-body rest)])
    (make-request "POST"
                  url
                  (expand-header-values (car split) vars)
                  (expand-variables (cdr split) vars)
                  #true)))

(define (expand-header-values headers vars)
  (map (lambda (h) (cons (car h) (expand-variables (cdr h) vars))) headers))

;; Drop blank lines, comments and `@` declarations ahead of the request line.
(define (drop-leading-noise lines)
  (cond
    [(null? lines) '()]
    [(or (blank-line? (car lines))
         (comment-line? (car lines))
         (declaration-line? (car lines)))
     (drop-leading-noise (cdr lines))]
    [else lines]))

;; Headers run until the first blank line; everything after it is the body.
;; Returns (headers-alist . body-string).
(define (split-headers-and-body lines)
  (let loop ([ls lines] [headers '()])
    (cond
      [(null? ls) (cons (reverse headers) "")]
      [(blank-line? (car ls))
       (cons (reverse headers) (trim (string-join (cdr ls) "\n")))]
      [(comment-line? (car ls)) (loop (cdr ls) headers)]
      [else
       (let ([parts (split-once (car ls) ":")])
         (if parts
             (loop (cdr ls) (cons (cons (trim (car parts)) (trim (cdr parts))) headers))
             (loop (cdr ls) headers)))])))

;; As split-headers-and-body, but the blank line separating headers from body is
;; optional -- dropping it is most of what makes the shorthand shorter.
;;
;; Headers are therefore taken while the lines still LOOK like headers, and the
;; body starts at the first line that does not. That is why header-line? is
;; strict about the name: `{"sentence": "x"}` contains a colon and would
;; otherwise be swallowed as a header named `{"sentence"`, silently costing the
;; request its body.
(define (split-shorthand-headers-and-body lines)
  (let loop ([ls lines] [headers '()])
    (cond
      [(null? ls) (cons (reverse headers) "")]
      [(comment-line? (car ls)) (loop (cdr ls) headers)]
      [(blank-line? (car ls))
       (cons (reverse headers) (trim (string-join (cdr ls) "\n")))]
      [(header-line? (car ls))
       (let ([parts (split-once (car ls) ":")])
         (loop (cdr ls) (cons (cons (trim (car parts)) (trim (cdr parts))) headers)))]
      [else (cons (reverse headers) (trim (string-join ls "\n")))])))

;; `Name: value`, where the name is a token an HTTP header name may actually
;; use -- a letter first, then letters, digits or dashes. Anything looser eats
;; JSON bodies: `{"sentence": "hello"}` splits on its colon just as happily.
;;
;; Spelled with char->integer because steel has no char-alphabetic?.
(define (header-line? line)
  (let ([parts (split-once (trim line) ":")])
    (and parts
         (let ([name (car parts)])
           (and (> (string-length name) 0)
                (ascii-letter? (string-ref name 0))
                (every-char? name header-name-char?))))))

(define (ascii-letter? c)
  (let ([n (char->integer c)])
    (or (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122)))))

(define (header-name-char? c)
  (let ([n (char->integer c)])
    (or (ascii-letter? c) (and (>= n 48) (<= n 57)) (char=? c #\-))))

(define (every-char? s pred)
  (let loop ([i 0])
    (cond
      [(>= i (string-length s)) #true]
      [(pred (string-ref s i)) (loop (+ i 1))]
      [else #false])))

(define (absolute-url? s)

  (or (starts-with? s "http://") (starts-with? s "https://")))
;; A parsed request to curl argv.
;;
;; Headers written in the buffer win over the Connect defaults: a request that
;; explicitly sets Content-Type to application/proto must not have
;; application/json reimposed underneath it.
(define (request->curl-argv req)
  (let* ([written (request-headers req)]
         [defaults (filter (lambda (d)
                             (not (assoc-ci (car d) written)))
                           (connect-headers))])
    (curl-argv (request-url req) (append defaults written) (request-body req))))

;; Header names are case-insensitive, so `content-type:` in the buffer must
;; still suppress the `Content-Type` default.
(define (assoc-ci key alist)
  (let ([needle (string-downcase key)])
    (let loop ([as alist])
      (cond
        [(null? as) #false]
        [(equal? (string-downcase (car (car as))) needle) (car as)]
        [else (loop (cdr as))]))))

;; Every block overlapping the inclusive line range FROM-LINE..TO-LINE.
;;
;; Overlap rather than containment, so a selection touching part of a request
;; still runs the whole of it -- selecting a body line and getting a request
;; with no method is never what was meant.
(define (blocks-in-line-range blocks from-line to-line)
  (filter (lambda (b)
            (and (<= (block-first-line b) to-line)
                 (>= (block-last-line b) from-line)))
          blocks))
