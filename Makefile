# Makefile for the LiteX UARTBone + LiteScope standalone IP core.
#
# Common one-liners:
#   make generate          -> LiteX build: emits build/virtual/gateware/soc.v (+ csr.csv, csr.json, analyzer.csv)
#   make build             -> generate, then copy the final IP files to dist/
#   make test              -> lint + Verilator self-checking simulation
#   make simulate          -> Verilator-compile the IP + C++ harness and run it
#   make lint              -> Verilator lint-only pass on the generated gateware
#   make clean             -> Remove all build artifacts (build/, dist/)
#   make help              -> Show this help
#
# Override the core parameters on the command line, e.g.:
#   make build CLK_FREQ=100000000 BAUDRATE=1000000 BUILD_NAME=my_ila

# ---- Configuration ----------------------------------------------------------

UV         ?= uv
BUILD_NAME ?= soc
CLK_FREQ   ?= 50000000
BAUDRATE   ?= 115200
OUT_DIR    ?= build/virtual
DIST_DIR   ?= dist
VERI_DIR   ?= build/verilator
# IVL_DIR    ?= build/iverilog
TB_CPP     ?= test/tb_soc.cpp
# Icarus support is disabled for now (see test/tb_soc.v for the known issue).
# TB_V       ?= test/tb_soc.v
# FULL       ?=
# # Icarus run timeout (seconds): a timeout prints a warning instead of failing.
# IVL_TIMEOUT ?= 180

TOP_MODULE := $(BUILD_NAME)
GATEWARE   := $(OUT_DIR)/gateware/$(TOP_MODULE).v
SYSFILES   := $(OUT_DIR)/csr.csv $(OUT_DIR)/csr.json $(OUT_DIR)/analyzer.csv
VERI_BIN   := $(VERI_DIR)/Vdut
# IVL_BIN    := $(IVL_DIR)/sim
TB_DEFS    := -DCLK_FREQ=$(CLK_FREQ) -DBAUDRATE=$(BAUDRATE)

# Benign warning classes from generated code (see README).
VERI_WARN  := -Wno-COMBDLY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE

# Regenerate when the core parameters change (not only when sources change).
PARAMS     := $(OUT_DIR)/.params
PARAMS_VAL := $(BUILD_NAME) $(CLK_FREQ) $(BAUDRATE)

# ---- Targets ----------------------------------------------------------------

.PHONY: all generate build test simulate lint clean help FORCE

all: build test

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

generate: $(GATEWARE) ## LiteX build -> single-file Verilog IP in build/
	@echo "[make] Generated: $(GATEWARE) $(SYSFILES)"

build: $(GATEWARE) ## Generate the IP and copy the final files to dist/
	@mkdir -p $(DIST_DIR)
	cp $(GATEWARE) $(SYSFILES) $(DIST_DIR)/
	@echo "[make] IP core ($(CLK_FREQ) Hz, $(BAUDRATE) baud) in $(DIST_DIR)/:"
	@ls -1 $(DIST_DIR)

$(PARAMS): FORCE
	@mkdir -p $(OUT_DIR)
	@echo '$(PARAMS_VAL)' | cmp -s - $@ || echo '$(PARAMS_VAL)' > $@

$(GATEWARE) $(SYSFILES) &: src/litex_wb_litescope/soc.py src/litex_wb_litescope/build_soc.py \
                           pyproject.toml uv.lock $(PARAMS)
	$(UV) run simple-soc --output-dir $(OUT_DIR) --build-name $(BUILD_NAME) \
	                     --clk-freq $(CLK_FREQ) --baudrate $(BAUDRATE)

test: lint simulate ## Lint + Verilator self-checking simulation

# Icarus support is disabled for now (see test/tb_soc.v for the known issue).
# test: lint simulate $(if $(FULL),simulate-iverilog)
# full-test: lint simulate simulate-iverilog

simulate: $(VERI_BIN) ## Verilator-compile the IP + C++ harness, then run it
	$(VERI_BIN)

$(VERI_BIN): $(GATEWARE) $(TB_CPP)
	verilator --cc --exe -Wno-fatal $(VERI_WARN) --top-module $(TOP_MODULE) --prefix Vdut \
	          -CFLAGS "$(TB_DEFS)" -Mdir $(VERI_DIR) $(GATEWARE) $(TB_CPP)
	$(MAKE) -j -C $(VERI_DIR) -f Vdut.mk

# simulate-iverilog: $(IVL_BIN)
# 	@echo "vvp -n $(IVL_BIN)  (timeout $(IVL_TIMEOUT)s)"
# 	@timeout $(IVL_TIMEOUT) vvp -n $(IVL_BIN); rc=$$?; \
# 	if [ $$rc -eq 124 ]; then \
# 		echo "WARNING: Icarus simulation did not finish within $(IVL_TIMEOUT)s -- result inconclusive (not a failure)." >&2; \
# 	else exit $$rc; fi
#
# $(IVL_BIN): $(GATEWARE) $(TB_V)
# 	@mkdir -p $(IVL_DIR)
# 	iverilog -g2012 $(TB_DEFS) -DTOP=$(TOP_MODULE) -s tb_soc -o $@ $(GATEWARE) $(TB_V)

lint: $(GATEWARE) ## Verilator lint-only pass on the generated gateware
	verilator --lint-only -Wno-fatal $(VERI_WARN) --top-module $(TOP_MODULE) $(GATEWARE)

clean: ## Remove all build artifacts
	rm -rf build $(DIST_DIR)
