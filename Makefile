.PHONY: test test-fixtures

LARGE_FIXTURE := tests/fixtures/large.elp

test-fixtures: $(LARGE_FIXTURE)

# A ~500MB template that is mostly plain text with a handful of tags
# sprinkled in. Used by READ-STEP-STAYS-NEAR-RAW-READ to compare the
# read step's wall time against a raw chunked file read on the same
# bytes. Regenerate by deleting and re-running this target; should
# rarely need to change.
$(LARGE_FIXTURE):
	mkdir -p $(dir $@)
	{ \
	  printf '<%%= title %%>\n'; \
	  printf '<%%# generated fixture — see Makefile %%>\n'; \
	  yes 'lorem ipsum dolor sit amet consectetur adipiscing elit' | head -c 250000000; \
	  printf '\n<%% (let ((x 7) (y 35)) (format t "sum=~A" (+ x y))) %%>\n'; \
	  yes 'lorem ipsum dolor sit amet consectetur adipiscing elit' | head -c 250000000; \
	  printf '\n<%%= title %%>\n'; \
	} > $@

test:
	sbcl --non-interactive \
	     --eval "(ql:quickload :fiveam)" \
	     --eval "(push #p\"$(CURDIR)/\" asdf:*central-registry*)" \
	     --eval "(asdf:load-system :elp)" \
	     --eval "(load \"elp-test.lisp\")" \
	     --eval "(elp-test:run-tests)"

bin/elp: elp.lisp elp.asd cli.lisp
	mkdir -p bin
	sbcl --eval "(require :asdf)" \
	     --eval "(push #p\"$(CURDIR)/\" asdf:*central-registry*)" \
	     --eval "(asdf:load-system :elp)" \
	     --eval "(sb-ext:save-lisp-and-die \"bin/elp\" :toplevel $(SHARP)'elp/cli:main :executable t :compression t :save-runtime-options t)"

SHARP := \#
