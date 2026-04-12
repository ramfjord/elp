bin/elp:
	mkdir -p bin
	sbcl --eval "(require :asdf)" \
	     --eval "(push #p\"$(CURDIR)/\" asdf:*central-registry*)" \
	     --eval "(asdf:load-system :elp)" \
	     --eval "(sb-ext:save-lisp-and-die \"bin/elp\" :toplevel $(SHARP)'elp/cli:main :executable t :compression t)"

SHARP := \#
