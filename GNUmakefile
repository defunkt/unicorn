# use GNU Make to run tests in parallel, and without depending on Rubygems
all:: test
-include local.mk
ifeq ($(DLEXT),) # "so" for Linux
  DLEXT := $(shell ruby -rrbconfig -e 'puts Config::CONFIG["DLEXT"]')
endif

slow_tests := test/unit/test_server.rb
awk_slow := awk '/def test_/{print FILENAME"--"$$2".n"}'
T := $(filter-out $(slow_tests),$(wildcard test/unit/test*.rb))
T_n := $(shell $(awk_slow) $(slow_tests))
test: $(T) $(T_n)

$(slow_tests):
	@$(MAKE) $(shell $(awk_slow) $@)
%.n: arg = $(subst .n,,$(subst --, -n ,$@))
%.n: name = $(subst .n,,$(subst --, ,$@))
%.n: lib/http11.$(DLEXT)
	@echo '**** $(name) ****'; ruby -I lib $(arg) $(TEST_OPTS)
$(T): lib/http11.$(DLEXT)
	@echo '**** $@ ****'; ruby -I lib $@ $(TEST_OPTS)

http11_deps := $(addprefix ext/http11/, \
                 ext_help.h http11.c http11_parser.c http11_parser.h \
                 http11_parser.rl http11_parser_common.rl \
	         Makefile)
ext/http11/http11_parser.c: ext/http11/http11_parser.rl
	cd $(@D) && ragel $(<F) -C -G2 -o $(@F)
ext/http11/Makefile: ext/http11/extconf.rb
	cd $(@D) && ruby $(<F)
ext/http11/http11.$(DLEXT): $(http11_deps)
	$(MAKE) -C $(@D)
lib/http11.$(DLEXT): ext/http11/http11.$(DLEXT)
	@mkdir -p lib
	install -m644 $< $@

clean:
	-$(MAKE) -C ext/http11 clean
	$(RM) ext/http11/Makefile lib/http11.$(DLEXT)

.PHONY: $(T) $(slow_tests)
