# --- Path ---
RTL_DIR   = ../rtl
FILELIST = ./filelist.f

# VCS 
VCS_OPTS  = -full64 -sverilog -Mupdate -kdb \
            -debug_access+all -timescale=1ns/1ps +define+DUMP_FSDB\
            +incdir+$(RTL_DIR) \
            -l comp.log
# C
CC_OPTS   = -cpp g++-7 -cc gcc-7 \
            -LDFLAGS -Wl,--no-as-needed
# SIM
SIM_OPTS  = -l sim.log

# --- Targets ---
.PHONY: all comp sim verdi clean clean_all

all: clean comp sim

# compile
comp:
	@echo ">>> [Compiling] Source: $(FILELIST)"
	vcs $(VCS_OPTS) $(CC_OPTS) -f $(FILELIST)

# simulate
sim:
	@echo ">>> [Simulating] ..."
	# ./$(OUTPUT) $(SIM_OPTS) -fsdb +fsdbfile+tb.fsdb
	./simv $(SIM_OPTS)

# verdi
verdi:
	@echo ">>> [Verdi] Opening waveform..."
	# verdi -sverilog $(SRC_FILES) -ssf *.fsdb
	# -kdb can save knowledge database in simv.daidir, so here can directly read this dir, and can be faster
	verdi -dbdir simv.daidir -ssf *.fsdb

clean:
	@echo ">>> [Cleaning] Cleaning simulation files..."
	rm -rf csrc simv* *.daidir *.log *.key *.vpd *.fsdb*
	rm -rf verdiLog novas.* DVEfiles
	rm -rf *~ core vc_hdrs.h

clean_all: clean
	@echo ">>> [Cleaning] Cleaning coverage and reports..."
	rm -rf urgReport *.vdb stack.info* .inter.vpd.uvm
