;;; connect-client.scm -- the helix-facing half of connect.hx.
;;;
;;; Anything in this file may touch the editor or spawn a process, and so
;;; cannot run outside helix; the pure request construction lives in
;;; connect-request.scm, which is what the tests exercise.
;;;
;;; Helix builds its typed command list from the globals present after startup,
;;; so every command below has to appear in the `provide` AND this file has to
;;; be required from init.scm (or from a module that re-provides these names).
;;; See the header of ../magos/modules/features/helix/_config/init.scm for the
;;; full story on why requiring it from inside a module hides the commands.

(require "run-command/run-command.scm")
(require "connect.hx/connect-request.scm")
(require-builtin helix/core/text as text.)
(require-builtin steel/time)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
;; Not only-in: `keymap` is a macro rather than a plain binding, and this is a
;; module, so nothing required here leaks into the global environment anyway.
(require "helix/keymaps.scm")
(require "helix/editor.scm")
(require (only-in "helix/misc.scm"
                  set-status!
                  set-error!
                  cursor-position
                  enqueue-thread-local-callback))

(provide connect-doctor
         connect-exec
         connect-exec-selection
         connect-exec-buffer
         connect-set-timeout
         connect-clear
         connect-install-keybindings!)

;; How long a probe may take before it is treated as a missing binary. Short:
;; `command -v` either answers immediately or something is badly wrong, and
;; this runs on the editor thread.
(define probe-timeout-ms 2000)

