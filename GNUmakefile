# use GNU Make to run tests in parallel, and without depending on Rubygems
all:: test

slow_tests := test/unit/test_server.rb
awk_slow := awk '/def test_/{print FILENAME"--"$$2".n"}'
T := $(filter-out $(slow_tests),$(wildcard test/unit/test*.rb))
T_n := $(shell $(awk_slow) $(slow_tests))
test: $(T) $(T_n)

$(slow_tests):
	@$(MAKE) $(shell $(awk_slow) $@)
%.n: arg = $(subst .n,,$(subst --, -n ,$@))
%.n: name = $(subst .n,,$(subst --, ,$@))
%.n:
	@echo '**** $(name) ****'; ruby -I lib $(arg) $(TEST_OPTS)
$(T):
	@echo '**** $@ ****'; ruby -I lib $@ $(TEST_OPTS)

.PHONY: $(T) $(slow_tests)
