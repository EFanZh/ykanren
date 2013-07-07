;;; miniKanren from Dan Friedman, William Byrd and Oleg Kiselyov

;;; modified by Yin Wang to support a negation operator (noto) and a disjoint
;;; branching operator (condc). The limitation is that they cannot be nested
;;; (will remove this limitation later).

;;; Lazy streams are used to make the connections more modular.


(define *debug-tags* '())
(define debug
  (lambda (tags format . args)
    (let* ((tags (if (not (pair? tags)) (list tags) tags))
           (fs (string-append "[" (symbol->string (car tags)) "] " format "\n")))
      (cond
       [(null? tags)]
       [(pair? tags)
        (if (member (car tags) *debug-tags*)
            (apply printf fs args)
            (void))]
       ))))



(define-syntax lambdag@
  (syntax-rules ()
    ((_ (p ...) e ...) (lambda (p ...) e ...))))


(define-syntax lambdaf@
  (syntax-rules ()
    ((_ () e ...) (lambda () e ...))))


(define-syntax inc
  (syntax-rules () ((_ e) (lambdaf@ () e))))


(define defunc
  (lambda (f)
    (if (procedure? f) (defunc (f)) f)))



;;------------ stream primitives ------------
(define snull 'snull)


(define snull? 
  (lambda (s)
    (eq? s snull)))


(define-syntax scons
  (syntax-rules ()
    ((_ a d) (cons a (lambda () d)))))


(define scar
  (lambda (s)
    (cond
     [(procedure? s) (scar (s))]
     [else (car s)])))


(define scdr
  (lambda (s)
    (cond
     [(procedure? s) (scdr (s))]
     [else ((cdr s))])))


(define-syntax sunit
  (syntax-rules ()
    ((_ a) (scons a snull))))


(define slift
  (lambda (f)
    (lambda args
      (sunit (apply f args)))))


(define-syntax make-stream
  (syntax-rules ()
    ((_) snull)
    ((_ e1 e2 ...) (scons e1 (make-stream e2 ...)))))


(define taken
  (lambda (n s)
    (if (and n (zero? n))
        '()
        (let ([s (defunc s)])
          (cond
           [(snull? s) '()]
           [else (cons (scar s) (taken (and n (- n 1)) (scdr s)))])))))


(define smerge
  (lambda (s1 s2)
    (cond
     [(snull? s1) s2]
     [(procedure? s1)
      (lambda () (smerge s2 (s1)))]
     [else (scons (scar s1) (smerge s2 (scdr s1)))])))


(define stream-merge
  (lambda (ss)
    (cond
     [(snull? ss) snull]
     [(procedure? ss) (lambda () (stream-merge (ss)))]
     [(snull? (scar ss)) (stream-merge (scdr ss))]
     [(procedure? (scar ss)) (lambda () 
                               (smerge (stream-merge (scdr ss))
                                       (scar ss)))]
     [else (scons (scar (scar ss)) (smerge (scdr (scar ss))
                                           (stream-merge (scdr ss))))])))

(define smap
  (lambda (f s)
    (cond
     [(snull? s) snull]
     [(procedure? s) (lambda () (smap f (s)))]
     [else (scons (f (scar s)) (smap f (scdr s)))])))



;; Substitution
(define-syntax rhs
  (syntax-rules ()
    ((_ x) (cdr x))))


(define-syntax lhs
  (syntax-rules ()
    ((_ x) (car x))))


(define-syntax size-s
  (syntax-rules ()
    ((_ x) (length x))))


(define-syntax var
  (syntax-rules ()
    ((_ x) (vector x))))


(define-syntax var?
  (syntax-rules ()
    ((_ x) (vector? x))))


(define empty-s '())

(define ext-s
  (lambda (x v s)
    (cons `(,x . ,v) s)))


(define walk
  (lambda (v s)
    (cond
      ((var? v)
       (let ((a (assq v s)))
         (cond
           (a (walk (rhs a) s))
           (else v))))
      (else v))))


(define unify
  (lambda (v w s env)
    ((Env-unify env) v w s env)))


(define unify-good
  (lambda (v w s env)
;    (printf "[unify-good]: ~a <--> ~a :: ~a\n" v w s)
    (let ((v (walk v s))
          (w (walk w s)))
      (cond
        ((eq? v w) s)
        ((var? v) (ext-s v w s))
        ((var? w) (ext-s w v s))
        ((and (pair? v) (pair? w))
         (let ((s (unify-good (car v) (car w) s env)))
           (and s (unify-good (cdr v) (cdr w) s env))))
        ((equal? v w) s)
        (else #f)))))


(define unify-evil
  (lambda (v w s env)
    (debug '(unify-evil unify) 
           "v=~a, w=~a, cvars: ~a\n  subst:~a" v w (Env-cvars env) s)
    (let ((vv (walk v s))
          (ww (walk w s)))
      (cond
       ((eq? vv ww) s)
       ((and (var? vv) (memq v (Env-cvars env))) #f)
       ((and (var? ww) (memq w (Env-cvars env))) #f)
       ((var? vv) (ext-s vv ww s))
       ((var? ww) (ext-s ww vv s))
       ((and (pair? vv) (pair? ww))
        (let ((s (unify-evil (car vv) (car ww) s env)))
          (and s (unify-evil (cdr vv) (cdr ww) s env))))
       ((equal? vv ww) s)
       (else #f)))))


(define switch-unify
  (lambda (env)
    (if (eq? (Env-unify env) unify-good)
        (change-unify env unify-evil)
        (change-unify env unify-good))))


(define unify-check
  (lambda (u v s)
    (let ((u (walk u s))
          (v (walk v s)))
      (cond
        ((eq? u v) s)
        ((var? u) (ext-s-check u v s))
        ((var? v) (ext-s-check v u s))
        ((and (pair? u) (pair? v))
         (let ((s (unify-check (car u) (car v) s)))
           (and s (unify-check (cdr u) (cdr v) s))))
        ((equal? u v) s)
        (else #f)))))

 
(define ext-s-check
  (lambda (x v s)
    (cond
      ((occurs-check x v s) #f)
      (else (ext-s x v s)))))


(define occurs-check
  (lambda (x v s)
    (let ((v (walk v s)))
      (cond
        ((var? v) (eq? v x))
        ((pair? v) 
         (or 
           (occurs-check x (car v) s)
           (occurs-check x (cdr v) s)))
        (else #f)))))


(define walk*
  (lambda (w s)
    (let ((v (walk w s)))
      (cond
        ((var? v) v)
        ((pair? v)
         (cons
           (walk* (car v) s)
           (walk* (cdr v) s)))
        (else v)))))


(define reify-s
  (lambda (v s)
    (debug 'reify-s "v: ~a\ns:~a" v s)
    (let ((v (walk v s)))
      (cond
        ((var? v)
         (ext-s v (reify-name (size-s s)) s))
        ((pair? v) (reify-s (cdr v)
                     (reify-s (car v) s)))
        (else s)))))


(define reify-name
  (lambda (n)
    (string->symbol
      (string-append "_" "." (number->string n)))))


(define reify
  (lambda (v s)
    (let ((v (walk* v s)))
      (walk* v (reify-s v empty-s)))))





;-------------------------------------------------------------
;                     data structures
;-------------------------------------------------------------

(struct Pkg (subst constraints) #:transparent)


;; constraints save the current environment vars
(struct Constraint (goal vars text) #:transparent)


;; environment
(struct Env (unify constraints vars cvars) #:transparent)

(define Env-constraint-goals
  (lambda (p)
    (map Constraint-goal (Env-constraint p))))


(define ext-pkg-constraints
  (lambda (p cs ctexts env)
    (let ([newc (map (lambda (g t) 
                       (Constraint g (Env-vars env) t))
                     cs ctexts)])
      (Pkg (Pkg-subst p) (append newc (Pkg-constraints p))))))



;; convenience functions
(define change-unify
  (lambda (p u)
    (match p
      [(Env _ constraints vars cvars)
       (Env u constraints vars cvars)])))


(define change-constraints
  (lambda (p c)
    (match p
      [(Env unify _ vars cvars)
       (Env unify c vars cvars)])))


(define change-vars
  (lambda (p v)
    (match p
      [(Env unify constraints _ cvars)
       (Env unify constraints v cvars)])))


(define change-cvars
  (lambda (p cv)
    (match p
      [(Env unify constraints vars _)
       (Env unify constraints vars cv)])))


(define ext-constraint
  (lambda (env new-cg)
    (let ([newc (map (lambda (g) (Constraint g (Env-vars env) 'a))
                     new-cg)])
      (change-constraints env newc))))


(define ext-vars
  (lambda (env new-vars)
    (change-vars env (append new-vars (Env-vars env)))))


(define ext-cvars
  (lambda (env new-cvars)
    (change-cvars env (append new-cvars (Env-cvars env)))))






;-------------------------------------------------------------
;                       miniKanren
;-------------------------------------------------------------

(define succeed (lambda (s env) (sunit s)))
(define fail (lambda (s env) snull))


(define bind
  (lambda (s f env)
    (cond
     [(procedure? s) (lambda () (bind (s) f env))]
     [else
      (stream-merge (smap (lambda (s) (f s env)) s))])))


(define bind*
  (lambda (s goals env)
    (cond
     [(null? goals)
      (stream-merge
       (smap (lambda (s) 
               (bind-constraints (sunit s) (Pkg-constraints s) env))
             s))]
     [(snull? s) snull]
     [else (bind* (bind s (car goals) env) (cdr goals) env)])))


(define bind*
  (lambda (s goals env)
    (cond
     [(null? goals) s]
     [(snull? s) snull]
     [else (bind* (bind s (car goals) env) (cdr goals) env)])))


(define bind-constraints
  (lambda (s cs env)
    (cond
     [(null? cs) s]
     [(snull? s) snull]
     [else 
      (debug 'bind-constraints
             "checking constraint: ~a" (Constraint-text (car cs)))
      (bind-constraints
            (bind s
                  (Constraint-goal (car cs))
                  (Env (Env-unify env)
                            '()                     ; no constraints
                            (Env-vars env)
                            (Constraint-vars (car cs)))) 
            (cdr cs)
            env)])))


(define ==
  (lambda (u v)
    (lambdag@ (s env)
      (let ((s1 ((Env-unify env) u v (Pkg-subst s) env)))
        (cond
         [(not s1) snull]
         [else (sunit (Pkg s1 (Pkg-constraints s)))])))))


(define ==
  (lambda (u v)
    (lambdag@ (s env)
      (let ((s1 ((Env-unify env) u v (Pkg-subst s) env)))
        (cond
         [(not s1) snull]
         [else
          (let ([cc (bind-constraints (sunit (Pkg s1 '()))
                                      (Pkg-constraints s) env)])
            (if (snull? cc)
                snull
                (sunit (Pkg s1 (filter (lambda (c) 
                                         (not (subsumed? c (Pkg-subst s))))
                                       (Pkg-constraints s))))))])))))


(define ando
  (lambda goals
    (lambdag@ (s env)
      (bind* (sunit s) goals env))))


(define org2
  (lambda (goals)
    (lambdag@ (s env)
      (cond
       [(null? goals) snull]
       [else
        (scons (bind (sunit s) (car goals) env)
               ((org2 (cdr goals)) s env))]))))


(define oro
  (lambda goals
    (lambdag@ (s env)
      (stream-merge ((org2 goals) s env)))))

(define noto
  (lambda (g)
    (lambdag@ (s env)
      (let ([ans (defunc (g s (switch-unify env)))])
        (if (snull? ans)
            (succeed s env)
            (fail s env))))))


(define-syntax fresh
  (syntax-rules ()
    ((_ (x ...) g0 g ...)
     (lambdag@ (s env)
       (inc
         (let ((x (var 'x)) ...)
           ((ando g0 g ...) s (ext-vars env (list x ...)))))))))


(define-syntax forall
  (syntax-rules ()
    ((_ (x ...) g0 g ...)
     (lambdag@ (s env)
       (inc
         (let ((x (var 'x)) ...)
           ((ando g0 g ...)
            (let loop ([ss (Pkg-subst s)] [vars (list x ...)])
             (cond
              [(null? vars) ss]
              [else (loop (ext-s (car vars) (gensym) ss) (cdr vars))]))
            (ext-vars env (list x ...)))))))))


(define-syntax conde
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (s env)
       (inc
         ((oro (ando g0 g ...)
               (ando g1 g^ ...) ...) s env))))))


(define-syntax condc
  (syntax-rules ()
    ((_ (g0 g ...)) (ando g0 g ...))
    ((_ (g0 g ...) g^ ...)
     (lambdag@ (s env)
       (inc
         ((oro (ando g0 g ...)
               (assert ((noto g0))
                       (condc g^ ...))) s env))))))


(define reify-constraint
  (lambda (s)
    (lambda (c)
      (let ((ct (Constraint-text c)))
        (cond
         [(pair? ct)
          (cons (car ct) 
                (map (lambda (v) (walk* v (Pkg-subst s))) (cdr ct)))]
         [else ct])))))


(define format-constraints
  (lambda (s)
    (debug 'format-constraints "subst: ~a\nconstraints: ~a\n" 
           (Pkg-subst s)
           (Pkg-constraints s))
    (map (reify-constraint s)
         (filter (lambda (c) 
                   (not (subsumed? c (Pkg-subst s))))
                 (Pkg-constraints s)))))


(define-syntax run
  (syntax-rules ()
    ((_ n (x) g0 g ...)
     (let ((x (var 'x)))
       (let ([ss ((ando g0 g ...) (Pkg empty-s '())
                   (Env unify-good '() (list x) '()))])
         (taken n (smap (lambda (s)
                         (let* ((x (walk* x (Pkg-subst s)))
                                (rs (reify-s x empty-s)))
                           (list
                            (walk* x rs)
                            (let ((ctext (walk* (format-constraints s) rs)))
                              (if (null? ctext)
                                  '()
                                  (list 'constraints: ctext))))))
                       ss)))))))


(define subsumed?
  (lambda (c s)
    (debug 'subsumed?
           "constraint: ~a\nvars: ~a\nsubst:~a\n"
           (Constraint-text c)
           (Constraint-vars c)
           s)
    (not (snull?
          (defunc ((Constraint-goal c)
                   (Pkg s '())
                   (Env unify-evil '() '() (Constraint-vars c))))))))


(define-syntax run*
  (syntax-rules ()
    ((_ (x) g ...) (run #f (x) g ...))))


(define-syntax make-text
  (syntax-rules (quote quasiquote)
    ((_ (quote a)) (quote a))
    ((_ (quasiquote a)) (quasiquote a))
    ((_ (g a0 ...)) (list 'g (make-text a0) ...))
    ((_ a) a)))


(define-syntax make-text*
  (syntax-rules (quote quasiquote)
    ((_) '())
    ((_ (quote a)) (quote a))
    ((_ (quasiquote a)) (quasiquote a))
    ((_ (g0 a ...) g ...)
     (list (make-text (g0 a ...)) (make-text g) ...))
    ((_ a) 'a)))


;; (make-text* `b)
;; (make-text* (noto (== `(,a ,d) (cons u v))) (noto (appendo a b c)))
;; (define a 1)
;; (define b 2)
;; (define c 3)
;; (define d 4)
;; (define u 5)
;; (define v 6)
;; (make-text* (a b c) `(,c a))
;; (define q 10)
; (make-text* (noto (== q 3)))


(define-syntax assert
  (syntax-rules ()
    ((_ (c0 c ...) g ...)
     (lambdag@ (s env)
       (inc 
        ((ando g ...)
         (ext-pkg-constraints s (list c0 c ...) (make-text* c0 c ...) env)
         (ext-constraint env (list c0 c ...))))))))


(define-syntax conda
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (s)
       (inc
         (ifa ((g0 s) g ...)
              ((g1 s) g^ ...) ...))))))


(define-syntax ifa
  (syntax-rules ()
    ((_) snull)
    ((_ (e g ...) b ...)
     (cond
      [(snull? (defunc e)) (ifa b ...)]
      [else (bind* e (list g ...))]))))


(define-syntax condu
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (s)
       (inc
         (ifu ((g0 s) g ...)
              ((g1 s) g^ ...) ...))))))

 
(define-syntax ifu
  (syntax-rules ()
    ((_) snull)
    ((_ (e g ...) b ...)
     (cond
      [(snull? (defunc e)) (ifa b ...)]
      [else (bind* (sunit (scar e)) (list g ...))]))))


(define-syntax project
  (syntax-rules ()
    ((_ (x ...) g g* ...)
     (lambdag@ (s env)
       (let ((x (walk* x s)) ...)
         ((fresh () g g* ...) s env))))))



(define prints
  (lambda (s env)
    (begin 
      (printf "#[prints]:: ~s\n" s)
      (succeed s env))))


(define print-env
  (lambdag@ (s env)
    (begin 
      (printf "env: ~s\n" env)
      (succeed s env))))


(define print-var
  (lambda (name v)
    (lambda (s env)
      (begin 
        (printf "#[print-var] ~a = ~s\n" name (walk v s))
        (succeed s env)))))


(define-syntax print-var
  (syntax-rules ()
    ((_ v) (lambda (s env)
             (begin 
               (printf "#[print-var] ~a = ~s\n" 'v (walk* v (Pkg-subst s)))
               (succeed s env))))))


(define print-constraintso
  (lambda (s env)
    (printf "#[constraints] \n~a\n" 
            (map (lambda (s) (format "~a\n" s))
                 (map (reify-constraint s) (Pkg-constraints s))))
    (succeed s env)))





;-------------------------------------------------------------
;                basic definitions (from TRS)
;-------------------------------------------------------------

(define caro
  (lambda (p a)
    (fresh (d)
      (== (cons a d) p))))


(define cdro
  (lambda (p d)
    (fresh (a)
      (== (cons a d) p))))


(define conso
  (lambda (a d p)
    (== (cons a d) p)))


(define nullo
  (lambda (x)
    (== '() x)))


(define eqo
  (lambda (x y)
    (== x y)))


(define pairo
  (lambda (p)
    (fresh (a d)
      (conso a d p))))


(define nullo
  (lambda (x)
    (== '() x)))




;-------------------------------------------------------------
;                  rembero (TRS frame 30)
;-------------------------------------------------------------

;; using conde operator
(define rembero1
  (lambda (x l out)
    (conde
      ((nullo l) (== '() out))
      ((caro l x) (cdro l out))
      ((fresh (res)
         (fresh (d)
           (cdro l d)
           (rembero1 x d res))
         (fresh (a)
           (caro l a)
           (conso a res out)))))))


;; example
(run* (out)
 (fresh (y)
   (rembero1 y `(a b ,y d peas e) out)))


;; We got 7 answers, 4 of which shouldn't happen, because
;; the fresh variable y should never fail to remove itself
;; and thus go on to remove d, peas and e.

;; =>
;; (((b a d peas e) ())               ; y == a
;;  ((a b d peas e) ())               ; y == b
;;  ((a b d peas e) ())               ; y == y
;;  ((a b d peas e) ())               ; unreasonable beyond this point
;;  ((a b peas d e) ())
;;  ((a b e d peas) ())
;;  ((a b _.0 d peas e) ()))



;; using condc operator
(define rembero
  (lambda (x l out)
    (condc
      ((nullo l) (== '() out))
      ((caro l x) (cdro l out))
      ((fresh (res)
         (fresh (d)
           (cdro l d)
           (rembero x d res))
         (fresh (a)
           (caro l a)
           (conso a res out)))))))


;; example
(run* (out)
 (fresh (y)
   (rembero y `(a b ,y d peas e) out)))


;; We got only 3 answers, plus two constraints for the third
;; answer. The constraints are basically saying: If we are
;; to have this answer, neither (caro (b y d peas e) y) nor
;; (caro (a b y d peas e) y) should hold.

;; =>
;; (((b a d peas e) ())
;;  ((a b d peas e) ())
;;  ((a b d peas e)
;;   (constraints:
;;    ((noto (caro (b #1(y) d peas e) #1(y)))
;;     (noto (caro (a b #1(y) d peas e) #1(y)))))))





;-------------------------------------------------------------
;                     Oleg's comments (Jul 23)
;-------------------------------------------------------------

(run 5 (out)
 (fresh (y l r)
  (== out (list y l r))
  (rembero y l r)))

;; =>
;; '(((_.0 () ()) ())
;;   ((_.0 (_.0 . _.1) _.1) ())
;;   ((_.0 (_.1) (_.1)) 
;;    (constraints: ((noto (caro (_.1) _.0)))))
;;   ((_.0 (_.1 _.0 . _.2) (_.1 . _.2))
;;    (constraints: ((noto (caro (_.1 _.0 . _.2) _.0)))))
;;   ((_.0 (_.1 _.2) (_.1 _.2))
;;    (constraints: ((noto (caro (_.2) _.0))
;;                   (noto (caro (_.1 _.2) _.0))))))


;; Here, the constraints are really part of the answer: the answer
;; (_.0 (_.1) (_.1)) does not make sense without the constraint that
;; _.0 must be different from _.1. The easy way to see that (_.0 (_.1)
;; (_.1)) is not an answer is to instantiate both variables to 1:

(run 5 (out)
 (fresh (y l r)
  (== out '(1 (1) (1)))
  (== out (list y l r))
  (rembero y l r)))


;; produces (). Thus constraints must be, in general, part of the
;; answer. Hence what I said about the need to normalize constraints
;; applies. Here is the simple example where constraint normalization
;; may help:

(run* (out)
  (fresh (x y)
    (== out (list x y))
    (condc
      ((caro (list x) y))
      ((caro (list y) x))
      ((caro (list y) 1))
      ((caro (list x) 1)))))

;; =>
;; '(((_.0 _.0) ())
;;   ((_.0 1)
;;    (constraints: 
;;     ((noto (caro (list 1) _.0))
;;      (noto (caro (list _.0) 1)))))
;;   ((1 _.0)
;;    (constraints:
;;     ((noto (caro (list _.0) 1))
;;      (noto (caro (list _.0) 1))
;;      (noto (caro (list 1) _.0))))))


;; The three constraints in the last answer are identical, aren't they?

;; Here is why we need a genuine constraint solver.

; num predicate
(define (num x)
 (conde
   ((== x '()))
   ((fresh (y)
    (== x (cons 1 y))
    (num y)))))

(run 5 (out) (num out))


; greater-than on num
(define (gt x y)
 (conde
   ((== y '()) (pairo x))
   ((fresh (x1 y1)
     (== x (cons 1 x1))
     (== y (cons 1 y1))
     (gt x1 y1)))))

(run* (out) (gt '(1 1 1 1) out))


;; (run 1 (out)
;;  (fresh (x y)
;;   (condc
;;     ((gt x y) fail)
;;     ((gt x (cons 1 y))
;;      (num x) (num y) (== out 'really?)))))

;; => diverges

;; rewritten this way
;; (run 1 (out)
;;  (fresh (x y)
;;    (== out (list x y))
;;    (num x) (num y)
;;    (condc
;;      ((gt x y) fail)
;;      ((gt x (cons 1 y))))))


;; The genuine constraint solver for naturals would have determined
;; that if NOT(x > y) then x > y+1 cannot succeed. The CLP system will
;; return the finite failure. This is the fundamental difference
;; between CLP and ordinary Prolog: Prolog is based on `generate and
;; test', whereas CLP do `test and then generate'. They solve
;; constraints using uninstantiated variables; they instantiate
;; afterwards.

;; Incidentally, your noto does not play well will committed choice
;; like condu and conda, which is expected (one has to be very careful
;; nesting of condu and conda). There is an easy way to make condu and
;; conda sound (at least, reporting a run-time error when attempting
;; to instantiate a non-local variable). The best way to solve this
;; problems is with mode inference (as Mercury or Twelf do).

;; Incidentally, the mini-Kanren is based on lazy lists (on streams).
;; The monad of mini-Kanren is

;;        data L a = Zero | One a | Cons a (() -> L a)

;; which is the ordinary lazy list with the special case for
;; one-element list.

       ;; Cheers,
       ;; Oleg
