;;; connect-picker.scm -- a minimal fuzzy picker over a list of strings.
;;;
;;; Helix registers two pickers for steel and both are file pickers: they call
;;; editor.open on the selected value, so a method name never survives the trip.
;;; `prompt` takes free text with no completion. Hence this: a component built
;;; on new-component!, which is the only route to picking an arbitrary string.
;;;
;;; Deliberately small -- one column, no preview, no multi-select. It exists to
;;; choose a method name, and grows only if something needs more.

(require-builtin helix/components)
(require (only-in "helix/misc.scm" fuzzy-match push-component!))

(provide pick)

;; items    : the full candidate list, filtered by the query as you type
;; query    : what has been typed
;; selected : index into the FILTERED list
;; offset   : first visible row, so a long list can scroll
;; on-choose: called with the chosen string once, on Enter
(struct PickerState (items query selected offset on-choose))

(define (visible-rows area)
  ;; One row goes to the query line, one to each border.
  (let ([rows (- (area-height area) 3)])
    (if (< rows 1) 1 rows)))

(define (filtered state)
  (let ([query (unbox (PickerState-query state))])
    (if (= (string-length query) 0)
        (unbox (PickerState-items state))
        (fuzzy-match query (unbox (PickerState-items state))))))

;;@doc
;; Show a fuzzy picker over ITEMS, calling ON-CHOOSE with the chosen string.
(define (pick items on-choose)
  (push-component!
   (new-component! "connect-picker"
                   (PickerState (box items) (box "") (box 0) (box 0) on-choose)
                   render-picker
                   (hash "handle_event" handle-picker-event "cursor" picker-cursor))))

;; The picker is pushed over the whole screen, so it draws itself into a
;; centered box rather than filling it. Clearing that box first is not optional:
;; without it the buffer shows through, and a shorter line leaves the tail of a
;; longer one behind it ("CreateLake" over "CreateLakeService" reads as
;; "CreateLakeervice").
;; NB the parameter is not called `area`: that would shadow the `area`
;; constructor called below, and the failure is a bare "Function application not
;; a procedure" with no hint of where.
(define (popup-area screen)
  (let* ([width (min 72 (- (area-width screen) 4))]
         [height (min 18 (- (area-height screen) 4))]
         [x (+ (area-x screen) (quotient (- (area-width screen) width) 2))]
         [y (+ (area-y screen) (quotient (- (area-height screen) height) 2))])
    (area x y (max width 10) (max height 4))))

(define (render-picker state area frame)
  (let* ([popup (popup-area area)]
         [matches (filtered state)]
         [rows (visible-rows popup)]
         [offset (unbox (PickerState-offset state))]
         [selected (unbox (PickerState-selected state))]
         [x (+ (area-x popup) 1)]
         [y (+ (area-y popup) 1)]
         [width (- (area-width popup) 2)])
    (buffer/clear frame popup)
    (block/render frame popup (block))
    (frame-set-string! frame
                       x
                       y
                       (pad-to (string-append "> " (unbox (PickerState-query state))) width)
                       (theme-scope-ref "ui.text"))
    (let loop ([i 0])
      (when (and (< i rows) (< (+ offset i) (length matches)))
        (let* ([index (+ offset i)]
               [chosen (= index selected)]
               [label (pad-to (string-append (if chosen "> " "  ") (list-ref matches index))
                              width)])
          (frame-set-string! frame
                             x
                             (+ y 1 i)
                             label
                             (theme-scope-ref (if chosen "ui.selection" "ui.text")))
          (loop (+ i 1)))))))

;; Truncate to WIDTH, then pad back out to it, so the selection highlight is a
;; full-width bar rather than ending at the text.
(define (pad-to s width)
  (cond
    [(> (string-length s) width) (substring s 0 width)]
    [(= (string-length s) width) s]
    [else (string-append s (make-spaces (- width (string-length s))))]))

(define (make-spaces n)
  (let loop ([i 0] [acc ""])
    (if (>= i n) acc (loop (+ i 1) (string-append acc " ")))))

(define (picker-cursor state area)
  (let ([popup (popup-area area)])
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

;; Selection stays inside the list and drags the scroll offset with it; the
;; offset is only ever nudged by one, so it follows rather than jumps.
(define (move-selection! state matches delta)
  (let* ([count (length matches)]
         [next (+ (unbox (PickerState-selected state)) delta)]
         [clamped (cond
                    [(< next 0) 0]
                    [(>= next count) (if (= count 0) 0 (- count 1))]
                    [else next])]
         [offset (unbox (PickerState-offset state))])
    (set-box! (PickerState-selected state) clamped)
    (cond
      [(< clamped offset) (set-box! (PickerState-offset state) clamped)]
      [else void])))
