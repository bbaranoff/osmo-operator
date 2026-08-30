#!/usr/bin/env python3
# Raccourci vers la console SS7 : le code vit dans navigation/.
import os
import runpy
import sys

target = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "navigation", "ss7-console.py")
sys.argv[0] = target
runpy.run_path(target, run_name="__main__")
