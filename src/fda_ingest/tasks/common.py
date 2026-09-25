"""Shared arguments and naming for the ingestion tasks."""

from __future__ import annotations

import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class Target:
    catalog: str
    schema: str
    volume: str
    table_prefix: str

    def table(self, name: str) -> str:
        return f"{self.catalog}.{self.schema}.{self.table_prefix}{name}"

    @property
    def volume_path(self) -> str:
        return f"/Volumes/{self.catalog}/{self.schema}/{self.volume}"


def base_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--volume", required=True)
    parser.add_argument("--table-prefix", default="")
    return parser


def target_from(args: argparse.Namespace) -> Target:
    return Target(args.catalog, args.schema, args.volume, args.table_prefix)


def ensure_volume(spark, target: Target) -> None:
    spark.sql(f"CREATE VOLUME IF NOT EXISTS {target.catalog}.{target.schema}.{target.volume}")