;; #true when NAME resolves on PATH.
;;
;; `command -v` rather than `which`: it is a shell builtin, so this costs one
;; /bin/sh and no second exec, and it is POSIX where `which` is not.
(define (binary-available? name)
  (hash-ref (run-command (string-append "command -v " name " >/dev/null 2>&1")
                         (hash 'timeout-ms probe-timeout-ms))
            'ok))

;; Report the version of NAME, or #false when it is not installed.
;;
;; PROBE is a shell pipeline rather than a flag because the two executors
;; disagree wildly on format: `buf --version` prints a bare "1.72.0", while
;; `curl --version` opens with a 200-character line listing every linked
;; library. The status line truncates, so the caller reduces each to a bare
;; version before it ever gets there.
(define (binary-version name probe)
  (if (binary-available? name)
      (let ([result (run-command probe (hash 'timeout-ms probe-timeout-ms))])
        (if (hash-ref result 'ok)
            (let ([out (trim (hash-ref result 'stdout))])
              (if (> (string-length out) 0) out "(unknown version)"))
            #false))
      #false))

;;@doc
;; Report which executors are available, as a status-line message.
;;
;; This is the step-0 smoke test: it proves the cog resolved out of STEEL_HOME,
;; that its run-command dependency loaded, and that spawning a process from the
;; editor thread works -- before any of the real request machinery exists.
;; curl is the zero-schema fallback; buf carries `buf curl`, which validates
;; request bodies against the schema and decodes streaming responses.
(define (connect-doctor)
  (let ([curl-version (binary-version "curl" "curl --version | head -1 | cut -d' ' -f2")]
        [buf-version (binary-version "buf" "buf --version 2>&1 | head -1")])
    (if curl-version
        (set-status!
         (string-append "connect.hx: curl "
                        curl-version
                        " | buf "
                        (if buf-version
                            buf-version
                            "not found (schema features unavailable)")))
        (set-error! "connect.hx: curl not found on PATH -- no executor available"))))

;; ---------------------------------------------------------------------------
;; State
;; ---------------------------------------------------------------------------

;; A box rather than a struct: the only mutable state is the response buffer's
;; doc-id and the timeout, and a box keeps the update sites obvious.
(define client-state (box (hash 'buffer-id #false 'timeout-ms 30000 'request-count 0)))

(define (state-ref key) (hash-ref (unbox client-state) key))

(define (state-set! key value)
  (set-box! client-state (hash-insert (unbox client-state) key value)))

(define response-buffer-name "*connect*")

;; ---------------------------------------------------------------------------
;; Response buffer
;; ---------------------------------------------------------------------------

;; Return the doc-id of the *connect* buffer, creating it in a vertical split
;; if it does not exist or is no longer visible.
;;
;; Focus is restored to the originating view before returning: creating the
;; split moves focus, and the request was written in the other buffer, so
;; leaving the cursor in the response pane would be actively annoying.
(define (ensure-response-buffer)
  (let ([doc-id (state-ref 'buffer-id)])
    (if (and doc-id (editor-doc-exists? doc-id) (editor-doc-in-view? doc-id))
        doc-id
        (let ([origin (editor-focus)])
          (helix.vsplit)
          (helix.new)
          (set-scratch-buffer-name! response-buffer-name)
          (helix.set-language "markdown")
          (let ([new-id (editor->doc-id (editor-focus))])
            (state-set! 'buffer-id new-id)
            (editor-set-focus! origin)
            new-id)))))

;; Append TEXT to the *connect* buffer and scroll the new entry into view.
;;
;; Append rather than replace, so a sequence of calls can be compared against
;; each other -- which is most of what this is for. `:connect-clear` wipes the
;; log when it gets long.
;;
;; The append is done by rewriting the buffer with old + new rather than by
;; seeking to the end and inserting there. That looks wasteful and is
;; deliberate: `select_all` followed by `delete_selection` is the only sequence
;; observed to survive the first write into a newly created buffer. Seeking
;; instead -- with `goto_file_end`, or `collapse_selection`, deferred through
;; enqueue-thread-local-callback or not -- builds a transaction whose positions
;; still belong to the request buffer and applies it to the 1-character
;; response document, panicking helix outright rather than erroring:
;;   Positions [(586, AfterSticky), (587, BeforeSticky)] are out of range for
;;   changeset len 1!  (helix-core/src/transaction.rs:509)
;; select_all rewrites the selection against the document actually being
;; edited, which is what makes it safe; http.hx opens with the same two calls.
;; The buffer is a session-local log of small responses, so rewriting it costs
;; nothing worth optimising.
;;
;; The cursor then goes to the top of the newly appended entry rather than the
;; end of the buffer: a long response would otherwise scroll its own header off
;; screen, and that header is the line saying which call this was. `goto` is
;; 1-indexed and the count is of the lines already present, so it addresses the
;; first line of what was just added.
(define (append-response! text)
  (let ([doc-id (ensure-response-buffer)]
        [origin (editor-focus)])
    (let ([view (editor-doc-in-view? doc-id)])
      (when view
        (let* ([existing (text.rope->string (editor->text doc-id))]
               [existing (if (= (string-length (trim existing)) 0) "" existing)]
               [line-count (length (split-many existing "\n"))])
          (editor-set-focus! view)
          (helix.static.select_all)
          (helix.static.delete_selection)
          (helix.static.insert_string (string-append existing text))
          (helix.static.goto_file_end)
          (helix.static.align_view_bottom)
          (editor-set-focus! origin))))))

;; ---------------------------------------------------------------------------
;; Response formatting
;; ---------------------------------------------------------------------------

;; curl -i emits the header block, a blank line, then the body. Split on the
;; first blank line, tolerating both CRLF and LF.
;;
;; A redirect or a 100-continue produces more than one header block; the LAST
;; one describes the response actually delivered, so keep splitting while what
;; follows still looks like a status line.
(define (split-headers-body raw)
  (let loop ([text raw] [headers ""])
    (let ([idx (find-blank-line text)])
      (if (not idx)
          (cons headers text)
          (let ([block (substring text 0 idx)]
                [rest (substring text (blank-line-end text idx) (string-length text))])
            (if (starts-with? (trim rest) "HTTP/")
                (loop rest block)
                (cons block rest)))))))

;; Index of the first blank line, or #false.
(define (find-blank-line text)
  (let ([lf (find-substring text "\n\n")]
        [crlf (find-substring text "\r\n\r\n")])
    (cond
      [(and lf crlf) (if (< lf crlf) lf crlf)]
      [lf lf]
      [crlf crlf]
      [else #false])))

(define (blank-line-end text idx)
  (if (starts-with? (substring text idx (string-length text)) "\r\n\r\n")
      (+ idx 4)
      (+ idx 2)))

;; Index of NEEDLE in HAYSTACK, or #false. Steel has no such builtin.
(define (find-substring haystack needle)
  (let ([hl (string-length haystack)] [nl (string-length needle)])
    (if (> nl hl)
        #false
        (let loop ([i 0])
          (cond
            [(> i (- hl nl)) #false]
            [(equal? (substring haystack i (+ i nl)) needle) i]
            [else (loop (+ i 1))])))))

;; "HTTP/2 404 Not Found" -> 404, or #false when the line is not a status line.
(define (status-code headers)
  (let ([lines (split-many headers "\n")])
    (if (null? lines)
        #false
        (let ([parts (split-many (trim (car lines)) " ")])
          (if (or (null? parts) (null? (cdr parts)))
              #false
              (string->number (car (cdr parts))))))))

(define (success-status? code) (and code (>= code 200) (< code 300)))

;; Pull `code` and `message` out of a Connect error body for the summary line.
;;
;; The parsed value is used ONLY for this summary -- the body itself is always
;; rendered verbatim. steel's JSON reader turns integers into floats, so a
;; re-serialised body would misreport what the server actually sent.
(define (connect-error-summary body)
  (with-handler
   (lambda (err) #false)
   (let ([parsed (string->jsexpr body)])
     (if (hash? parsed)
         (let ([code (hash-try-get parsed 'code)]
               [message (hash-try-get parsed 'message)])
           (if code
               (string-append (to-string code)
                              (if message (string-append ": " (to-string message)) ""))
               #false))
         #false))))

(define (fence body content-type)
  (string-append "```"
                 (if (and content-type (string-contains? content-type "json")) "json" "")
                 "\n"
                 body
                 "\n```\n"))

(define (header-value headers name)
  (let ([needle (string-downcase name)])
    (let loop ([lines (split-many headers "\n")])
      (cond
        [(null? lines) #false]
        [(starts-with? (string-downcase (trim (car lines))) needle)
         (trim (cdr (split-many-once (trim (car lines)) ":")))]
        [else (loop (cdr lines))]))))

(define (split-many-once line delim)
  (let ([parts (split-many line delim)])
    (if (or (null? parts) (null? (cdr parts)))
        (cons line "")
        (cons (car parts)
              (substring line
                         (+ (string-length (car parts)) (string-length delim))
                         (string-length line))))))

(define (format-response req headers body elapsed-ms index)
  (let* ([code (status-code headers)]
         [status-line (trim (car (split-many headers "\n")))]
         [error-summary (if (success-status? code) #false (connect-error-summary body))]
         [content-type (header-value headers "content-type")])
    (string-append
     "# " (to-string index) " · " (request-method req) " " (request-url req) "\n\n"
     "`" status-line "`"
     (if error-summary (string-append " -- **" error-summary "**") "")
     "  ·  " (to-string elapsed-ms) "ms\n\n"
     (if (= (string-length (trim body)) 0)
         "_(empty body)_\n"
         (fence (trim body) content-type))
     "\n## response headers\n\n"
     (fence (trim headers) #false)
     "\n---\n\n")))

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

;;@doc
;; Set the request timeout in seconds, or report it when called with no
;; argument.
(define (connect-set-timeout . args)
  (if (null? args)
      (set-status! (string-append "connect.hx: timeout "
                                  (to-string (/ (state-ref 'timeout-ms) 1000))
                                  "s"))
      (let ([seconds (string->number (to-string (car args)))])
        (if (and seconds (> seconds 0))
            (begin
              (state-set! 'timeout-ms (* seconds 1000))
              (set-status! (string-append "connect.hx: timeout " (to-string seconds) "s")))
            (set-error! "connect.hx: timeout must be a positive number of seconds")))))

;;@doc
;; Execute the request under the cursor and show the response in *connect*.
(define (connect-exec)
  (run-blocks (blocks-under-cursor) "under the cursor"))

;;@doc
;; Execute every request the selection touches.
;;
;; Overlap, not containment: a selection clipping one line of a request runs the
;; whole of it, since running a fragment is never what was meant.
(define (connect-exec-selection)
  (run-blocks (blocks-in-selection) "in the selection"))

;;@doc
;; Execute every request in the buffer, top to bottom.
;;
;; One request blocks the editor thread; a buffer of them blocks it for their
;; total time, with the timeout bounding each. Worth knowing before pointing it
;; at a file of slow endpoints.
(define (connect-exec-buffer)
  (run-blocks (split-blocks (buffer-text)) "in the buffer"))

(define (buffer-text)
  (text.rope->string (editor->text (editor->doc-id (editor-focus)))))

(define (blocks-under-cursor)
  (let* ([text (buffer-text)]
         [block (block-at-line (split-blocks text) (char-offset->line text (cursor-position)))])
    (if block (list block) '())))

;; The selection's char offsets mapped to lines, then to the blocks they touch.
;; Every range is used, not just the primary, so a multi-cursor selection runs
;; everything it covers.
(define (blocks-in-selection)
  (let* ([text (buffer-text)]
         [blocks (split-blocks text)]
         [ranges (helix.static.selection->ranges (helix.static.current-selection-object))])
    (transduce ranges
               (flat-mapping
                (lambda (range)
                  (blocks-in-line-range blocks
                                        (char-offset->line text (helix.static.range->from range))
                                        (char-offset->line text (helix.static.range->to range)))))
               (into-list))))

;; Parse and run BLOCKS in order, reporting a summary.
;;
;; Variables always come from the WHOLE buffer, never from the blocks being run:
;; `@base` lives at the top of the file and a selection almost never includes
;; it.
;;
;; A block that holds no request is skipped in silence -- the `@`-declaration
;; preamble and comment-only blocks are not requests and saying so for each
;; would be noise. A block whose request is malformed is counted as failed.
;;
;; A failure does not stop the run. The point of executing several is to see all
;; of their results, and stopping at the first would throw away the rest; a
;; non-2xx is not even a failure here, just a response with an error body.
(define (run-blocks blocks where)
  (let ([vars (resolve-variables (parse-variables (buffer-text)))])
    (let loop ([bs blocks] [ran 0] [failed 0] [last-status ""])
      (if (null? bs)
          (report-run ran failed last-status where)
          (let ([req (parse-request (block-lines (car bs)) vars)])
            (cond
              [(not req) (loop (cdr bs) ran failed last-status)]
              [(request-error? req)
               (set-error! (string-append "connect.hx: " (request-error-message req)))
               (loop (cdr bs) ran (+ failed 1) last-status)]
              [else
               (let ([status (execute-request req)])
                 (loop (cdr bs)
                       (+ ran 1)
                       (if status failed (+ failed 1))
                       (if status status last-status)))]))))))

;; One request reports its own status line; several report a tally, since the
;; individual ones would all overwrite each other anyway.
(define (report-run ran failed last-status where)
  (cond
    [(and (= ran 0) (= failed 0))
     (set-error! (string-append "connect.hx: no request " where))]
    [(= (+ ran failed) 1)
     (when (> (string-length last-status) 0) (set-status! last-status))]
    [else
     (set-status! (string-append "connect.hx: ran "
                                 (to-string ran)
                                 " request"
                                 (if (= ran 1) "" "s")
                                 (if (> failed 0)
                                     (string-append ", " (to-string failed) " failed")
                                     "")))]))

;; Run REQ and append its response. Returns the status line on success, or
;; #false when curl itself failed -- which is what the caller counts.
(define (execute-request req)
  (let* ([started (instant/now)]
         [result (run-argv "curl"
                           (request->curl-argv req)
                           (hash 'timeout-ms (state-ref 'timeout-ms)))]
         [elapsed (duration->millis (instant/elapsed started))])
    (cond
      [(hash-ref result 'timed-out)
       (set-error! (string-append "connect.hx: timed out after "
                                  (to-string (/ (state-ref 'timeout-ms) 1000))
                                  "s"))
       #false]
      ;; A non-2xx is NOT a failure here -- curl exits 0 and the body carries
      ;; the Connect error. A non-zero exit means curl itself failed: DNS,
      ;; connection refused, TLS.
      [(not (hash-ref result 'ok))
       (set-error! (string-append "connect.hx: curl failed (exit "
                                  (to-string (hash-ref result 'exit))
                                  "): "
                                  (trim (hash-ref result 'stderr))))
       #false]
      [else
       (let* ([split (split-headers-body (hash-ref result 'stdout))]
              [headers (car split)]
              [body (cdr split)])
         (state-set! 'request-count (+ 1 (state-ref 'request-count)))
         (append-response!
          (format-response req headers body elapsed (state-ref 'request-count)))
         (string-append "connect.hx: "
                        (trim (car (split-many headers "\n")))
                        " in "
                        (to-string elapsed)
                        "ms"))])))
;;@doc
;; Empty the *connect* buffer.
(define (connect-clear)
  (let ([doc-id (ensure-response-buffer)]
        [origin (editor-focus)])
    (let ([view (editor-doc-in-view? doc-id)])
      (when view
        (editor-set-focus! view)
        (helix.static.select_all)
        (helix.static.delete_selection)
        (editor-set-focus! origin)))
    (state-set! 'request-count 0)
    (set-status! "connect.hx: cleared")))

;; ---------------------------------------------------------------------------
;; Keybindings
;; ---------------------------------------------------------------------------

;; File extensions that get the connect.hx bindings.
(define binding-extensions (list "connect" "http"))

;;@doc
;; Bind the connect.hx commands under `space H` in .connect and .http files.
;;
;; `space H c` executes, `space H x` clears. Both rows are labelled from their
;; @doc once the submenu is open; the `H` row in the parent space menu is blank,
;; which is not fixable -- a submenu's description is its KeyTrieNode name, that
;; field is private and #[serde(skip)], and the whole steel keymap API has no
;; setter for it. Only rust's keymap! macro names a node.
;;
;; The inherit-from is load-bearing. Helix falls back to the global keymap only
;; on a miss, and a map holding just `space H` would match `space` and strand
;; every other sequence under it inside these files.
(define (connect-install-keybindings!)
  (enqueue-thread-local-callback
   (lambda ()
     (for-each install-bindings-for-extension! binding-extensions))))

(define (install-bindings-for-extension! ext)
  (keymap (extension ext (inherit-from (deep-copy-global-keybindings)))
          (normal (space (H (c ":connect-exec")
                            (s ":connect-exec-selection")
                            (b ":connect-exec-buffer")
                            (x ":connect-clear"))))))
