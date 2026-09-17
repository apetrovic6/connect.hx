;;; connect-picker.scm -- a two-pane fuzzy picker over a list of strings.
;;;
;;; Helix registers two pickers for steel and both are file pickers: they call
;;; editor.open on the selected value, so a method name never survives the trip.
;;; `prompt` takes free text with no completion. Hence this: a component built
;;; on new-component!, which is the only route to picking an arbitrary string.
;;;
;;; Laid out like helix's own pickers: query on top, candidates bottom-left,
;;; a preview of the selection on the right.

(require-builtin helix/components)
(require (only-in "helix/misc.scm" fuzzy-match push-component!))

(provide pick)

;; items    : the full candidate list, filtered by the query as you type
;; query    : what has been typed
;; selected : index into the FILTERED list
;; offset   : first visible row, so a long list can scroll
;; on-choose: called with the chosen string once, on Enter
;; preview  : (-> string? (listof string?)) for the right pane, or #false
;; cache    : preview lines already computed, keyed by item
(struct PickerState (items query selected offset on-choose preview cache rows))

;;@doc
;; Show a fuzzy picker over ITEMS, calling ON-CHOOSE with the chosen string.
;; PREVIEW, when given, maps the highlighted item to lines for the right pane.
(define (pick items on-choose preview)
  (push-component!
   (new-component! "connect-picker"
                   (PickerState (box items) (box "") (box 0) (box 0) on-choose preview (box (hash)) (box 10))
                   render-picker
                   (hash "handle_event" handle-picker-event "cursor" picker-cursor))))

(define (filtered state)
  (let ([query (unbox (PickerState-query state))])
    (if (= (string-length query) 0)
        (unbox (PickerState-items state))
        (fuzzy-match query (unbox (PickerState-items state))))))

;; Rows available to the list: the popup minus its two borders, the query line
;; and the rule under it.
(define (visible-rows popup)
  (let ([rows (- (area-height popup) 4)])
    (if (< rows 1) 1 rows)))

;; A centered box rather than the whole screen, which is what gets passed in.
;;
;; NB the parameter is not called `area`: that would shadow the `area`
;; constructor called below, and the failure is a bare "Function application not
;; a procedure" with nothing pointing at the cause.
(define (popup-area screen)
  (let* ([width (min 120 (- (area-width screen) 6))]
         [height (min 24 (- (area-height screen) 4))]
         [x (+ (area-x screen) (quotient (- (area-width screen) width) 2))]
         [y (+ (area-y screen) (quotient (- (area-height screen) height) 2))])
    (area x y (max width 20) (max height 6))))

;; Clearing before drawing is not optional: without it the buffer shows through,
;; and a shorter line leaves the tail of a longer one behind it -- "CreateLake"
;; drawn over "CreateLakeService" reads as "CreateLakeervice".
(define (render-picker state screen frame)
  (let* ([popup (popup-area screen)]
         [matches (filtered state)]
         [rows (visible-rows popup)]
         [x (+ (area-x popup) 1)]
         [y (+ (area-y popup) 1)]
         [inner-width (- (area-width popup) 2)]
         [list-width (if (PickerState-preview state) (quotient inner-width 2) inner-width)])
    ;; Stashed for move-selection!, which has to scroll but never sees the area.
    (set-box! (PickerState-rows state) rows)
    (buffer/clear frame popup)
    (block/render frame popup (block))
    (render-query state frame x y inner-width (length matches))
    (render-rule frame x (+ y 1) inner-width)
    (render-list state frame x (+ y 2) list-width rows matches)
    (when (PickerState-preview state)
      (render-divider frame (+ x list-width) (+ y 2) rows)
      (render-preview state
                      frame
                      (+ x list-width 2)
                      (+ y 2)
                      (- inner-width list-width 2)
                      rows
                      matches))))

;; The count on the right is helix's own habit, and it is the quickest way to
;; see that a query matched nothing.
(define (render-query state frame x y width count)
  (let* ([query (string-append "> " (unbox (PickerState-query state)))]
         [tally (string-append (to-string count) " ")]
         [gap (- width (string-length query) (string-length tally))])
    (frame-set-string! frame
                       x
                       y
                       (pad-to (if (> gap 0)
                                   (string-append query (make-spaces gap) tally)
                                   query)
                               width)
                       (theme-scope-ref "ui.text"))))

