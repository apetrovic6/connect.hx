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
(require (only-in "helix/misc.scm" set-status! set-error!))

(provide connect-doctor)

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

;; Report the version line of NAME, or #false when it is not installed.
(define (binary-version name flag)
  (if (binary-available? name)
      (let ([result (run-command (string-append name " " flag " 2>&1 | head -1")
                                 (hash 'timeout-ms probe-timeout-ms))])
        (if (hash-ref result 'ok)
            (trim (hash-ref result 'stdout))
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
  (let ([curl-version (binary-version "curl" "--version")]
        [buf-version (binary-version "buf" "--version")])
    (if curl-version
        (set-status!
         (string-append "connect.hx: "
                        curl-version
                        " | buf "
                        (if buf-version buf-version "MISSING (schema features unavailable)")))
        (set-error! "connect.hx: curl not found on PATH -- no executor available"))))
