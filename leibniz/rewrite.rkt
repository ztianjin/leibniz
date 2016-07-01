#lang racket

(require "./sorts.rkt"
         "./operators.rkt"
         "./terms.rkt"
         "./builtins.rkt"
         "./equations.rkt"
         "./contexts.rkt"
         racket/generator)

(module+ test

  (require "./term-syntax.rkt"
           "./test-examples.rkt"
           rackunit
           racket/function
           rackjure/threading)

  (define-context test-context
    (include truth-context)
    (op (not Boolean) Boolean)
    (op foo Boolean)
    (=> (not true) false)
    (=> (not false) true)
    (=> foo (not true) #:if false)
    (=> foo (not false) #:if true))

  (define-context test-with-var
    (include truth-context)
    (op (not Boolean) Boolean)
    (var X Boolean)
    (=> (not true) false)
    (=> (not false) true)
    (=> (not (not X)) X)))

;
; Rule matching and basic term rewriting
;
(define (test-condition context condition substitution)
  (define signature (context-signature context))
  (or (not condition)
      (let* ([s-condition (term.substitute signature condition substitution)]
             [r-condition (reduce context s-condition)])
        (let-values ([(op args) (term.op-and-args r-condition)])
          (and (equal? op 'true)
               (empty? args))))))

(define (in-matching-rules context term test-conditions?)
  (define signature (context-signature context))
  (define rules (lookup-rules (context-rules context) term))
  (unless (allowed-term? signature term)
    (error (format "term not allowed by the context")))
  (in-generator #:arity 2
   (for* ([rule rules]
          [s (term.match signature (rule-pattern rule) term)])
     (when (or (not test-conditions?)
               (test-condition context (rule-condition rule) s))
       (yield rule s)))))

(define (all-matching-rules context term test-conditions?)
  (for/list ([(rule substitution)
              (in-matching-rules context term test-conditions?)])
    (cons rule substitution)))

(module+ test
  (with-context test-context
    (define signature (context-signature test-context))
    (check-equal? (all-matching-rules test-context (T (not true)) #f)
                  (list (cons (make-rule signature (T (not true)) #f (T false))
                              empty-substitution)))
    (check-equal? (all-matching-rules test-context (T foo) #f)
                  (list (cons (make-rule signature
                                         (T foo) (T false) (T (not true)))
                              empty-substitution)
                        (cons (make-rule signature
                                         (T foo) (T true) (T (not false)))
                              empty-substitution)))
    (check-equal? (all-matching-rules test-context (T foo) #t)
                  (list (cons (make-rule signature
                                         (T foo) (T true) (T (not false)))
                              empty-substitution)))))

(define (rewrite-head-once context term)
  (define signature (context-signature context))
  (or (for/first ([(rule substitution) (in-matching-rules context term #t)])
        (term.substitute signature (rule-replacement rule) substitution))
      term))

(module+ test

  (with-context test-context
    (check-equal? (rewrite-head-once test-context (T (not true)))
                  (T false))
    (check-equal? (rewrite-head-once test-context (T (not false)))
                  (T true))
    (check-equal? (rewrite-head-once test-context (T (not (not false))))
                  (T (not (not false))))
    (check-equal? (rewrite-head-once test-context (T foo))
                  (T (not false)))
    (check-exn exn:fail? (thunk (rewrite-head-once test-context (T 42)))))

  (with-context test-with-var
    (check-equal? (rewrite-head-once test-with-var (T (not true)))
                  (T false))
    (check-equal? (rewrite-head-once test-with-var (T (not false)))
                  (T true))
    (check-equal? (rewrite-head-once test-with-var (T (not (not false))))
                  (T false))
    (check-exn exn:fail? (thunk (rewrite-head-once test-with-var (T 42))))))

;
; Recursive rewriting (one step)
;
(define (rewrite-leftmost-innermost context term)
  (define-values (op args) (term.op-and-args term))
  (define signature (context-signature context))
  (if op
      ; op-term or op-pattern: first reduce args
      (let* ([reduced-args (map (λ (arg) (reduce context arg)) args)]
             [with-reduced-args (if (andmap eq? args reduced-args)
                                    ; Optimization for unchanged args, avoids
                                    ; unnecessary term construction. Note the
                                    ; use of eq? for doing a fast check.
                                    term
                                    (make-term* signature op reduced-args))])
        (rewrite-head-once context with-reduced-args))
      ; builtin term type: no args
      (rewrite-head-once context term)))

(module+ test
  (with-context test-context
    (check-equal? (rewrite-leftmost-innermost test-context (T (not true)))
                  (T false))
    (check-equal? (rewrite-leftmost-innermost test-context (T (not false)))
                  (T true))
    (check-equal? (rewrite-leftmost-innermost test-context
                                              (T (not (not false))))
                  (T false))
    (check-equal? (rewrite-leftmost-innermost test-context (T foo))
                  (T (not false)))))

;
; Recursive rewriting to normal form
;
(define (reduce context term)
  (let loop ([term term])
    (let* ([rewritten-term (rewrite-leftmost-innermost context term)])
      (cond
        ; First a fast eq? check
        [(eq? rewritten-term term)    term]
        ; Next the more general but slow equal? check
        [(equal? rewritten-term term) term]
        ; Not equal: another round of rewriting
        [else                         (loop rewritten-term)]))))

(module+ test
  (with-context test-context
    (check-equal? (reduce test-context (T (not true)))
                  (T false))
    (check-equal? (reduce test-context (T (not false)))
                  (T true))
    (check-equal? (reduce test-context (T (not (not false))))
                  (T false))
    (check-equal? (reduce test-context (T foo))
                  (T true))))

;
; Introspection and debugging utilities
;