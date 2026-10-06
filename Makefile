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

.PHONY: hello test load build chat verify diagnostic-tool-call test-live clean help

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

test-live: build
	@echo '[live] local model round-trip'
	@printf '/exit\n' | \
	SEXPR_PROVIDER=openai-compatible \
	SEXPR_BASE_URL=http://localhost:6969/v1 \
	SEXPR_MODEL=Qwythos-9B-v2 \
	./sexpr --goal "Say hello in one word."

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
	@echo "  test-live  Run ./sexpr against the live local model (requires a running server)"
	@echo "  clean   Remove build artifacts"
	@echo "  help    This message"
