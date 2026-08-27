# Makefile for the LiteX UARTBone + LiteScope standalone IP core.
#
# Common one-liners:
#   make generate   -> LiteX build: emits build/virtual/gateware/soc.v (+ csr.csv, analyzer.csv)
#   make simulate   -> Verilator-compile the IP + C++ harness and run the simulation
#   make lint       -> Verilator lint-only pass on the generated gateware
#   make clean      -> Remove all build artifacts
#   make help       -> Show this help

# ---- Configuration ----------------------------------------------------------

UV         ?= uv
OUT_DIR    ?= build/virtual
VERI_DIR   ?= build/verilator
TOP_MODULE ?= soc
TB         ?= test/tb_soc.cpp

GATEWARE   := $(OUT_DIR)/gateware/$(TOP_MODULE).v
BIN        := $(VERI_DIR)/V$(TOP_MODULE)
SYSFILES   := $(OUT_DIR)/csr.csv $(OUT_DIR)/analyzer.csv

# Benign warning classes from generated code (see README).
VERI_WARN  := -Wno-COMBDLY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE

# ---- Targets ----------------------------------------------------------------

.PHONY: all generate simulate lint clean help

all: generate simulate

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

generate: $(GATEWARE) ## LiteX build -> single-file Verilog IP
	@echo "[make] Generated: $(GATEWARE) $(SYSFILES)"

$(GATEWARE) $(SYSFILES): src/litex_wb_litescope/soc.py src/litex_wb_litescope/build_soc.py
	$(UV) run simple-soc --output-dir $(OUT_DIR)

simulate: $(BIN) ## Verilator-compile the IP + harness, then run the simulation
	$(BIN)

$(BIN): $(GATEWARE) $(TB)
	verilator --cc --exe --timing -Wall -Wno-fatal --top-module $(TOP_MODULE) \
	          -Mdir $(VERI_DIR) $(GATEWARE) $(TB)
	$(MAKE) -C $(VERI_DIR) -f V$(TOP_MODULE).mk

lint: $(GATEWARE) ## Verilator lint-only pass on the generated gateware
	verilator --lint-only -Wno-fatal $(VERI_WARN) --top-module $(TOP_MODULE) $(GATEWARE)

clean: ## Remove all build artifacts
	rm -rf build
