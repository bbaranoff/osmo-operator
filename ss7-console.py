#!/usr/bin/env python3
# ss7-console.py - shortcut to the SS7 console; the code lives in navigation/ss7-console.py.
import os
import runpy
import sys

target = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "navigation", "ss7-console.py")
sys.argv[0] = target
runpy.run_path(target, run_name="__main__")
