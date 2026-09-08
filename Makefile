# Shortcuts for the tasks documented in README.md. Nothing here is new behaviour — each
# target is the command it already tells you to run.

JULIA   ?= julia
PROJECT ?= --project=.

# Which Arrow file `make portability` should check. Left empty, a small sample is written
# to a temporary directory so the target is runnable on its own.
FILE ?=

.DEFAULT_GOAL := help
.PHONY: help instantiate test check-upstream record-fixtures bench portability clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

instantiate: ## Install the package dependencies
	$(JULIA) $(PROJECT) -e 'using Pkg; Pkg.instantiate()'

test: ## Run the test suite (offline — never touches the network)
	$(JULIA) $(PROJECT) -e 'using Pkg; Pkg.test()'

check-upstream: ## Report whether Delphi still matches test/fixtures/ (network; ~10 requests)
	$(JULIA) $(PROJECT) scripts/check_upstream.jl

record-fixtures: ## Re-record test/fixtures/ from the live API (network; ~10 requests)
	$(JULIA) $(PROJECT) scripts/check_upstream.jl --write

bench: ## Storage size and reload benchmark (bench/ has its own project)
	$(JULIA) --project=bench bench/size_and_reload.jl

portability: ## Read an Arrow file from Go (make portability FILE=out.arrow)
	@f='$(FILE)'; \
	if [ -z "$$f" ]; then \
		d=$$(mktemp -d); f="$$d/sample.arrow"; \
		echo "No FILE given — writing a sample table to $$f"; \
		$(JULIA) $(PROJECT) -e 'using EpiDataKit, Dates, StructArrays; obs = [EpiObservation(source=:nssp, signal=:pct_ed_visits_covid, geo_level=STATE, geo_id="ca", period_start=Date(2026,5,17), period_end=Date(2026,5,23), value=0.07, issue=Date(2026,8,1), lag=10), EpiObservation(source=:jhu_csse, signal=:confirmed_incidence_num, geo_level=COUNTY, geo_id="06075", period_start=Date(2020,6,1), period_end=Date(2020,6,1), value=2437.0, missing_code=CENSORED)]; EpiDataKit.save(StructArray(obs), ARGS[1])' "$$f"; \
	else \
		case "$$f" in /*) ;; *) f="$$PWD/$$f" ;; esac; \
	fi; \
	go -C test/portability_check run . "$$f"

clean: ## Remove the compiled Go checker
	rm -f test/portability_check/portabilitycheck