(define (render-rule frame x y width)
  (frame-set-string! frame x y (repeat-char #\─ width) (theme-scope-ref "ui.text")))

(define (render-divider frame x y rows)
  (let loop ([i 0])
    (when (< i rows)
      (frame-set-string! frame x (+ y i) "│" (theme-scope-ref "ui.text"))
      (loop (+ i 1)))))

(define (render-list state frame x y width rows matches)
  (let ([offset (unbox (PickerState-offset state))]
        [selected (unbox (PickerState-selected state))])
    (let loop ([i 0])
      (when (and (< i rows) (< (+ offset i) (length matches)))
        (let* ([index (+ offset i)]
               [chosen (= index selected)])
          (frame-set-string! frame
                             x
                             (+ y i)
                             (pad-to (string-append (if chosen "> " "  ") (list-ref matches index))
                                     width)
                             (theme-scope-ref (if chosen "ui.selection" "ui.text")))
          (loop (+ i 1)))))))

;; Previews are cached per item: the function behind this shells out, and
;; recomputing it on every frame would make arrowing through the list crawl.
(define (render-preview state frame x y width rows matches)
  (let ([selected (unbox (PickerState-selected state))])
    (when (< selected (length matches))
      (let ([lines (preview-lines state (list-ref matches selected))])
        (let loop ([i 0] [ls lines])
          (when (and (< i rows) (not (null? ls)))
            (frame-set-string! frame x (+ y i) (pad-to (car ls) width) (theme-scope-ref "ui.text"))
            (loop (+ i 1) (cdr ls))))))))

(define (preview-lines state item)
  (let ([cache (unbox (PickerState-cache state))])
    (if (hash-contains? cache item)
        (hash-ref cache item)
        (let ([lines ((PickerState-preview state) item)])
          (set-box! (PickerState-cache state) (hash-insert cache item lines))
          lines))))

;; Truncate to WIDTH then pad back to it, so a selection highlight is a full-
;; width bar rather than stopping at the text.
(define (pad-to s width)
  (cond
    [(<= width 0) ""]
    [(> (string-length s) width) (substring s 0 width)]
    [(= (string-length s) width) s]
    [else (string-append s (make-spaces (- width (string-length s))))]))

(define (make-spaces n) (repeat-char #\space n))

(define (repeat-char c n)
  (let loop ([i 0] [acc ""])
    (if (>= i n) acc (loop (+ i 1) (string-append acc (string c))))))

(define (picker-cursor state screen)
  (let ([popup (popup-area screen)])
    (position (+ (area-y popup) 1)
              (+ (area-x popup) 3 (string-length (unbox (PickerState-query state)))))))

(define (handle-picker-event state event)
  (let ([matches (filtered state)])
    (cond
      [(key-event-escape? event) event-result/close]
      [(key-event-enter? event)
       (let ([selected (unbox (PickerState-selected state))])
         (when (< selected (length matches))
           ((PickerState-on-choose state) (list-ref matches selected))))
       event-result/close]
      [(key-event-up? event) (move-selection! state matches -1) event-result/consume]
      [(key-event-down? event) (move-selection! state matches 1) event-result/consume]
      [(key-event-backspace? event)
       (let ([query (unbox (PickerState-query state))])
         (when (> (string-length query) 0)
           (set-box! (PickerState-query state) (substring query 0 (- (string-length query) 1)))
           (reset-selection! state)))
       event-result/consume]
      [else
       (let ([c (key-event-char event)])
         (if (char? c)
             (begin
               (set-box! (PickerState-query state)
                         (string-append (unbox (PickerState-query state)) (string c)))
               (reset-selection! state)
               event-result/consume)
             event-result/ignore))])))

(define (reset-selection! state)
  (set-box! (PickerState-selected state) 0)
  (set-box! (PickerState-offset state) 0))

;; Selection stays inside the list and drags the scroll offset with it, nudged
;; by one at a time so the view follows rather than jumps.
(define (move-selection! state matches delta)
  (let* ([count (length matches)]
         [next (+ (unbox (PickerState-selected state)) delta)]
         [clamped (cond
                    [(< next 0) 0]
                    [(>= next count) (if (= count 0) 0 (- count 1))]
                    [else next])]
         [offset (unbox (PickerState-offset state))])
    (set-box! (PickerState-selected state) clamped)
    (let ([rows (unbox (PickerState-rows state))])
      (cond
        [(< clamped offset) (set-box! (PickerState-offset state) clamped)]
        [(>= clamped (+ offset rows)) (set-box! (PickerState-offset state) (- clamped (- rows 1)))]
        [else void]))))
