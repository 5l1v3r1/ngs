;; apt-get install cl-esrap

(require :asdf)
(require :esrap)

(defpackage :ngs
  (:use :cl :esrap)
  (:export
   :ngs-call-function
   :ngs-compile))

(in-package :ngs)

(defstruct parameters positional named)
(defstruct arguments  positional named)


(defvar *source-file-name* "TOP-LEVEL")
(defvar *source-file-positions* #(0))

;; Parser - start ------------------------------


(defclass node ()
  ((src :initarg :src :initform nil :accessor node-src)
   (children :initarg :children :initform (list) :accessor node-children)
   (data :initarg :data :initform nil :accessor node-data)))

(defparameter *required-space-binary-operators*
  '(("or")
    ("and")
    ("in" "not in")))

(defparameter *optional-space-binary-operations*
  '(("*" "/")
    ("+" "-")))

(defparameter *binary-operators*
  (append
   (mapcar #'(lambda(x) `(and space (or ,@x) space)) *required-space-binary-operators*)
   (mapcar #'(lambda(x) `(and optional-space (or ,@x) optional-space)) *optional-space-binary-operations*)))

(defmethod print-object ((n node) stream)
  (format stream "#<~A :SRC ~A :DATA ~A :CHILDREN ~A>"
          (class-name (class-of n))
          (node-src n)
          (node-data n)
          (node-children n)))

(defclass number-node (node) ())
(defclass string-node (node) ())
(defclass string-container-node (node) ())
(defclass binary-operation-node (node) ())
(defclass identifier-node (node) ())
(defclass varname-node (node) ())
(defclass assignment-node (node) ())
(defclass expressions-node (node) ())

(defclass function-definition-node (node) ())
(defclass lambda-node (node) ())
(defclass function-parameter-node (node) ())
(defclass function-parameters-node (node) ())
(defclass function-argument-node (node) ())
(defclass function-arguments-node (node) ())
(defclass function-call-node (node) ())

(defclass incompilable-node (node) ())
(defclass comment-node (incompilable-node) ())
(defclass end-node (incompilable-node) ())

(defclass keyword-node (node) ())

(defclass list-node (node) ())
(defclass splice-node (node) ())
(defclass list-concat-node (node) ())
(defclass getattr-node (node) ())
(defclass getitem-node (node) ())

(defun make-binop-node (ls)
  (let ((result (first ls)))
    (loop
       for (op expr) in (second ls)
       do (setq result (make-instance 'binary-operation-node :data (second op) :children (list result expr))))
    result))

(defun process-possible-splice (node)
  (if (some #'(lambda (x) (typep x 'splice-node)) (node-children node))
      (make-instance
       'list-concat-node
       :children
       (mapcar #'(lambda (x)
                   (if (typep x 'splice-node)
                       (first (node-children x))
                       (make-instance 'list-node :children (list x))))
               (node-children node)))
      node))


(defun make-human-position (position)
  (let ((line (loop
                 for p across *source-file-positions*
                 for line from 0
                 if (or (eq line (1- (length *source-file-positions*)))
                        (> (elt *source-file-positions* (1+ line)) position)) return line)))
    (format nil "~A:~A:~A" *source-file-name* (1+ line) (1+ (- position (elt *source-file-positions* line))))))

(define-symbol-macro %std-src (list 'list (make-human-position start) (make-human-position end)))

(defrule comment (and #\# (* (and (! #\Newline) character)))
  (:lambda (list &bounds start end)
    (declare (ignore list))
    (make-instance 'comment-node :src %std-src)))

(defrule end (and "END" #\Newline (* (string 1)))
  (:lambda (list &bounds start end)
    (declare (ignore list))
    (make-instance 'end-node :src %std-src)))

(defrule optional-sign (or "+" "-" ""))

(defrule digit (character-ranges (#\0 #\9)))

(defrule digits (+ digit))

(defrule hex-digit (or digit (character-ranges (#\a #\f) (#\A #\F))))

(defrule hex-digits (+ hex-digit))

(defrule inline-space (+ (or #\Space #\Tab)) (:constant nil))

(defrule space (+ (or #\Space #\Tab #\Newline)) (:constant nil))

(defrule newline-space (+ (and (? inline-space) (+ #\Newline) (? inline-space))))

(defrule optional-space (* space) (:constant nil))

(defrule integer (and optional-sign digits) (:lambda (list) (parse-integer (text list) :radix 10)))

(defrule float (and optional-sign digits "." digits) (:lambda (list) (with-input-from-string (s (text list)) (read s))))

(defun make-integer-if-possible (x)
  (multiple-value-bind (result remainder) (floor x)
    (if (zerop remainder)
        result
        x)))

;; Units idea - Thanks to Avishai Ish Shalom
(defrule number (and (or float integer) (? (or #\K #\M #\G)))
  (:lambda (n &bounds start end)
    (make-instance
     'number-node
     :data (make-integer-if-possible (* (first n)
                                        (let ((units (second n)))
                                          ;; (format t "UNITS ~S~%" units)
                                          (cond
                                            ((equal units "K") 1024)
                                            ((equal units "M") (* 1024 1024))
                                            ((equal units "G") (* 1024 1024 1024))
                                            (t 1)))))
     :src %std-src)))

;; http://en.wikipedia.org/wiki/Escape_sequences_in_C
(defparameter *escape-chars*
  '((#\a 7)
    (#\b 8)
    (#\e 27)
    (#\f 12)
    (#\n 10)
    (#\r 13)
    (#\t 9)))

(defun is-escape-char (ch) (assoc ch *escape-chars*))

(defrule string-contents-common-escape (and #\\ (is-escape-char character))
  (:lambda (list)
    (make-instance 'string-node :data (text (code-char (second (assoc (second list) *escape-chars*)))))))

(define-symbol-macro %code-char (make-instance 'string-node :data (text (code-char (parse-integer (text (cddr list)) :radix 16)))))
(defrule string-contents-common-x (and #\\ #\x hex-digit hex-digit) (:lambda (list) %code-char))
(defrule string-contents-common-u (and #\\ #\u hex-digit hex-digit hex-digit hex-digit) (:lambda (list) %code-char))
(defrule string-contents-common-cap-u (and #\\ #\U
                                           hex-digit hex-digit hex-digit hex-digit
                                           hex-digit hex-digit hex-digit hex-digit) (:lambda (list) %code-char))

(defrule string-contents-common (or
                                 string-contents-common-escape
                                 string-contents-common-x
                                 string-contents-common-u
                                 string-contents-common-cap-u))

(defrule string-contents-var (and "$" varname)
  (:lambda (list)
    ;; (format t "string-contents-var: ~S~%" list)
    (second list)))

(defrule string-contents-expression (and "${" expression "}")
  (:lambda (list)
    (second list)))

(defun not-single-quote (x) (not (eq x #\')))
(defun not-double-quote (x) (not (eq x #\")))

(defrule not-double-quote (not-double-quote character)
  (:lambda (list)
    (make-instance 'string-node :data (text list))))

(defrule string-contents-dq (+ (or
                                string-contents-var
                                string-contents-expression
                                string-contents-common
                                not-double-quote)))

(defrule string-dq (and #\" (* string-contents-dq) #\")
  (:lambda (list &bounds start end) (make-instance 'string-container-node :children (first (second list)) :src %std-src)))

(defrule string (or string-dq))

(defrule letters (character-ranges (#\a #\z) (#\A #\Z)) (:lambda (list) (text list)))

(defrule identifier-first (+ (or letters "_")))

(defrule identifier-rest (* (or identifier-first digits)))

(defrule identifier-whole-text (and identifier-first identifier-rest)
  (:lambda (list) (text list)))

(defrule identifier-immediate identifier-whole-text
  (:lambda (list &bounds start end)
    (make-instance 'string-node :data list :src %std-src)))

(defrule identifier (or identifier-immediate))

(defrule expression (or comment end function-definition lambda binary-expression-1))

(defrule varname identifier-whole-text
  (:lambda (list &bounds start end)
    (make-instance 'varname-node :data list :src %std-src)))

(defun %bin-expr (n)
  (intern (concatenate 'string "BINARY-EXPRESSION-" (write-to-string n))))

(defmacro define-binary-operations-rules ()
  `(progn
     ,@(loop
          for binary-operator in *binary-operators*
          for i from 1
          collecting
          ;; http://en.wikipedia.org/wiki/Operator-precedence_parser
            `(defrule ,(%bin-expr i) (and ,(%bin-expr (1+ i)) (* (and ,binary-operator ,(%bin-expr (1+ i)))))
               (:lambda (list)
                 (make-binop-node list))))
     (defrule ,(%bin-expr (1+ (length *binary-operators*))) non-binary-operation
       (:lambda (list) list))))

(defrule expressions (and expression (* (+ (and expressions-delimiter expression))) optional-space (* ";"))
  (:lambda (list)
    (make-instance 'expressions-node :children (append (list (first list)) (mapcar #'second (caadr list))))))

(defrule expressions-delimiter (or newline-space (and (? inline-space) ";" (? space))))

(defmacro defrule-spaced-seq (name seq &body body)
  `(defrule
       ,name
       (and ,@(butlast (loop
                          for item in seq
                          for i from 0
                          collecting item
                          if (not (eq 'space (nth (1+ i) seq))) collecting 'optional-space)))
     ,@body))


(defrule function-parameter (and
                             (? (or "**" "*"))
                             identifier
                             optional-space
                             (? (and optional-space ":" optional-space varname))
                             (? (and optional-space "=" optional-space expression)))
  (:lambda (list)
    (make-instance 'function-parameter-node
                   :data (list
                          (cond ((equal "*"  (first list)) 'positional-rest)
                                ((equal "**" (first list)) 'named-rest)
                                (t 'regular)))
                   :children (list
                              (second list)
                              (fourth (fourth list))
                              (fourth (fifth list))))))

(defrule function-parameters (? (and function-parameter (* (and optional-space "," optional-space function-parameter optional-space))))
  (:lambda (list)
    ;; (format t "~%WTF1: ~S~%" (make-instance 'function-parameters-node :children (append (list (first list)) (mapcar #'fourth (cadr list)))))
    (make-instance 'function-parameters-node :children (when list (append (list (first list)) (mapcar #'fourth (cadr list)))))))


(defrule-spaced-seq function-parameters-with-parens ("(" function-parameters ")") (:lambda (list) (third list)))

(defrule-spaced-seq function-definition ((or "defg" "def") space identifier function-parameters-with-parens "{" (? expressions) "}")
  (:lambda (list)
    (make-instance 'function-definition-node
                   :data (list (equal "defg" (first list)))
                   :children (list
                              (fourth list)
                              (sixth list)
                              (tenth list)))))

(defrule lambda (and (or "F" "lambda") (? (and space identifier)) optional-space function-parameters-with-parens optional-space "{" optional-space (? expressions) optional-space "}")
  (:lambda (list)
    (make-instance 'lambda-node
                   :children (list
                              (second (second list))
                              (fourth list)
                              (eighth list)))))

(define-binary-operations-rules)

(defrule assignment (and (? (and "global" space)) identifier optional-space "=" optional-space expression)
  (:lambda (list)
    (make-instance 'assignment-node
                   :data (not (not (first list)))
                   :children (list (second list) (sixth list)))))

;; TODO: named arguments
(defrule function-argument (or
                            (and identifier optional-space "=" optional-space expression)
                            expression)
  (:lambda (list)
    ;; (format t "ARG: ~S~%" list)
    (make-instance 'function-argument-node :children (list list))))


;; TODO: named arguments
(defrule function-arguments (? (and function-argument (* (and optional-space "," optional-space function-argument optional-space))))
  (:lambda (list)
    ;; (format t "ARGS: ~S~%" list)
    (make-instance 'function-arguments-node :children (when list (append (list (first list)) (mapcar #'fourth (cadr list)))))))

(defrule-spaced-seq function-call (expression "(" function-arguments ")")
  (:lambda (list &bounds start end)
    (make-instance 'function-call-node :children (list (first list) (fifth list)) :src %std-src)))

(defrule true  "true"  (:constant (make-instance 'keyword-node :data :true)))
(defrule false "false" (:constant (make-instance 'keyword-node :data :false)))
(defrule null  "null"  (:constant (make-instance 'keyword-node :data :null)))

(defrule list (and "[" optional-space (? (and expression (* (and optional-space "," optional-space expression optional-space)))) optional-space "]")
  (:lambda (list &bounds start end)
    (process-possible-splice
     (make-instance 'list-node
                    :children (when (first (third list)) (append (list (first (third list))) (mapcar #'fourth (second (third list)))))
                    :src %std-src))))

(defrule splice (and "*" optional-space expression)
  (:lambda (list &bounds start end)
    (make-instance 'splice-node
                   :children (list (third list))
                   :src %std-src)))

(defrule non-binary-operation (or chain))

(defrule chain (and non-chain (* chain-item))
  (:lambda (list)
    (let ((result (first list)))
      (loop for n in (second list)
         do (nsubst result :arg (second n))
         do (setq result (first n)))
      result)))

(defrule chain-item (or
                     chain-item-dot-call
                     chain-item-getattr
                     chain-item-getitem))

(defrule chain-item-dot-call (and "." varname optional-space "(" function-arguments ")")
  (:lambda (list &bounds start end)
    (let*
        ((args (fifth list))
         (target-list (list :arg)))
      (setf (node-children args) (cons (make-instance 'function-argument-node :children target-list) (node-children args)))
      (list
       (make-instance 'function-call-node :children (list (second list) args) :src %std-src)
       target-list))))

(defrule chain-item-getattr (and "." identifier)
  (:lambda (list &bounds start end)
    (let ((target-list (list :arg (second list))))
      (list
       (make-instance 'getattr-node :children target-list :src %std-src)
       target-list))))

(defrule chain-item-getitem (and optional-space "[" optional-space expression optional-space "]")
  (:lambda (list &bounds start end)
    (let ((target-list (list :arg (fourth list))))
      (list
       (make-instance 'getitem-node :children target-list :src %std-src)
       target-list))))


(defrule non-chain (or
                    assignment
                    function-call
                    number
                    string
                    true
                    false
                    null
                    list
                    splice
                    varname))

;; Parser - end ------------------------------

;; Variables - start ------------------------------

(defclass lexical-scopes ()
  ((hashes
    :initform (list (make-hash-table :test #'equal :size 100))
    :initarg :hashes
    :accessor lexical-scopes-hashes)))

(defmethod print-object ((ls lexical-scopes) stream)
  (format stream "#<LEXICAL-SCOPES ~S>"
          (loop
             for hash in (lexical-scopes-hashes ls)
             collecting
               (loop
                  for key being the hash-keys of hash
                  collecting (list key (gethash key hash))))))

(defvar *ngs-globals* (make-instance 'lexical-scopes))
(defvar *source-position* nil)

(defun one-level-deeper-lexical-vars (ls)
  (make-instance 'lexical-scopes :hashes (cons (make-hash-table :test #'equal :size 20) (lexical-scopes-hashes ls))))

(defun get-var (name vars &optional (include-top-level t))
  ;; (format t "GET ~S~%" name)
  (loop for hash in (if include-top-level
                        (lexical-scopes-hashes vars)
                        (butlast (lexical-scopes-hashes vars)))
     do (multiple-value-bind (result found) (gethash name hash)
          (when found (return-from get-var (values result hash)))))
  (error 'variable-not-found :varname name :stack-trace *source-position*))

(defun get-var-or-default (name vars default)
  (handler-case (get-var name vars)
    (variable-not-found () default)))

(defun set-var (name vars value &optional (global t))
  ;; (format t "SET ~S=~S~%" name value)
  (let ((dst-hash
         (handler-case (multiple-value-bind (unused-result hash) (get-var name vars global)
                         (declare (ignore unused-result))
                         hash)
           (variable-not-found ()
             (if global
                 (first (last (lexical-scopes-hashes vars)))
                 (first (lexical-scopes-hashes vars)))))))
    (setf (gethash name dst-hash) value)))

(defun set-local-var (name vars value) (set-var name vars value nil))

(defun %set-global-variable (name value)
  ;; (format t "X ~S ~%" (last (lexical-scopes-hashes *ngs-globals*)))
  (setf (gethash name (first (lexical-scopes-hashes *ngs-globals*))) value))

;; Variables - end ------------------------------


;; Types definitions - start ------------------------------

(defstruct ngs-type name parents constructors predicate)

(defmethod print-object ((typ ngs-type) stream)
  (format stream "#<ngs-type ~A>" (ngs-type-name typ)))

(defun %ngs-type-symbol (type-name)
  (intern (concatenate 'string "NGS-TYPE-" (string-upcase type-name))))

(defmacro def-ngs-type (name predicate)
  (let*
      ((symb (%ngs-type-symbol name)))
    `(progn
       (defvar ,symb
         (make-ngs-type :name ,name :predicate ,predicate))
       (%set-global-variable ,name ,symb))))

;; (def-ngs-type "Any"    #'(lambda (x) (declare (ignore x)) t))
(def-ngs-type "Type"   #'ngs-type-p)
(def-ngs-type "Number" #'numberp)
(def-ngs-type "String" #'stringp)
(def-ngs-type "List"   #'listp)
(def-ngs-type "Array"  #'arrayp)
(def-ngs-type "Null"   #'(lambda (x) (eq x :null)))
(def-ngs-type "Bool"   #'(lambda (x) (or (eq x :true) (eq x :false))))

;; Types definitions - end ------------------------------

;; Compiler - start ------------------------------

(defgeneric generate-code (node))

(define-symbol-macro %1 (generate-code (first (node-children n))))
(define-symbol-macro %2 (generate-code (second (node-children n))))
(define-symbol-macro %children (children-code n))
(define-symbol-macro %data (node-data n))

(defun children-code (node &key (start 0))
  (mapcar #'generate-code
          (remove-if #'(lambda (x) (typep x 'incompilable-node))
                     (subseq (node-children node) start))))

(defun generate-expected-parameters (n)
  `(list
    ,@(mapcar
       #'(lambda(x) `(list ,@(apply #'list (mapcar #'generate-code (node-children x)))))
       (node-children n))))

;; TODO :src
(defun string-container-children-optimize (list)
  (if list
      (let ((p (position-if-not #'(lambda (x) (typep x 'string-node)) list)))
        (if (eq 0 p)
            (cons
             (first list)
             (string-container-children-optimize (rest list)))
            (cons
             (make-instance 'string-node :data (apply #'concatenate 'string (mapcar #'(lambda (x) (node-data x)) (subseq list 0 p))))
             (subseq list (or p (length list))))))
      nil))

(defun make-function-call-node (fname positionals)
  (make-instance
   'function-call-node
   :children (list
              (make-instance 'varname-node :data fname)
              (make-instance 'function-arguments-node :children (mapcar #'(lambda (x) (make-instance 'function-argument-node :children (list x))) positionals)))
   :src (node-src (first positionals))))

(defun wrap-with-call-to-string (n)
  (if (typep n 'string-node)
      n
      (make-function-call-node "String" (list n))))

;; For simplicity of generate-expected-parameters, which has nullable fields in each parameter

(defmethod generate-code ((n null))                      nil)

(defmethod generate-code ((n number-node))               %data)
(defmethod generate-code ((n string-node))               %data)
(defmethod generate-code ((n varname-node))             `(get-var ,%data vars))
(defmethod generate-code ((n binary-operation-node))    `(ngs-call-function
                                                          (get-var ,%data vars)
                                                          (make-arguments :positional (list ,@(children-code n)))))
(defmethod generate-code ((n assignment-node))          `(set-var
                                                          ,(node-data (first (node-children n)))
                                                          vars
                                                          ,@(children-code n :start 1)
                                                          ,(node-data n)))
(defmethod generate-code ((n expressions-node))         `(progn ,@%children))

(defmethod generate-code ((n function-definition-node)) `(let ((expected-parameters ,(generate-expected-parameters (second (node-children n)))))
                                                           (ngs-define-function
                                                            ,%1
                                                            vars
                                                            ,(first %data)
                                                            ;; expected-parameters
                                                            (lambda (parameters)
                                                              (let ((vars (one-level-deeper-lexical-vars vars)))
                                                                ,@(children-code n :start 1))))))

(defmethod generate-code ((n lambda-node))              `(let ((expected-parameters ,(generate-expected-parameters (second (node-children n)))))
                                                            (lambda (parameters)
                                                              (let ((vars (one-level-deeper-lexical-vars vars)))
                                                                ,@(children-code n :start 1)))))

;; 1. match the parameters and signal if there is a mismatch
;; 2. set local variables
;; 3. do it smarter and more efficient
(defmethod generate-code ((n function-parameters-node)) `(progn
                                                           ,(when
                                                             (notany
                                                              #'(lambda (p) (eq (first (node-data p)) 'positional-rest))
                                                              (node-children n))
                                                             `(when (> (length (arguments-positional parameters)) ,(length (node-children n)))
                                                                (error 'parameters-mismatch)))
                                                           ,@(loop
                                                                for p in (node-children n)
                                                                for pc = (node-children p)
                                                                for i from 0
                                                                collecting
                                                                  (cond
                                                                    ((eq (first (node-data p)) 'positional-rest)
                                                                     `(set-local-var
                                                                       (first (nth ,i expected-parameters))
                                                                       vars
                                                                       (subseq (arguments-positional parameters) ,i)))
                                                                    (t
                                                                     `(set-local-var (first (nth ,i expected-parameters)) vars
                                                                                     (if
                                                                                      (> (length (arguments-positional parameters)) ,i)
                                                                                      (guard-type
                                                                                       (nth ,i (arguments-positional parameters))
                                                                                       (second (nth ,i expected-parameters)))
                                                                                      ,(if (third pc)
                                                                                           `(third (nth ,i expected-parameters))
                                                                                           `(error 'parameters-mismatch)))))))))

(defmethod generate-code ((n function-call-node))       `(ngs-call-function ,%1 ,%2))
;; TODO: support named arguments
(defmethod generate-code ((n function-arguments-node))  `(make-arguments
                                                          :positional
                                                          ,(generate-code
                                                            (process-possible-splice
                                                             (make-instance 'list-node
                                                                            :children (mapcar #'(lambda (a) (first (node-children a))) (node-children n)))))))

(defmethod generate-code ((n keyword-node))             %data)
(defmethod generate-code ((n list-node))                `(list ,@%children))
(defmethod generate-code ((n list-concat-node))         `(concatenate 'list ,@%children))

(defmethod generate-code ((n string-container-node))    (if (null (node-children n))
                                                            ""
                                                            (let* ((children (string-container-children-optimize (node-children n)))
                                                                   (stringified-children (mapcar #'wrap-with-call-to-string children)))
                                                              (if (eq 1 (length stringified-children))
                                                                  (generate-code (first stringified-children))
                                                                  `(apply #'concatenate (list 'string ,@(mapcar #'generate-code stringified-children)))))))

(defmethod generate-code ((n getattr-node))             `(ngs-call-function
                                                          (get-var "__get_attr" vars)
                                                          (make-arguments :positional (list ,@(children-code n)))))

(defmethod generate-code ((n getitem-node))             `(ngs-call-function
                                                          (get-var "__get_item" vars)
                                                          (make-arguments :positional (list ,@(children-code n)))))

;; GENERATE MARKER

(defmethod generate-code :around ((n node))
  `(let ((*source-position* (cons ,(or (node-src n) "<unknown>") *source-position*)))
     ,(call-next-method)))

(defun make-source-file-positions (code)
  "Positions where lines start"
  (apply #'vector 0 (loop
                     for char across code
                     for position from 0
                     if (eq #\Newline char) collecting (1+ position))))

(defun ngs-compile (code file-name)
  (let* ((*source-file-name* file-name)
         (*source-file-positions* (make-source-file-positions code))
         (c (generate-code (parse 'expressions code))))
    `(let ((vars *ngs-globals*))
       (handler-case ,c
         (runtime-error (e) (format t "Run-time error: ~A~%Stack: ~S" e (runtime-error-stack-trace e)))))))

;; Compiler - end ------------------------------

;; Runtime - start ------------------------------

(define-condition runtime-error () ((stack-trace :initarg :stack-trace :initform nil :reader runtime-error-stack-trace)))
(define-condition variable-not-found (runtime-error) ((varname :initarg :varname :reader variable-not-found-varname)))
(define-condition method-implementatoin-not-found (runtime-error) ())
(define-condition calling-non-a-method (runtime-error) ())
(define-condition parameters-mismatch () ())

(defmethod print-object ((e variable-not-found) stream)
  (format stream "Variable '~A' not found" (variable-not-found-varname e)))

;; TODO: check parents
(defun ngs-value-is-of-type (val typ)
  (or (null typ) (funcall (ngs-type-predicate typ) val)))

(defun guard-type (val typ)
  (unless (ngs-value-is-of-type val typ)
    (error 'parameters-mismatch))
  val)

(defun guard-equalp (v1 v2)
  (unless (equalp v1 v2)
    (error 'parameters-mismatch))
  v1)


(defun hash-keys (h)
  (loop for key being the hash-keys of h
     collecting key))

;; XXX - some issues, probably global/local
(defun ngs-define-function (function-name vars global lambda)
  (let ((v (get-var-or-default function-name vars nil)))
    (if (typep v 'ngs-type)
        (setf (ngs-type-constructors v) (cons lambda (ngs-type-constructors v)))
        (set-var function-name vars (cons lambda v) global))))

;; TODO - handle parameters-mismatch
(defun ngs-call-function (methods arguments)
  ;; (format t "METHODS: ~S~%" methods)
  (cond
    ((typep methods 'ngs-type) (ngs-call-function (ngs-type-constructors methods) arguments))
    ((functionp methods) (ngs-call-function (list methods) arguments))
    ((listp methods)
     ;; TODO: check that at least the first element is callable
     (progn
       (loop for m in methods
          ;; do (format t "+ Trying implementation ~A~%" m)
          do (handler-case (return-from ngs-call-function (funcall m arguments))
               (parameters-mismatch () nil)))
       (error 'method-implementatoin-not-found)))
    (t
     (error 'calling-non-a-method))))

;; (handler-case (get-var name vars)
;;     (variable-not-found () default)))

(define-symbol-macro %positionals (arguments-positional parameters))
(define-symbol-macro %p1 (first %positionals))
(define-symbol-macro %p2 (second %positionals))

(defmacro native (name &body body)
  `(ngs-define-function
    ,name *ngs-globals*
    t
    (lambda (parameters)
      (let* ((source-position (format nil "<builtin:~A>" ,name))
             (*source-position* (cons (list source-position source-position) *source-position*)))
      ,@body))))

(defmacro all-positionals (typ)
  `(loop for p in %positionals do (guard-type p ,typ)))

(defmacro native-getattr (typ &body body) `(native "__get_attr"
                                             (guard-type %p1 ,typ)
                                             (cond
                                             ,@(loop
                                                  for clause in body
                                                  collecting `((equalp %p2 ,(first clause)) ,(second clause))))))

(defmacro %call (name parameters)
  `(ngs-call-function (get-var ,name *ngs-globals*) ,parameters))

(native "+" (all-positionals ngs-type-number) (apply #'+ %positionals))
(native "+" (all-positionals ngs-type-string) (apply #'concatenate 'string %positionals))
(native "__get_item" (nth (guard-type %p2 ngs-type-number) (guard-type %p1 ngs-type-list)))
(native "__get_item" (let ((pos (guard-type %p2 ngs-type-number)))
                            (subseq (guard-type %p1 ngs-type-string) pos (1+ pos))))


(native "String" (format nil "~A" %p1))

(native "echo"
  (let ((v (%call "String" parameters)))
    (format t "~A~%" v)
    v))

(native-getattr ngs-type-type
  ("name" (ngs-type-name %p1))
  ("constructors" (ngs-type-constructors %p1)))

;; Runtime - end ------------------------------

(defun get-argv ()
  "Abstraction layer for ARGV"
  sb-ext:*posix-argv*)

(defun file-string (path)
  "http://rosettacode.org/wiki/Read_entire_file#Common_Lisp"
  (with-open-file (stream path)
    (let ((data (make-string (file-length stream))))
      (read-sequence data stream)
      data)))