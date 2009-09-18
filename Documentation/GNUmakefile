all::

PANDOC = pandoc
PANDOC_OPTS = -s -f markdown --email-obfuscation=none --sanitize-html
pandoc = $(PANDOC) $(PANDOC_OPTS)
pandoc_html = $(pandoc) --toc -t html --no-wrap

man1 := unicorn unicorn_rails

all:: html man
doc-gz: man-gz html-gz

html: $(addsuffix .1.html,$(man1))
man: $(addsuffix .1,$(man1))
html-gz: $(addsuffix .1.html.gz,$(man1))
man-gz: $(addsuffix .1.gz,$(man1))

%.1: %.1.txt
	$(pandoc) -t man < $< > $@+ && mv $@+ $@
%.1.html: %.1.txt
	$(pandoc_html) -T $(basename $@) < $< > $@+ && mv $@+ $@

%.1.gz: %.1
	gzip --rsyncable < $< > $@+ && mv $@+ $@

%.1.html.gz: %.1.html
	gzip --rsyncable < $< > $@+ && mv $@+ $@

clean::
	$(RM) $(addsuffix .1.html,$(man1))
	$(RM) $(addsuffix .1,$(man1))
	$(RM) $(addsuffix .1.html.gz,$(man1))
	$(RM) $(addsuffix .1.gz,$(man1))
