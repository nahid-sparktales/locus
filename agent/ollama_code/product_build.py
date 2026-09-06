"""Fixed standard-product identity and feature factory.

The app build stages the appropriate version of this module. Never select a
product implementation from environment variables, preferences, or requests.
"""
from __future__ import annotations

from typing import Any

from .product_features import ProductFeatures

PRODUCT_NAME = "Locus"
PRODUCT_BUNDLE_ID = "io.sparktales.locus"
PRODUCT_URL_SCHEME = "locus"


def create_features(registry: Any) -> ProductFeatures:
    return ProductFeatures(registry)
