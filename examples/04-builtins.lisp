#| 04-builtins.lisp — The five built-in tools in action.

sexpr ships with five built-in tools, each a plain Lisp function wearing
metadata:
  read-file   :fs-read    Read a file's contents
  write-file  :fs-write   Write text to a file
  edit-file   :fs-write   Replace the first occurrence of old text
  shell       :process    Run a shell command with a timeout
  lisp        :lisp-eval  Eval source in a sandboxed environment

The builtins are not exported from :sexpr.tools — call them via perform-tool,
which is how the kernel dispatches tool calls in the agent loop.

Run:
  sbcl --load ~/.sbclinit --load examples/04-builtins.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.tools)

(format t "=== 04-builtins.lisp ===~%")
(format t "~%")

;; Helper: call a tool via perform-tool
(defun call-tool (name args &rest caps)
  (perform-tool (list :name name :arguments args)
                :capabilities (append (first caps) '(:fs-read :fs-write :process :lisp-eval))))

;; 1. write-file
(format t "-- write-file --~%")
(let ((tmp "/tmp/sexpr-example-1.txt"))
  (format t "~a~%" (call-tool "write-file"
                               (list :path tmp :content "Hello, sexpr!")))
  (format t "file exists: ~a~%" (uiop:file-exists-p tmp)))

;; 2. read-file
(format t "~%-- read-file --~%")
(format t "~a~%" (call-tool "read-file" (list :path "/tmp/sexpr-example-1.txt")))

;; 3. edit-file
(format t "~%-- edit-file --~%")
(let ((tmp "/tmp/sexpr-example-2.txt"))
  (call-tool "write-file" (list :path tmp :content "The quick brown fox jumps over the lazy dog."))
  (format t "~a~%" (call-tool "edit-file"
                               (list :path tmp :old "quick" :new "slow")))
  (format t "after edit: ~a~%" (call-tool "read-file" (list :path tmp))))

;; 4. shell
(format t "~%-- shell --~%")
(let ((result (call-tool "shell" (list :command "echo 'Hello from shell' && echo 'error' >&2; exit 0"))))
  (format t "stdout:    ~a~%" (getf result :stdout))
  (format t "stderr:    ~a~%" (getf result :stderr))
  (format t "exit-code: ~a~%" (getf result :exit-code)))

;; 5. shell with timeout
(format t "~%-- shell (timeout) --~%")
(let ((result (call-tool "shell" (list :command "sleep 5" :seconds 1.0))))
  (format t "timed-out: ~a~%" (getf result :timed-out))
  (format t "stdout:    ~a~%" (getf result :stdout)))

;; 6. lisp (sandboxed eval)
(format t "~%-- lisp --~%")
(format t "~a~%" (call-tool "lisp" (list :source "(+ 1 2 3)")))
(format t "~a~%" (call-tool "lisp" (list :source "(list :a :b :c)")))
(format t "~a~%" (call-tool "lisp"
                             (list :source "(defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)")))

;; 7. lisp with refusal
(format t "~%-- lisp (refusal) --~%")
(format t "~a~%" (call-tool "lisp" (list :source "#.(+ 1 2) ")))
(format t "~a~%" (call-tool "lisp" (list :source "(undefined-function 1 2)")))
(format t "~a~%" (call-tool "lisp" (list :source "(loop)" :seconds 1.0)))

;; 8. Cleanup
(uiop:delete-file-if-exists "/tmp/sexpr-example-1.txt")
(uiop:delete-file-if-exists "/tmp/sexpr-example-2.txt")

(format t "~%=== done ===~%")
