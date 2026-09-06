#!/usr/bin/env python3
"""Stage an app-owned Python package with a fixed product implementation.

The source checkout always runs the standard product. LocusX app builds use a
staged copy with a fixed factory; runtime environment values never select it.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def stage_backend(source: Path, destination: Path, edition: str) -> None:
    source = source.resolve()
    destination = destination.resolve()
    if edition not in {"locus", "locusx"}:
        raise ValueError(f"unknown product edition: {edition}")
    if not (source / "product_build.py").is_file():
        raise ValueError("source must be the ollama_code package directory")
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError("source and destination must be separate package directories")
    if destination.name != "ollama_code":
        raise ValueError("destination must name a staged ollama_code package")
    if destination.exists():
        shutil.rmtree(destination)

    def ignored(directory: str, names: list[str]) -> set[str]:
        exclude = {name for name in names if name == "__pycache__" or name.endswith(".pyc")}
        if Path(directory) == source and edition == "locus":
            exclude.add("_locusx")
        return exclude

    # copy preserves script modes without carrying extended file metadata.
    shutil.copytree(source, destination, ignore=ignored, copy_function=shutil.copy)
    if edition == "locusx":
        if not (destination / "_locusx/wallet.py").is_file():
            raise ValueError("LocusX source is missing its private product implementation")
        (destination / "product_build.py").write_text(
            '"""Fixed LocusX identity and factory, selected by the app build."""\n'
            'from __future__ import annotations\n\n'
            'from typing import Any\n\n'
            'from .product_features import ProductFeatures\n\n'
            'PRODUCT_NAME = "LocusX"\n'
            'PRODUCT_BUNDLE_ID = "io.sparktales.locusx"\n'
            'PRODUCT_URL_SCHEME = "locusx"\n\n\n'
            'def create_features(registry: Any) -> ProductFeatures:\n'
            '    from ._locusx.wallet import WalletFeature\n\n'
            '    return WalletFeature(registry)\n',
            encoding="utf-8",
        )
    else:
        # Do not trust a previously staged X package as the standard factory.
        (destination / "product_build.py").write_text(
            '"""Fixed Locus identity and factory, selected by the app build."""\n'
            'from __future__ import annotations\n\n'
            'from typing import Any\n\n'
            'from .product_features import ProductFeatures\n\n'
            'PRODUCT_NAME = "Locus"\n'
            'PRODUCT_BUNDLE_ID = "io.sparktales.locus"\n'
            'PRODUCT_URL_SCHEME = "locus"\n\n\n'
            'def create_features(registry: Any) -> ProductFeatures:\n'
            '    return ProductFeatures(registry)\n',
            encoding="utf-8",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--edition", choices=("locus", "locusx"), required=True)
    args = parser.parse_args()
    stage_backend(args.source, args.destination, args.edition)


if __name__ == "__main__":
    main()
