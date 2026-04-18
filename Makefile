.PHONY: test

test:
	sbcl --non-interactive \
	     --eval "(ql:quickload :fiveam)" \
	     --eval "(push #p\"$(CURDIR)/\" asdf:*central-registry*)" \
	     --eval "(asdf:load-system :elp)" \
	     --eval "(load \"elp-test.lisp\")" \
	     --eval "(elp-test:run-tests)"

bin/elp:
	mkdir -p bin
	sbcl --eval "(require :asdf)" \
	     --eval "(push #p\"$(CURDIR)/\" asdf:*central-registry*)" \
	     --eval "(asdf:load-system :elp)" \
	     --eval "(sb-ext:save-lisp-and-die \"bin/elp\" :toplevel $(SHARP)'elp/cli:main :executable t :compression t)"

SHARP := \#
