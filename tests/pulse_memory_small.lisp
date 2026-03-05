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

;; Small test to verify correctness
(pulse-memory 3 100)
