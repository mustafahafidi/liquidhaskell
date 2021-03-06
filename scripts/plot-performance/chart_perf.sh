#!/usr/bin/env bash

# Simple script to plot the performance regression between different testruns in Liquidhaskell.
# It requires:
# - gnuplot
# - Imagemagick

# $1 = before.csv
# $2 = after.csv

cat $1 | tail -n +5 > before.csv
cat $2 | tail -n +5 > after.csv

paste before.csv after.csv > combined.csv

gnuplot -p -e "csv_1='before.csv';csv_2='after.csv';csv_3='combined.csv'" perf.gnuplot
convert -trim -density 300 perf.svg perf.png
