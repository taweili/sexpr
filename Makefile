# SPDX-License-Identifier: GPL-3.0-or-later
# sexpr — build & run targets.
#
#   make hello      Run the sexpr:hello entry point.
#   make test       Run the rove test suite (asdf:test-op).
#   make load       Load the system into an interactive SBCL session.
#   make clean      Remove build artifacts.

SBCL      ?= sbcl
SBCLINIT  ?= $(HOME)/.sbclinit
SYSTEM    := sexpr
CHAT_ARGS ?= --goal "pair programmer"

.PHONY: hello test load build chat verify diagnostic-tool-call diagnostic-live-round test-live clean help

hello:
	$(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--eval '(sexpr:hello)'

test:
	$(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--eval "(asdf:test-system :$(SYSTEM))"

load:
	$(SBCL) --load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--eval '(format t "~&Loaded ~a ~a. Type (sexpr:hello) to run.~%" (sexpr:name) (sexpr:version))'

build: test
	$(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(asdf:load-system "$(SYSTEM)")' \
		--eval '(sexpr.cli:build)'

chat: build
	./sexpr $(CHAT_ARGS)

diagnostic-tool-call:
	SEXPR_PROVIDER=openai-compatible \
	SEXPR_BASE_URL=http://localhost:6969/v1 \
	SEXPR_MODEL=Qwythos-9B-v2 \
	$(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--load tools/diagnostic-tool-call.lisp

diagnostic-live-round:
	SEXPR_PROVIDER=openai-compatible \
	SEXPR_BASE_URL=http://localhost:6969/v1 \
	SEXPR_MODEL=Qwythos-9B-v2 \
	timeout 420 $(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--load tools/diagnostic-live-round.lisp

test-live: build
	@echo '[live] local model round-trip'
	@tmp=$$(mktemp --suffix=.sexp); \
	trap 'rm -f $$tmp /tmp/sexpr-live-readme.txt' EXIT; \
	printf 'hello world from s05\n' > /tmp/sexpr-live-readme.txt; \
	echo "$$(date -u +%H:%M:%S) [1/4] prompting model to read /tmp/sexpr-live-readme.txt"; \
	printf 'Use the read-file tool to read /tmp/sexpr-live-readme.txt, then tell me exactly what it contains.\n/save %s\n/exit\n' $$tmp | \
	SEXPR_PROVIDER=openai-compatible \
	SEXPR_BASE_URL=http://localhost:6969/v1 \
	SEXPR_MODEL=Qwythos-9B-v2 \
	  timeout 420 ./sexpr --goal "You are a terse assistant. Use tools when asked." \
	  > /tmp/sexpr-live-out.txt 2>&1; \
	rc=$$?; \
	echo "$$(date -u +%H:%M:%S) [2/4] sexpr exited $$rc"; \
	echo '=== output ==='; cat /tmp/sexpr-live-out.txt; \
	echo "$$(date -u +%H:%M:%S) [3/4] structural check of saved transcript"; \
	if [ $$rc -ne 0 ]; then echo 'FAIL: sexpr exited non-zero'; exit 1; fi; \
	SEXPR_TRANSCRIPT=$$tmp SEXPR_FIXTURE='hello world from s05' \
	  $(SBCL) --non-interactive \
	    --load $(SBCLINIT) \
	    --eval '(ql:quickload "$(SYSTEM)" :print t)' \
	    --load tools/check-saved-transcript.lisp \
	  || { echo 'FAIL: saved-transcript structural check failed'; exit 1; }; \
	echo "$$(date -u +%H:%M:%S) [4/4] LIVE MODEL ROUND-TRIP PASSED"

verify: build
	@echo '[probe 1] --help exits 0 and prints usage'
	@./sexpr --help | grep -q 'usage: sexpr'
	@echo '[probe 2] scripted session runs and exits 0'
	@printf '/help\n/exit\n' | ./sexpr --goal "verify" | grep -q 'Commands:'
	@echo '[probe 3] cross-process --load round-trips'
	@tmp=$$(mktemp --suffix=.sexp); printf "/save $$tmp\n/exit\n" | ./sexpr --goal "verify"; test -s $$tmp; ./sexpr --goal "verify" --load $$tmp </dev/null; rc=$$?; rm -f $$tmp; exit $$rc
	@echo '[probe 4] R015 provider seam clean'
	@! rg -q cl-llm-provider src/cli/
	@echo 'ALL PROBES PASSED'

clean:
	rm -f ./sexpr
	rm -rf .ql .output *.fasl *.fbas *.lib
	find src -type f \( -name '*.fasl' -o -name '*.fbas' -o -name '*.lib' \) -delete

help:
	@echo "sexpr — targets:"
	@echo "  hello   Run sexpr:hello"
	@echo "  test    Run the rove test suite"
	@echo "  load    Load the system interactively"
	@echo "  build   Produce ./sexpr via save-lisp-and-die (depends on test)"
	@echo "  chat    Run ./sexpr (override with CHAT_ARGS='--goal \"...\"')"
	@echo "  verify  Run binary probes: --help, scripted session, cross-process load, R015 seam"
	@echo "  diagnostic-tool-call  Probe a live local server for a usable :tool-calls node"
	@echo "  diagnostic-live-round  In-process live turn: assert the recorded events and the live :value"
	@echo "  test-live  Run ./sexpr against the live local model and structurally check the saved transcript (requires a running server)"
	@echo "  clean   Remove build artifacts"
	@echo "  help    This message"
