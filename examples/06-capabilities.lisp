#| 06-capabilities.lisp — The capability gate: grants and denials.

Each tool declares a capability requirement (:fs-read, :fs-write,
:process, or :lisp-eval). The gate checks the granted capability set
before dispatching. A denied call signals tool-error with :capability-denied.

Run:
  sbcl --load ~/.sbclinit --load examples/06-capabilities.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.tools)

(format t "=== 06-capabilities.lisp ===~%")
(format t "~%")

;; 1. Show the built-in tools and their capabilities
(format t "-- Tool capabilities --~%")
(dolist (record (all-tools))
  (format t "~a: ~a~%"
          (getf record :name)
          (getf record :capability)))

;; 2. Successful call: capability granted
(format t "~%-- Successful call (capability granted) --~%")
(let ((result (perform-tool
               (list :name "read-file"
                     :arguments (list :path "/etc/hostname"))
               :capabilities '(:fs-read))))
  (format t "result: ~a~%" (type-of result)))

;; 3. Denied call: capability not granted
(format t "~%-- Denied call (capability not granted) --~%")
(handler-case
    (perform-tool
     (list :name "write-file"
           :arguments (list :path "/tmp/test.txt" :content "hello"))
     :capabilities '(:fs-read))   ;; only fs-read granted; write-file needs fs-write
  (tool-error (err)
    (format t "denied!~%")
    (format t "  tool:   ~a~%" (tool-error-tool err))
    (format t "  reason: ~a~%" (tool-error-reason err))
    (format t "  detail: ~a~%" (tool-error-detail err))))

;; 4. Unknown tool
(format t "~%-- Unknown tool --~%")
(handler-case
    (perform-tool
     (list :name "nonexistent-tool"
           :arguments (list :foo "bar"))
     :capabilities '(:fs-read))
  (tool-error (err)
    (format t "error!~%")
    (format t "  tool:   ~a~%" (tool-error-tool err))
    (format t "  reason: ~a~%" (tool-error-reason err))
    (format t "  detail: ~a~%" (tool-error-detail err))))

;; 5. Argument validation error
(format t "~%-- Argument validation error --~%")
(handler-case
    (perform-tool
     (list :name "read-file"
           :arguments (list :path "x" :unknown "y"))   ;; extra argument
     :capabilities '(:fs-read))
  (tool-error (err)
    (format t "error!~%")
    (format t "  tool:   ~a~%" (tool-error-tool err))
    (format t "  reason: ~a~%" (tool-error-reason err))
    (format t "  detail: ~a~%" (tool-error-detail err))))

;; 6. Each capability type
(format t "~%-- Capability types --~%")
(let ((caps '(:fs-read :fs-write :process :lisp-eval)))
  (format t "All four capabilities: ~a~%" caps)
  (dolist (cap caps)
    (let* ((tool-name
             (case cap
               (:fs-read "read-file")
               (:fs-write "write-file")
               (:process "shell")
               (:lisp-eval "lisp")))
           (record (find-tool tool-name)))
      (format t "  ~a -> ~a (capability: ~a)~%"
              cap tool-name (getf record :capability)))))

;; 7. check-capability directly
(format t "~%-- check-capability --~%")
(let ((record (find-tool "read-file")))
  (format t "fs-read granted?    ~a~%"
          (check-capability record '(:fs-read)))
  (format t "no caps granted?    ~a~%"
          (handler-case
              (check-capability record '())
            (tool-error () :denied))))

(format t "~%=== done ===~%")
