(define (pulse-memory iterations size)
  (if (> iterations 0)
      (begin
        (display "Expanding memory...") (newline)
        (let ((big-list (make-list size 'data)))
          (display "Memory full. Processing...") (newline)
          (length big-list))
        (display "Reducing memory (GC opportunity)...") (newline)
        (newline)
        (pulse-memory (- iterations 1) size))
      (display "Finished.")))

;; Run 10 cycles of 5,000,000 elements each
(pulse-memory 10 5000000)
