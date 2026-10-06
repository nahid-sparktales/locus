"""Compatibility import; canonical mechanics live in locus_runtime.snapshots."""
import sys

from locus_runtime import snapshots

sys.modules[__name__] = snapshots
