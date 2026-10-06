"""Compatibility import; canonical mechanics live in locus_runtime.installer."""
import sys

from locus_runtime import installer

sys.modules[__name__] = installer
