#|
  This file is a part of cl-elastic.
  (c) 2019 Finn Völkel
  Author: Finn Völkel  (firstname.lastname@gmail.com)
|#

(defpackage cl-elastic
  (:use :cl)
  (:nicknames :elastic)
  (:import-from :drakma
                :http-request
                :*text-content-types*)
  (:import-from :named-readtables
                :defreadtable)
  (:import-from :yason
                :encode
                :parse
                :with-output-to-string)
  (:export :<client>
           :endpoint
           :user
           :password
           :send-request
           :*enable-keywords*
           :enable-hashtable-syntax
           :disable-hashtable-syntax
           :hashtable-syntax))

(in-package :cl-elastic)

(defvar *enable-keywords* nil
  "If set to a true value, keywords will be transformed to strings in JSON
objects and read back as keywords.")

(defclass <client> ()
  ((endpoint :initarg :endpoint
             :initform "http://localhost:9200"
             :reader endpoint)
   (user :initarg :user
         :initform nil
         :reader user)
   (password :initarg :password
             :initform nil
             :reader password)))

(defun parse-uri (uri)
  "Parses a URI in form of a string, keyword or list."
  (typecase uri
    (string (format nil "/~A" uri))
    (keyword (format nil "/~A" (keyword-downcase uri)))
    (list (reduce (lambda (res uri)
                    (format nil "~A~A" res (parse-uri uri)))
                  uri :initial-value ""))
    (t (format nil "/~A" uri))))

(defun create-uri (client uri)
  (format nil "~A~A" (endpoint client) (parse-uri uri)))

(defun concat-with-newlines (strings)
  "Concats STRINGS with newlines. Ends in a newline."
  (format nil "~A~%"
   (reduce (lambda (res x) (format nil "~A~%~A" res x)) strings)))

(defun encode-json (data)
  "Transforms a lisp object into a JSON object in string form. A list is
transformed into the newline seperated concatenation of JSON objects."
  (typecase data
    (null nil)
    (list (concat-with-newlines (mapcar #'encode-json data)))
    (T (with-output-to-string (s)
         (yason:encode (if *enable-keywords* (keywords-to-strings data) data) s)))))

(defun send-request (client uri &key (method :get) data parameters)
  "Sends a request to an Elasticsearch client."
  (assert (eq (type-of client) '<client>))
  (let ((*text-content-types*
         '(("application" . "json")))
        (uri (create-uri client uri))
        (yason:*parse-object-key-fn* (if *enable-keywords* #'make-keyword #'identity))
        (data (encode-json data))
        (parameters (if *enable-keywords*
                        (mapcar (lambda (p) (cons (keywords-to-strings (car p)) (cdr p)))
                                parameters)
                        parameters)))
    (multiple-value-bind (body status headers uri stream closep reason)
        (http-request uri
                      :method method
                      :content data
                      :content-type "application/json"
                      :external-format-in :utf-8
                      :external-format-out :utf-8
                      :parameters parameters
                      :want-stream T)
      (declare (ignore headers uri stream reason))
      (unwind-protect
           (if (= status 400)
               (let ((error-message
                      (gethash (if *enable-keywords* :error "error") (parse body))))
                 (error (cond
                          ((equal (type-of error-message) 'hash-table)
                           (format nil "~A" error-message))
                          (T error-message))))
               ;; (error (gethash (if *enable-keywords* :error "error") (yason:parse body)))
               (values (yason:parse body) status))
        (when closep
          (close body))))))

;; utility functions

(defun make-keyword (name)
  "Creates a keyword symbol for a given string NAME."
  (values (intern (string-upcase name) "KEYWORD")))

(defun keyword-downcase (keyword)
  (string-downcase (string keyword)))

(defun keywords-to-strings (x)
  (typecase x
    (hash-table (progn
                  (maphash (lambda (k v)
                             (let ((newv (keywords-to-strings v)))
                               (if (eq (type-of k) 'keyword)
                                   (progn
                                     (remhash k x)
                                     (setf (gethash (keyword-downcase k) x) newv))
                                   (setf (gethash k x) newv))))
                           x)
                  x))
    (list (mapcar #'keywords-to-strings x))
    ;; o/w strings get transformed into vectors
    (string x)
    (vector (map 'vector #'keywords-to-strings x))
    (keyword (keyword-downcase x))
    (t x)))

;; new hashtable syntax
(define-condition odd-number-of-forms (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "Hashmap literal must contain an even number of forms."))))

(defun |#{-reader-}| (stream char arg)
  (declare (ignore char) (ignore arg))
  (let ((*readtable* (copy-readtable *readtable* nil)))
    (set-macro-character #\} (get-macro-character #\)))
    (let ((contents (read-delimited-list #\} stream t)))
      (when (oddp (length contents)) (error 'odd-number-of-forms))
      (let ((pairs (if contents
                       (loop for pairs = contents then (cddr pairs)
                          collect (list (car pairs) (cadr pairs))
                          while (cddr pairs))
                       '()))
            (res (gensym)))
        `(let ((,res (make-hash-table :test #'equal)))
           ,@(mapcar
              (lambda (pair)
                `(setf (gethash ,(car pair) ,res) ,(cadr pair)))
              pairs)
           ,res)))))

(defvar *previous-readtables* nil)

(defmacro enable-hashtable-syntax ()
  '(eval-when (:compile-toplevel :load-toplevel :execute)
    (push *readtable* *previous-readtables*)
    (setq *readtable* (copy-readtable))
    (set-dispatch-macro-character #\# #\{ #'|#{-reader-}|)
    (values)))

(defmacro disable-hashtable-syntax ()
  '(eval-when (:compile-toplevel :load-toplevel :execute)
    (setq *readtable* (pop *previous-readtables*))
    (values)))

(defreadtable hashtable-syntax
  (:merge :standard)
  (:macro-char #\# :dispatch)
  (:dispatch-macro-char #\# #\{ #'|#{-reader-}|))

#-lispworks
(handler-bind (#+sbcl(sb-kernel:redefinition-with-defmethod #'muffle-warning))
  (defmethod print-object ((object hash-table) stream)
    (if (= (hash-table-count object) 0)
        (format stream "#{}")
        (let ((data (loop for k being the hash-keys of object
                       for v being the hash-values of object
                       for res = (format nil "~S ~S" k v)
                       then (format nil "~A ~S ~S" res k v)
                       finally (return res))))
          (format stream "#{~A}" data)))))
