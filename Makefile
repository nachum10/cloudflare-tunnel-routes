# cloudflare-tunnel-routes - common tasks

.PHONY: help test lint install ci docs-check

help:
	@echo "Targets:"
	@echo "  make test       - run the hermetic test suite (no real cloudflared/DNS)"
	@echo "  make lint       - bash syntax check on all shell scripts"
	@echo "  make install    - symlink this repo into ~/.claude/skills/"
	@echo "  make docs-check - verify all documented files actually exist"
	@echo "  make ci         - what CI runs: lint + test"

test:
	@bash tests/run-tests.sh

lint:
	@for f in scripts/*.sh tests/*.sh install.sh; do \
	    bash -n "$$f" || exit 1; \
	done
	@echo "lint: OK"

install:
	@./install.sh

ci: lint test

docs-check:
	@missing=0; \
	for f in README.md SKILL.md AGENTS.md INSTALL.md RELEASE.md \
	         USE_CASES.md PROMPTS.md llms.txt LICENSE \
	         .cursor/rules/cloudflare-tunnel-routes.mdc \
	         examples/gradio.md examples/streamlit.md examples/fastapi.md \
	         examples/webhooks.md examples/docker.md \
	         scripts/detect.sh scripts/add-route.sh scripts/remove-route.sh \
	         scripts/list-routes.sh scripts/setup-new-tunnel.sh \
	         tests/run-tests.sh references/troubleshooting.md; do \
	    if [ ! -e "$$f" ]; then echo "MISSING: $$f"; missing=$$((missing+1)); fi; \
	done; \
	if [ "$$missing" -gt 0 ]; then exit 1; fi; \
	echo "docs-check: all referenced files present"
