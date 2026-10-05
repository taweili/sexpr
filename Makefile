# SPDX-License-Identifier: GPL-3.0-or-later
# sexpr — build & run targets.
#
#   make hello      Run the sexpr:hello entry point.
#   make load       Load the system into an interactive SBCL session.
#   make clean      Remove build artifacts.

SBCL      ?= sbcl
SBCLINIT  ?= $(HOME)/.sbclinit
SYSTEM    := sexpr

.PHONY: hello load clean help

hello:
	$(SBCL) --non-interactive \
		--load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--eval '(sexpr:hello)'

load:
	$(SBCL) --load $(SBCLINIT) \
		--eval '(ql:quickload "$(SYSTEM)" :print t)' \
		--eval '(format t "~&Loaded ~a ~a. Type (sexpr:hello) to run.~%" (sexpr:name) (sexpr:version))'

clean:
	rm -rf .ql .output *.fasl *.fbas *.lib
	find src -type f \( -name '*.fasl' -o -name '*.fbas' -o -name '*.lib' \) -delete

help:
	@echo "sexpr — targets:"
	@echo "  hello   Run sexpr:hello"
	@echo "  load    Load the system interactively"
	@echo "  clean   Remove build artifacts"
	@echo "  help    This message"
