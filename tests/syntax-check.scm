;;; Balance check for the source files the other tests cannot load.
;;;
;;; connect-client.scm requires `helix/*`, which only exists inside the editor,
;;; so nothing in the test suite evaluates it -- an unbalanced paren there
;;; reaches helix as a startup "error[E09]: Parse" and takes every command in
;;; the file down with it. That happened once, from a bad splice, and the nix
;;; build passed anyway because the tests never touched the file.
;;;
;;; This is not a parser. It checks bracket balance only, which is precisely
;;; the failure mode that editing these files by machine produces.

(define (file->string path)
  (let ([port (open-input-file path)])
    (read-port-to-string port)))

;; Walk the text tracking the lexical states in which a bracket is not a
;; bracket: inside a string, after a `;` to end of line, and the character
;; literals `#\(` and friends, which are single tokens rather than delimiters.
(define (bracket-balance text)
  (let ([len (string-length text)])
    (let loop ([i 0] [depth 0] [in-string #false] [in-comment #false] [line 1] [min-depth 0])
      (if (>= i len)
          (list depth min-depth line)
          (let ([c (string-ref text i)])
            (cond
              ;; A newline always ends a line comment and never appears raw in
              ;; a steel string literal.
              [(char=? c #\newline)
               (loop (+ i 1) depth in-string #false (+ line 1) min-depth)]
              [in-comment (loop (+ i 1) depth in-string #true line min-depth)]
              ;; \" inside a string is an escaped quote, not a terminator; skip
              ;; the escaped character outright so \\" still closes.
              [(and in-string (char=? c #\\))
               (loop (+ i 2) depth #true #false line min-depth)]
              [(char=? c #\")
               (loop (+ i 1) depth (not in-string) #false line min-depth)]
              [in-string (loop (+ i 1) depth #true #false line min-depth)]
              [(char=? c #\;) (loop (+ i 1) depth #false #true line min-depth)]
              ;; #\( -- a character literal whose payload must not be counted.
              [(and (char=? c #\#)
                    (< (+ i 2) len)
                    (char=? (string-ref text (+ i 1)) #\\))
               (loop (+ i 3) depth #false #false line min-depth)]
              [(or (char=? c #\() (char=? c #\[))
               (loop (+ i 1) (+ depth 1) #false #false line min-depth)]
              [(or (char=? c #\)) (char=? c #\]))
               (let ([next (- depth 1)])
                 (loop (+ i 1) next #false #false line (if (< next min-depth) next min-depth)))]
              [else (loop (+ i 1) depth #false #false line min-depth)]))))))

(define (check-file path)
  (let* ([result (bracket-balance (file->string path))]
         [depth (car result)]
         [min-depth (car (cdr result))])
    (cond
      [(< min-depth 0)
       (displayln (string-append "FAIL " path ": closed more brackets than were opened"))
       (error! (string-append "unbalanced brackets in " path))]
      [(> depth 0)
       (displayln (string-append "FAIL " path ": " (to-string depth) " bracket(s) left open"))
       (error! (string-append "unbalanced brackets in " path))]
      [else (displayln (string-append "ok   " path " brackets balanced"))])))

(check-file "connect-client.scm")
(check-file "connect-request.scm")

(displayln "all syntax checks passed")
