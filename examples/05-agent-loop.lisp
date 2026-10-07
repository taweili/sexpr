#| 05-agent-loop.lisp — The agent loop with a mock provider.

The agent loop is the core of sexpr: model-step asks the model, integrate
folds the answer into the transcript, dispatch-tool-call runs any tool
calls, and the loop repeats until the model says :finish.

This example uses a mock provider (a simple function that returns canned
responses) so it runs without a real model endpoint. To use a real model,
see the comment at the bottom.

Run:
  sbcl --load ~/.sbclinit --load examples/05-agent-loop.lisp
|#

(unless (find-package :ql)
  (load (merge-pathnames "~/.sbclinit" (user-homedir-pathname))))
(ql:quickload "sexpr")

(in-package :sexpr.kernel)

(format t "=== 05-agent-loop.lisp ===~%")
(format t "~%")

;; 1. Define a mock provider
;;    The mock returns canned responses from a queue.
;;    When the queue is empty, it returns :finish :stop.
(defparameter *mock-responses*
  (list
   ;; Turn 1: model replies with a tool call (read-file)
   (list :content nil
         :tool-calls (list
                      (list :id "call_1"
                            :name "read-file"
                            :arguments (list :path "/etc/hostname")))
         :model "mock-model"
         :finish :tool-calls)
   ;; Turn 2: model replies with a tool call (write-file)
   (list :content nil
         :tool-calls (list
                      (list :id "call_2"
                            :name "write-file"
                            :arguments (list :path "/tmp/sexpr-mock.txt"
                                             :content "Hello from mock!")))
         :model "mock-model"
         :finish :tool-calls)
   ;; Turn 3: model is done
   (list :content "Task complete! I read the hostname and wrote a file."
         :tool-calls nil
         :model "mock-model"
         :finish :stop)))

(defun mock-provider-call (endpoint messages &key system tools temperature max-tokens)
  "Return the next canned response from *mock-responses*."
  (declare (ignore endpoint messages system tools temperature max-tokens))
  (pop *mock-responses*))

;; 2. Install the mock provider as a generic method
;;    We override the provider-call generic to use our mock.
;;    The real method calls complete; our mock just returns canned data.
(defmethod sexpr.provider:provider-call ((endpoint t) messages
                                          &key system tools temperature max-tokens)
  (mock-provider-call endpoint messages
                      :system system :tools tools
                      :temperature temperature :max-tokens max-tokens))

;; 3. Create an agent and run the loop
(format t "-- Create agent --~%")
(let ((agent (make-agent
              :goal "Read /etc/hostname and write a greeting file"
              :capabilities '(:fs-read :fs-write :process :lisp-eval))))
  (format t "goal:        ~a~%" (agent-goal agent))
  (format t "capabilities: ~a~%" (agent-capabilities agent))
  (format t "transcript:  ~a events~%" (transcript-length (agent-transcript agent)))

  (format t "~%-- Run agent loop --~%")
  (run-until-finished agent :max-steps 10)

  (format t "~%-- Final transcript (~a events) --~%"
          (transcript-length (agent-transcript agent)))
  (format t "~a" (render-events (agent-transcript agent))))

;; 4. Show the transcript serialization
(format t "~%-- Transcript as s-expression --~%")
(let ((tr (agent-transcript (make-agent
                             :goal "demo"
                             :transcript (make-transcript)))))
  (sexpr.transcript:append-event tr
    (sexpr.transcript:make-user-event "Hello"))
  (sexpr.transcript:append-event tr
    (sexpr.transcript:make-model-event "Hi!" :model "mock" :finish :stop))
  (format t "~a~%" (sexpr.transcript:write-transcript tr)))

;; 5. Budget object
(format t "~%-- Budget --~%")
(let ((b (make-budget :tokens 1000 :seconds 60)))
  (format t "tokens:  ~a~%" (budget-tokens b))
  (format t "seconds: ~a~%" (budget-seconds b))
  (format t "unlimited tokens? ~a~%" (unlimited-p b :kind :tokens))
  (format t "unlimited seconds? ~a~%" (unlimited-p b :kind :seconds)))

(format t "~%=== done ===~%")
