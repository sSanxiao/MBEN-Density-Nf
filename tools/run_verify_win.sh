#!/usr/bin/env bash
# tools/run_verify_win.sh
# Wrapper for running verify_equivalence.sh under Git Bash on Windows.
# Sets HOME to Windows home so R finds user config.
# R library path is handled by .Rprofile in the project root.
# 注意：本机 Windows/WSL 桥接脚本，非跨机可移植。
# 下方 HOME/RSCRIPT/PYTHON/DATA_DIR/RESULTS_DIR 均为本机绝对路径，换机需改写。

export HOME='/c/Users/13379'
export RSCRIPT='/d/R-4.5.2/bin/Rscript.exe'
export PYTHON='/d/python3.9.13/python.exe'
export DATA_DIR='/f/Thesis/scripts_Final/Scripts_New/fixture_data'
export RESULTS_DIR='/f/Thesis/scripts_Final/Scripts_New/verify_out'
# Force Python to use UTF-8 for stdout (fixes GBK encoding error in old P2's Âµm print)
export PYTHONIOENCODING='utf-8'

echo "HOME=$HOME"
echo "RSCRIPT=$RSCRIPT"
echo "PYTHON=$PYTHON"
echo "DATA_DIR=$DATA_DIR"
echo "RESULTS_DIR=$RESULTS_DIR"

cd /f/Thesis/scripts_Final/Scripts_New
bash tools/verify_equivalence.sh
