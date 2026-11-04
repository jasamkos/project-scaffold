SH := $(wildcard skill/install.sh skill/dispatch skill/templates/hooks/lib.sh skill/templates/hooks/brief skill/templates/hooks/checkpoint skill/templates/hooks/gate skill/templates/hooks/test.sh skill/templates/extras/haiku-refresh.sh)

check:
	shellcheck -x $(SH)
	bash skill/templates/hooks/test.sh
.PHONY: check
